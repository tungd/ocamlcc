open Sys_util
open Result_syntax

module Request = struct
  type t = {
    steps : Dep_graph.Step.t list;
    work_dir : string;
    include_dirs : string list;
    stdlib : Stdlib_build.t;
    nostdlib : bool;
    nopervasives : bool;
    single_thread : bool;
    include_main : bool;
    publish_object : bool;
    mode : Build_mode.t;
    debug_info : bool;
    cache_dir : string option;
    toolchain_key : string;
    qbe : string;
    target : Target.t;
    verbose : bool;
  }
end

type compiled = {
  assemblies : string list;
  object_interface : (string * string * Anf.exports) option;
  compiled : int;
  hits : int;
}

module Names = Map.Make (String)
module Name_set = Set.Make (String)

let find_interface available include_dirs name =
  match Names.find_opt name available with
  | Some path when Sys.file_exists path -> Some path
  | _ ->
      let targets =
        [ String.uncapitalize_ascii name ^ ".cmi"; name ^ ".cmi" ]
      in
      let rec search = function
        | [] -> None
        | dir :: rest ->
            match
              List.find_map (fun base ->
                let path = Filename.concat dir base in
                if Sys.file_exists path then Some path else None) targets
            with
            | Some _ as found -> found
            | None -> search rest
      in
      search include_dirs

let fingerprint_bytes label path =
  let+ digest = Sha256.file path in
  label, Sha256.to_hex digest

let read_refs available include_dirs (step : Dep_graph.Step.t) =
  let* references = Dep_graph.references step in
  let rec discover seen files = function
    | [] -> Ok files
    | name :: rest ->
        if Name_set.mem name seen then discover seen files rest
        else
          let seen = Name_set.add name seen in
          match find_interface available include_dirs name with
          | None -> discover seen files rest
          | Some interface ->
              let* file = fingerprint_bytes (name ^ ".cmi") interface in
              let sidecar = Filename.remove_extension interface ^ ".exports" in
              let* files =
                if Sys.file_exists sidecar then
                  let+ metadata = fingerprint_bytes (name ^ ".exports") sidecar in
                  metadata :: file :: files
                else Ok (file :: files)
              in
              let bin_exports = Filename.remove_extension interface ^ ".exports_bin" in
              let* files =
                if Sys.file_exists bin_exports then
                  let+ metadata = fingerprint_bytes (name ^ ".exports_bin") bin_exports in
                  metadata :: files
                else Ok files
              in
              let more =
                match Cmi_format.read_cmi interface with
                | info -> List.map fst info.cmi_crcs
                | exception _ -> []
              in
              discover seen files (more @ rest)
  in
  discover Name_set.empty [] (step.modname :: references)

let unit_cache_key ~toolchain_key ~include_dirs ~available ~has_mli ~publish_object
    (step : Dep_graph.Step.t) =
  let* source = fingerprint_bytes "source" step.path in
  let* imported = read_refs available include_dirs step in
  let role = match step.kind with `Mli -> "interface" | `Ml -> "implementation" in
  Ok
    (Build_cache.key
       ([ "toolchain", toolchain_key;
          "unit", step.modname;
          "role", role;
          "path", step.path;
          "has-mli", string_of_bool has_mli;
          "publish", string_of_bool publish_object;
          source ]
       @ List.sort compare imported))

let copy_cached ~source ~destination base extensions =
  List.iter (fun ext ->
    let src = Filename.concat source (base ^ ext) in
    if Sys.file_exists src then
      write_if_changed (Filename.concat destination (base ^ ext)) (read_file src))
    extensions

let write_exports_bin path (exports : Anf.exports) =
  write_atomic path (Marshal.to_string exports [])

let read_exports_bin path : (Anf.exports, string) result =
  try
    let data = read_file path in
    Ok (Marshal.from_string data 0)
  with
  | Sys_error msg -> Error msg
  | Invalid_argument msg | Failure msg -> Error ("corrupt cached export summary: " ^ msg)

let compile_entry_unit ~cache_dir ~toolchain_key ~work_dir ~qbe ~(target : Target.t)
    ~verbose local_units =
  let build_into dir =
    let ssa = Filename.concat dir "ocamlcc_entry.ssa" in
    let asm = Filename.concat dir "ocamlcc_entry.s" in
    write_file ssa (Qbe_il.to_string { funcs = [Codegen.entry_point local_units]; datas = [] });
    run_cmd ~verbose ~stdout_file:asm qbe ["-t"; target.qbe_target; ssa]
  in
  match cache_dir with
  | None ->
      let+ () = build_into work_dir in
      (Filename.concat work_dir "ocamlcc_entry.s", false)
  | Some cache ->
      let store = Filename.concat cache "occ-unit" in
      let key =
        Build_cache.key
          ([ "toolchain", toolchain_key; "kind", "entry" ]
          @ List.map (fun name -> "module", name) local_units)
      in
      let+ entry = Build_cache.ensure ~store ~key build_into in
      let asm = Filename.concat work_dir "ocamlcc_entry.s" in
      write_if_changed asm (read_file (Filename.concat entry.directory "ocamlcc_entry.s"));
      (asm, entry.hit)

let compile (request : Request.t) =
  let { Request.steps; work_dir; include_dirs; stdlib; nostdlib; nopervasives;
        single_thread; include_main; publish_object; mode; debug_info;
        cache_dir; toolchain_key; qbe; target; verbose } =
    request
  in
  let cmi_dir = Filename.concat work_dir "cmi" in
  mkdir_p cmi_dir;
  let implementations, interfaces =
    List.partition (fun (step : Dep_graph.Step.t) -> step.kind = `Ml) steps
  in
  let local_units =
    List.map (fun (step : Dep_graph.Step.t) -> step.modname) implementations
  in
  let stdlib_dir = Stdlib_build.interface_dir stdlib in
  let archive = Stdlib_build.archive stdlib in
  let summaries =
    Some (Export_summary.Loader.create ?archive ~exclude_units:local_units ())
  in
  let unit_store = Option.map (fun c -> Filename.concat c "occ-unit") cache_dir in
  let rec compile_steps available imports assemblies object_interface compiled hits = function
    | [] ->
        let+ assemblies, entry_hit =
          if include_main && implementations <> [] then
            let+ entry_asm, hit =
              compile_entry_unit ~cache_dir ~toolchain_key ~work_dir ~qbe ~target
                ~verbose local_units
            in
            List.rev (entry_asm :: assemblies), hit
          else Ok (List.rev assemblies, false)
        in
        let hits = hits + (if entry_hit then 1 else 0) in
        let compiled = compiled + (if include_main && implementations <> [] && not entry_hit then 1 else 0) in
        { assemblies; object_interface; compiled; hits }
    | (step : Dep_graph.Step.t) :: rest ->
        let base = String.uncapitalize_ascii step.modname in
        let work_prefix = Filename.concat cmi_dir base in
        let has_mli =
          List.exists (fun (interface : Dep_graph.Step.t) ->
              interface.modname = step.modname) interfaces
        in
        match step.kind with
        | `Mli ->
            let build_cmi dir =
              let prefix = Filename.concat dir base in
              let req =
                { (Pipeline.Request.create ~filename:step.path ~modname:step.modname) with
                  include_dirs; output_prefix = Some prefix; nopervasives; nostdlib;
                  mode; debug_info }
              in
              let+ _ = Pipeline.compile_interface_file req in
              ()
            in
            let* hit =
              match unit_store with
              | None ->
                  let+ () = build_cmi cmi_dir in false
              | Some store ->
                  let* key =
                    unit_cache_key ~toolchain_key ~include_dirs ~available ~has_mli:false
                      ~publish_object:false step
                  in
                  let+ entry = Build_cache.ensure ~store ~key build_cmi in
                  copy_cached ~source:entry.directory ~destination:cmi_dir base [".cmi"];
                  entry.hit
            in
            let available = Names.add step.modname (work_prefix ^ ".cmi") available in
            if not hit then Gc.full_major ();
            compile_steps available imports assemblies object_interface
              (compiled + if hit then 0 else 1) (hits + if hit then 1 else 0) rest
        | `Ml ->
            let build_ml ~cmi_target ~work_target exports_ref =
              let prefix = Filename.concat cmi_target base in
              let req =
                { (Pipeline.Request.create ~filename:step.path ~modname:step.modname) with
                  include_dirs; output_prefix = Some prefix; nopervasives; nostdlib;
                  stdlib_dir; summaries; imports;
                  emit_cmi = not has_mli; emit_entry = false;
                  export_policy = (if publish_object then Seal else Collect);
                  inline_single_thread_rc = single_thread;
                  mode; debug_info }
              in
              let* output = Pipeline.compile_file req in
              let ssa = Filename.concat work_target (base ^ ".ssa") in
              let asm = Filename.concat work_target (base ^ ".s") in
              write_file ssa output.ssa;
              let* () = run_cmd ~verbose ~stdout_file:asm qbe ["-t"; target.qbe_target; ssa] in
              (match output.interface with
               | Some cmi when cmi <> prefix ^ ".cmi" ->
                   write_if_changed (prefix ^ ".cmi") (read_file cmi)
               | _ -> ());
              write_exports_bin (prefix ^ ".exports_bin") output.exports;
              exports_ref := Some output.exports;
              Ok ()
            in
            let* exports, hit =
              match unit_store with
              | None ->
                  let exports_ref = ref None in
                  let* () = build_ml ~cmi_target:cmi_dir ~work_target:work_dir exports_ref in
                  let+ exports =
                    match !exports_ref with
                    | Some ex -> Ok ex
                    | None -> Error "missing compiled export summary"
                  in
                  exports, false
              | Some store ->
                  let* key =
                    unit_cache_key ~toolchain_key ~include_dirs ~available ~has_mli
                      ~publish_object step
                  in
                  let exports_ref = ref None in
                  let* entry =
                    Build_cache.ensure ~store ~key (fun dir ->
                      build_ml ~cmi_target:dir ~work_target:dir exports_ref)
                  in
                  copy_cached ~source:entry.directory ~destination:cmi_dir base
                    [".cmi"; ".exports_bin"];
                  copy_cached ~source:entry.directory ~destination:work_dir base
                    [".ssa"; ".s"];
                  let+ exports =
                    match !exports_ref with
                    | Some ex -> Ok ex
                    | None -> read_exports_bin (Filename.concat entry.directory (base ^ ".exports_bin"))
                  in
                  exports, entry.hit
            in
            let cmi = work_prefix ^ ".cmi" in
            let asm = Filename.concat work_dir (base ^ ".s") in
            let available =
              if Sys.file_exists cmi then Names.add step.modname cmi available else available
            in
            let object_interface =
              if publish_object && Sys.file_exists cmi then Some (step.modname, cmi, exports)
              else object_interface
            in
            if not hit then Gc.full_major ();
            compile_steps available ((step.modname, exports) :: imports) (asm :: assemblies)
              object_interface
              (compiled + if hit then 0 else 1) (hits + if hit then 1 else 0) rest
  in
  let imports =
    Stdlib_build.imports stdlib |> List.filter (fun (name, _) -> not (List.mem name local_units))
  in
  compile_steps Names.empty imports [] None 0 0 steps

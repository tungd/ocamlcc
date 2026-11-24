open Sys_util
open Result_syntax

module Names = Map.Make (String)
module Name_set = Set.Make (String)

type scope = {
  visible : string list;
  hidden : string list;
  archives : string list;
  package_keys : Sha256.t list;
}

type output = {
  objects : string list;
  units : string list;
  compiled : int;
  hits : int;
}

type event =
  | Start of int * string
  | Finish of int * string * bool

type layout = {
  map_name : string -> string;
  public : string -> bool;
  open_modules : string list;
  closed_aliases : string list;
}

let ordinary_layout = {
  map_name = Fun.id; public = (fun _ -> true); open_modules = []; closed_aliases = [];
}

let generate_alias file mappings =
  let body =
    List.map (fun (source, target) -> Printf.sprintf "module %s = %s\n" source target) mappings
    |> String.concat "" in
  write_if_changed file body

let wrapped_sources ~directory ~wrap ~exports sources =
  let names =
    List.map Pipeline.module_name_of_file sources |> List.sort_uniq String.compare
  in
  let internal = List.filter (fun name -> name <> wrap) names in
  let alias = wrap ^ "__" in
  let private_name name = alias ^ name in
  let map_name name = if List.mem name internal then private_name name else name in
  let source_dir = Filename.concat directory "aliases" in
  mkdir_p source_dir;
  let alias_path name = Filename.concat source_dir (String.uncapitalize_ascii name ^ ".ml") in
  let internal_alias = alias_path alias in
  let mappings = List.map (fun name -> (name, private_name name)) internal in
  generate_alias internal_alias mappings;
  let public_alias =
    if List.mem wrap names then []
    else
      let path = alias_path wrap in
      let mappings = if exports = [] then mappings
        else List.filter (fun (name, _) -> List.mem name exports) mappings in
      generate_alias path mappings;
      [path]
  in
  let layout =
    { map_name; public = String.equal wrap; open_modules = [alias];
      closed_aliases = alias :: (if public_alias = [] then [] else [wrap]) } in
  (layout, [internal_alias], public_alias)

let copy_artifacts source destination =
  Sys.readdir source |> Array.iter (fun name ->
    write_if_changed (Filename.concat destination name) (read_file (Filename.concat source name)))

let fingerprint_bytes label path =
  let+ sha = Sha256.file path in (label, Sha256.to_hex sha)

let read_refs available layout step =
  let* references = Dep_graph.references step in
  let rec discover seen files = function
    | [] -> Ok files
    | name :: rest ->
        let name = if Names.mem (layout.map_name name) available then layout.map_name name else name in
        if Name_set.mem name seen then discover seen files rest
        else
          let seen = Name_set.add name seen in
          match Names.find_opt name available with
          | None -> discover seen files rest
          | Some interface ->
              let* file = fingerprint_bytes (name ^ ".cmi") interface in
              let sidecar = Filename.remove_extension interface ^ ".exports" in
              let* files = if Sys.file_exists sidecar then
                  let+ metadata = fingerprint_bytes (name ^ ".exports") sidecar in metadata :: file :: files
                else Ok (file :: files) in
              let more =
                let info = Cmi_format.read_cmi interface in
                List.map fst info.cmi_crcs
              in
              discover seen files (more @ rest)
  in
  discover Name_set.empty [] (step.Dep_graph.Step.modname :: references)

let artifact_key ~tools ~scope ~layout available (step : Dep_graph.Step.t) =
  let* source = fingerprint_bytes "source" step.path in
  let* imported = read_refs available layout step in
  let deps = List.map (fun key -> "package", Sha256.to_hex key) scope.package_keys in
  let unit = layout.map_name step.modname in
  let role = match step.kind with `Mli -> "interface" | `Ml -> "implementation" in
  let key =
    Build_cache.key (["toolchain", Sha256.to_hex tools.Pkg_toolchain.fingerprint;
                     "unit", unit; "role", role; "path", step.path; source]
      @ deps @ List.sort compare imported)
  in
  Ok key

type step_output = {
  modname : string;
  kind : [ `Mli | `Ml ];
  path : string;
  prefix : string;
  object_file : string;
  hit : bool;
}

type task_output =
  | Ocaml_steps of step_output list
  | C_object of string

type node =
  | Ocaml_group of Dep_graph.Step.t list * int list
  | C_unit of int * string

let compile ~tools ~scope ~wrapping ~exports ?cache ?(cflags = [])
    ?(held = false) ?on_event ~sources ~c_sources ~directory () =
  mkdir_p directory;
  let layout, prelude, ending =
    match wrapping with
    | Ocpkg_format.Flat -> ordinary_layout, [], []
    | Wrapped wrap -> wrapped_sources ~directory ~wrap ~exports sources
  in
  let* dag_groups = Dep_graph.plan_build_dag sources in
  let alias_step path = { Dep_graph.Step.modname = Pipeline.module_name_of_file path; kind = `Ml; path } in
  let prelude_steps = List.map alias_step prelude in
  let ending_steps = List.map alias_step ending in
  let all_ocaml_steps =
    prelude_steps
    @ List.concat_map (fun (g : Dep_graph.Plan.group) -> g.steps) dag_groups
    @ ending_steps
  in
  let implementation_interfaces = List.fold_left (fun set (step : Dep_graph.Step.t) ->
      match step.kind with `Ml -> set | `Mli -> Name_set.add step.modname set)
      Name_set.empty all_ocaml_steps in
  let private_dir = Filename.concat directory "private" in
  if layout.open_modules <> [] then mkdir_p private_dir;
  let private_first = if layout.open_modules = [] then [] else [private_dir] in
  let include_dirs = private_first @ (directory :: tools.Pkg_toolchain.stdlib :: scope.visible) in
  let hide_dirs = scope.hidden in
  let stdlib_archive = Export_summary.find_archive tools.stdlib in
  let archives = Option.to_list stdlib_archive @ scope.archives in
  let local_units = List.map (fun (step : Dep_graph.Step.t) -> layout.map_name step.modname) all_ocaml_steps in
  let summaries = Some (Export_summary.Loader.create ~archives ~exclude_units:local_units ()) in
  let runtime_flags =
    Option.to_list (Option.map (fun dir -> "-I" ^ dir) (Target.runtime_sources None)) in
  let compile_unit available imports ?precomputed_key (step : Dep_graph.Step.t) =
    let modname = layout.map_name step.modname in
    let output_dir = if layout.public step.modname then directory else private_dir in
    let file_prefix = String.uncapitalize_ascii modname in
    let has_interface = Name_set.mem step.modname implementation_interfaces in
    let write target_dir =
      let prefix = Filename.concat target_dir file_prefix in
      let generated_alias = List.mem step.modname layout.closed_aliases in
      let request =
        { (Pipeline.Request.create ~filename:step.path ~modname) with
          include_dirs; hidden_include_dirs = hide_dirs; stdlib_dir = Some tools.stdlib;
          output_prefix = Some prefix; nostdlib = true; emit_cmi = not has_interface;
          emit_entry = false; no_alias_deps = layout.open_modules <> [];
          open_modules = if generated_alias then [] else layout.open_modules;
          inline_single_thread_rc = tools.single_thread;
          mode = tools.mode; debug_info = tools.debug_info;
          export_policy = Seal; summaries; imports }
      in
      if tools.verbose then Printf.eprintf "compile %s\n%!" step.path;
      match step.kind with
      | `Mli ->
          let+ _ = Pipeline.compile_interface_file request in ()
      | `Ml ->
          let* output = Pipeline.compile_file request in
          let ssa = prefix ^ ".ssa" in
          let obj = prefix ^ ".o" in
          write_file ssa output.ssa;
          let* () = Pkg_toolchain.assemble tools ssa obj in
          Sys.remove ssa;
          (match output.interface with
          | Some interface when interface <> prefix ^ ".cmi" ->
              write_if_changed (prefix ^ ".cmi") (read_file interface)
          | _ -> ());
          Export_summary.write_unit ~prefix output.exports;
          Export_summary.write_unit_object (prefix ^ ".opt");
          Ok ()
    in
    let* artifact_directory, hit = match cache with
      | None ->
          let+ () = write output_dir in (output_dir, false)
      | Some store ->
          let* key = match precomputed_key with
            | Some key -> Ok key
            | None -> artifact_key ~tools ~scope ~layout available step
          in
          let+ entry = Build_cache.ensure ~hasher:(Digest_index.hasher tools.index) ~store ~key write in
          copy_artifacts entry.directory output_dir;
          entry.directory, entry.hit
    in
    let prefix = Filename.concat output_dir file_prefix in
    Ok { modname; kind = step.kind; path = step.path; prefix;
         object_file = Filename.concat artifact_directory (file_prefix ^ ".o"); hit }
  in
  let prelude_nodes = List.map (fun s -> Ocaml_group ([s], [])) prelude_steps in
  let prelude_len = List.length prelude_nodes in
  let dag_nodes =
    List.map (fun (g : Dep_graph.Plan.group) ->
      let deps =
        (if prelude_len > 0 then [0] else [])
        @ List.map (fun d -> prelude_len + d) g.deps
      in
      Ocaml_group (g.steps, deps)) dag_groups
  in
  let ocaml_base_len = prelude_len + List.length dag_nodes in
  let ending_nodes =
    let all_deps = List.init ocaml_base_len Fun.id in
    List.map (fun s -> Ocaml_group ([s], all_deps)) ending_steps
  in
  let c_nodes = List.mapi (fun idx file -> C_unit (idx, file)) c_sources in
  let nodes = Array.of_list (prelude_nodes @ dag_nodes @ ending_nodes @ c_nodes) in
  let total_units = List.length all_ocaml_steps + List.length c_sources in
  let emit = match on_event with Some f -> f total_units | None -> fun _ -> () in
  let local_summaries = Export_summary.Loader.create () in
  let available_ref = ref Names.empty in
  let imports_ref = ref [] in
  let record_step out =
    available_ref := Names.add out.modname (out.prefix ^ ".cmi") !available_ref;
    match out.kind with
    | `Mli -> ()
    | `Ml ->
        match Export_summary.Loader.lookup local_summaries ~unit_name:out.modname ~cmi:(out.prefix ^ ".cmi") with
        | Some facts -> imports_ref := (out.modname, facts) :: !imports_ref
        | None -> ()
  in
  let node_label = function
    | Ocaml_group (step :: _, _) -> step.path
    | Ocaml_group ([], _) -> ""
    | C_unit (_, file) -> file
  in
  let deps i =
    match nodes.(i) with
    | Ocaml_group (_, ds) -> ds
    | C_unit _ -> []
  in
  let prepare i _results =
    match nodes.(i) with
    | C_unit (c_idx, file) ->
        let basename = Printf.sprintf "c%d_%s.o" c_idx (Filename.remove_extension (Filename.basename file)) in
        let obj = Filename.concat directory basename in
        Ok (`Run (fun _report ->
          if tools.verbose then Printf.eprintf "compile %s\n%!" file;
          let+ () = Pkg_toolchain.compile_c tools
              ~flags:(("-I" ^ Filename.dirname file) :: runtime_flags @ cflags) file obj in
          C_object obj))
    | Ocaml_group ([step], _) when Option.is_some cache -> (
        let store = Option.get cache in
        let available = !available_ref in
        let imports = !imports_ref in
        let* key = artifact_key ~tools ~scope ~layout available step in
        match Build_cache.peek ~hasher:(Digest_index.hasher tools.index) ~store ~key () with
        | Some entry ->
            let modname = layout.map_name step.modname in
            let output_dir = if layout.public step.modname then directory else private_dir in
            let file_prefix = String.uncapitalize_ascii modname in
            copy_artifacts entry.directory output_dir;
            let prefix = Filename.concat output_dir file_prefix in
            let object_file = Filename.concat entry.directory (file_prefix ^ ".o") in
            Ok (`Ready (Ocaml_steps [{ modname; kind = step.kind; path = step.path; prefix; object_file; hit = true }]))
        | None ->
            Ok (`Run (fun _report ->
              let+ out = compile_unit available imports ~precomputed_key:key step in
              Ocaml_steps [out])))
    | Ocaml_group (steps, _) ->
        let available = !available_ref in
        let imports = !imports_ref in
        Ok (`Run (fun _report ->
          let group_summaries = Export_summary.Loader.create () in
          let rec run_group avail imps acc = function
            | [] -> Ok (Ocaml_steps (List.rev acc))
            | step :: rest ->
                let* out = compile_unit avail imps step in
                let avail = Names.add out.modname (out.prefix ^ ".cmi") avail in
                let imps = match out.kind with
                  | `Mli -> imps
                  | `Ml ->
                      match Export_summary.Loader.lookup group_summaries ~unit_name:out.modname ~cmi:(out.prefix ^ ".cmi") with
                      | Some facts -> (out.modname, facts) :: imps
                      | None -> imps
                in
                run_group avail imps (out :: acc) rest
          in
          run_group available imports [] steps))
  in
  let on_start i = emit (Start (i, node_label nodes.(i))) in
  let on_done i = function
    | Ocaml_steps outs ->
        List.iter (fun out ->
          record_step out;
          emit (Finish (i, out.path, out.hit))) outs
    | C_object _ ->
        emit (Finish (i, node_label nodes.(i), false))
  in
  let+ outputs =
    Pkg_parallel.run_dag ~pool:tools.pool ~held ~index:tools.index
      ~on_start ~on_done ~deps ~prepare (Array.length nodes)
  in
  let objects = ref [] in
  let units = ref [] in
  let compiled = ref 0 in
  let hits = ref 0 in
  Array.iter (function
    | Ocaml_steps outs ->
        List.iter (fun out ->
          if out.hit then incr hits else incr compiled;
          match out.kind with
          | `Mli -> ()
          | `Ml ->
              objects := out.object_file :: !objects;
              units := out.modname :: !units) outs
    | C_object obj ->
        objects := obj :: !objects;
        incr compiled) outputs;
  { objects = List.rev !objects; units = List.rev !units; compiled = !compiled; hits = !hits }

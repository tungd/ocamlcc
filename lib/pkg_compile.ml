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

let compile ~tools ~scope ~wrapping ~exports ?cache ?(cflags = []) ~sources ~c_sources ~directory () =
  mkdir_p directory;
  let layout, prelude, ending =
    match wrapping with
    | Ocpkg_format.Flat -> ordinary_layout, [], []
    | Wrapped wrap -> wrapped_sources ~directory ~wrap ~exports sources
  in
  let* steps = Dep_graph.plan_build_order sources in
  let alias_step path = { Dep_graph.Step.modname = Pipeline.module_name_of_file path; kind = `Ml; path } in
  let steps = List.map alias_step prelude @ steps @ List.map alias_step ending in
  let implementation_interfaces = List.fold_left (fun set (step : Dep_graph.Step.t) ->
      match step.kind with `Ml -> set | `Mli -> Name_set.add step.modname set)
      Name_set.empty steps in
  let private_dir = Filename.concat directory "private" in
  if layout.open_modules <> [] then mkdir_p private_dir;
  let private_first = if layout.open_modules = [] then [] else [private_dir] in
  let include_dirs = private_first @ (directory :: tools.Pkg_toolchain.stdlib :: scope.visible) in
  let hide_dirs = scope.hidden in
  let stdlib_archive = Export_summary.find_archive tools.stdlib in
  let archives = Option.to_list stdlib_archive @ scope.archives in
  let local_units = List.map (fun (step : Dep_graph.Step.t) -> layout.map_name step.modname) steps in
  let summaries = Some (Export_summary.Loader.create ~archives ~exclude_units:local_units ()) in
  let initial = {objects = []; units = []; compiled = 0; hits = 0} in
  let runtime_flags =
    Option.to_list (Option.map (fun dir -> "-I" ^ dir) (Target.runtime_sources None)) in
  let compile_unit available imports (step : Dep_graph.Step.t) =
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
          let* key = artifact_key ~tools ~scope ~layout available step in
          let+ entry = Build_cache.ensure ~index:tools.index ~store ~key write in
          copy_artifacts entry.directory output_dir;
          entry.directory, entry.hit
    in
    let prefix = Filename.concat output_dir file_prefix in
    Ok (modname, prefix, Filename.concat artifact_directory (file_prefix ^ ".o"), hit)
  in
  let local_summaries = Export_summary.Loader.create () in
  let rec compile_steps available imports output = function
    | [] -> Ok output
    | (step : Dep_graph.Step.t) :: rest ->
        let* modname, prefix, object_file, hit = compile_unit available imports step in
        let available = Names.add modname (prefix ^ ".cmi") available in
        let output = {output with
          compiled = output.compiled + (if hit then 0 else 1);
          hits = output.hits + (if hit then 1 else 0) } in
        let output = match step.kind with
          | `Mli -> output
          | `Ml -> {output with objects = object_file :: output.objects;
                                units = modname :: output.units}
        in
        let imports = match step.kind with
          | `Mli -> imports
          | `Ml ->
              match Export_summary.Loader.lookup local_summaries ~unit_name:modname ~cmi:(prefix ^ ".cmi") with
              | Some facts -> (modname, facts) :: imports
              | None -> imports
        in
        compile_steps available imports output rest
  in
  let* output = compile_steps Names.empty [] initial steps in
  let rec compile_native index output = function
    | [] -> Ok {output with objects = List.rev output.objects; units = List.rev output.units}
    | file :: rest ->
        let basename = Printf.sprintf "c%d_%s.o" index (Filename.remove_extension (Filename.basename file)) in
        let build path =
          if tools.verbose then Printf.eprintf "compile %s\n%!" file;
          Pkg_toolchain.compile_c tools
            ~flags:(("-I" ^ Filename.dirname file) :: runtime_flags @ cflags) file (Filename.concat path basename)
        in
        let* artifact_directory, hit = match cache with
          | None -> let+ () = build directory in (directory, false)
          | Some store ->
              let headers =
                let dir = Filename.dirname file in
                Sys.readdir dir |> Array.to_list |> List.filter (fun name -> Filename.check_suffix name ".h")
                |> List.sort String.compare |> List.map (Filename.concat dir)
              in
              let* digests = Build_cache.fingerprints (file :: headers) in
              let key = Build_cache.key (["toolchain", Sha256.to_hex tools.fingerprint; "output", basename] @ digests) in
              let+ entry = Build_cache.ensure ~index:tools.index ~store ~key build in
              copy_artifacts entry.directory directory;
              entry.directory, entry.hit
        in
        let output = {output with objects = Filename.concat artifact_directory basename :: output.objects;
          compiled = output.compiled + (if hit then 0 else 1);
          hits = output.hits + (if hit then 1 else 0) } in
        compile_native (index + 1) output rest
  in
  compile_native 0 output c_sources

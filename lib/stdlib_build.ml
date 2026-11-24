open Sys_util
open Result_syntax

type compiled_unit = {
  prefix : string;
  exports : Anf.exports;
  modname : string;
}

type t =
  | Disabled
  | Unavailable
  | Prebuilt of { directory : string; objects : string list }
  | Compiled of { directory : string; units : compiled_unit list }

type source = {
  filename : string;
  prefix : string;
  flags : string list;
}

let interface_dir = function
  | Disabled | Unavailable -> None
  | Prebuilt { directory; _ } | Compiled { directory; _ } -> Some directory

let archive = function
  | Prebuilt { objects = [archive]; _ } when Filename.check_suffix archive ".a" ->
      Some archive
  | _ -> None

let imports = function
  | Compiled { units; _ } -> List.map (fun unit -> unit.modname, unit.exports) units
  | _ -> []

let identifier name =
  name <> "" && String.for_all (function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false) name

let unpack path directory =
  let read input =
    let invalid () = failwith ("invalid standard library source bundle: " ^ path) in
    if input_line input <> "occ-stdlib-sources-v1" then invalid ();
    let rec read_sources seen sources =
      match input_line input with
      | exception End_of_file -> List.rev sources
      | header ->
          match String.split_on_char ' ' header with
          | [name; prefix; flags; size] ->
              let base, ext = Filename.remove_extension name, Filename.extension name in
              if not (identifier base && identifier prefix
                      && (ext = ".ml" || ext = ".mli") && not (List.mem name seen))
              then invalid ();
              let size = match int_of_string_opt size with
                | Some size when size >= 0 && size <= in_channel_length input - pos_in input ->
                    size
                | _ -> invalid ()
              in
              let flags = if flags = "-" then [] else String.split_on_char ',' flags in
              let filename = Filename.concat directory name in
              write_if_changed filename (really_input_string input size);
              read_sources (name :: seen) ({ filename; prefix; flags } :: sources)
          | _ -> invalid ()
    in
    read_sources [] []
  in
  try Ok (In_channel.with_open_bin path read) with
  | End_of_file -> Error ("truncated standard library source bundle: " ^ path)
  | Failure msg | Sys_error msg -> Error msg

let compile ?on_step ~directory path =
  let source_dir = Filename.concat directory "src" in
  mkdir_p source_dir;
  let* sources = unpack path source_dir in
  let total = List.length sources in
  let rec units index compiled imports = function
    | [] -> Ok (Compiled { directory; units = List.rev compiled })
    | { filename; prefix; flags } :: rest ->
        Option.iter (fun f -> f (index + 1) total (Filename.basename filename)) on_step;
        let has_flag = Fun.flip List.mem flags in
        let prefix = Filename.concat directory prefix in
        let modname = Pipeline.module_name_of_file (prefix ^ ".ml") in
        let request =
          { (Pipeline.Request.create ~filename ~modname) with
            include_dirs = [directory]; output_prefix = Some prefix;
            nopervasives = has_flag "--nopervasives"; nostdlib = true;
            no_alias_deps = has_flag "--no-alias-deps";
            nolabels = has_flag "--nolabels" }
        in
        let result =
          if Filename.check_suffix filename ".mli" then
            let* _ = Pipeline.compile_interface_file request in
            units (index + 1) compiled imports rest
          else
            let request =
              { request with emit_cmi = not (Sys.file_exists (prefix ^ ".cmi")
                    && Sys.file_exists (Filename.remove_extension filename ^ ".mli"));
                emit_entry = false; stdlib_dir = Some directory; imports;
                export_policy = Seal }
            in
            let* output = Pipeline.compile_file request in
            write_file (prefix ^ ".ssa") output.ssa;
            let exports = output.exports in
            units (index + 1) ({ prefix; exports; modname } :: compiled)
              ((modname, exports) :: imports) rest
        in
        result
  in
  units 0 [] [] sources

let prebuilt directory ~prefer_archive =
  if not (Sys.file_exists (Filename.concat directory "stdlib.cmi")) then None
  else
    let objects =
      match (if prefer_archive then Export_summary.find_archive directory else None) with
      | Some archive -> [archive]
      | None ->
          Sys.readdir directory |> Array.to_list
          |> List.filter (fun file -> Filename.check_suffix file ".o")
          |> List.sort String.compare
          |> List.map (Filename.concat directory)
    in
    if objects = [] then None else Some (Prebuilt { directory; objects })

let prepare ~disabled ~prefer_prebuilt ~prefer_archive ~sources ~prebuilt:directory ~work_dir =
  if disabled then Ok Disabled
  else
    let candidate = if prefer_prebuilt then
        Option.bind (Target.prebuilt_stdlib directory) (prebuilt ~prefer_archive)
      else None
    in
    match candidate with
    | Some plan -> Ok plan
    | None ->
        match Target.stdlib_sources sources with
        | Some path -> compile ~directory:(Filename.concat work_dir "stdlib") path
        | None -> Ok Unavailable

let link_inputs ?parallel ~verbose ~qbe ~(target : Target.t) ~toolchain = function
  | Disabled | Unavailable -> Ok []
  | Prebuilt { objects; _ } -> Ok objects
  | Compiled { units; _ } ->
      let build_unit { prefix; exports; modname } =
        modname, (fun () ->
          let asm = prefix ^ ".s" in
          let obj = prefix ^ ".o" in
          let* () = run_cmd ~verbose ~stdout_file:asm qbe
              ["-t"; target.qbe_target; prefix ^ ".ssa"] in
          let* () = Linker.compile_source ~verbose toolchain [] asm obj in
          Export_summary.write_unit ~prefix exports;
          Export_summary.write_unit_object (prefix ^ ".opt");
          Ok obj)
      in
      let tasks = List.map build_unit units in
      match parallel with
      | Some run -> run tasks
      | None ->
          let rec seq acc = function
            | [] -> Ok (List.rev acc)
            | (_, f) :: rest ->
                let* obj = f () in
                seq (obj :: acc) rest
          in
          seq [] tasks

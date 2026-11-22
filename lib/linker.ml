open Sys_util
open Result_syntax

type mode = Static | Executable | Shared of string list option

module Request = struct
  type t = {
    mode : mode;
    target : Target.t;
    toolchain : Target.Toolchain.t;
    work_dir : string;
    output : string;
    user_objects : string list;
    internal_objects : string list;
    extra_ldflags : string list;
    verbose : bool;
  }
end

let compile_source ~verbose (tc : Target.Toolchain.t) extra_flags src obj =
  let args = tc.cc_base_args @ extra_flags @ ["-c"; src; "-o"; obj] in
  run_cmd ~verbose tc.cc_prog args

let compile_many ~verbose ~work_dir toolchain flags sources =
  let rec compile objects index = function
    | [] -> Ok (List.rev objects)
    | source :: rest ->
        let base = Filename.chop_extension (Filename.basename source) in
        let object_file = Filename.concat work_dir (Printf.sprintf "u_%d_%s.o" index base) in
        let* () = compile_source ~verbose toolchain flags source object_file in
        compile (object_file :: objects) (index + 1) rest
  in
  compile [] 0 sources

let archive ~verbose (tc : Target.Toolchain.t) output objects =
  if Sys.file_exists output then Sys.remove output;
  run_cmd ~verbose tc.ar_prog (["rcs"; output] @ objects)

let write_lines path lines = write_file path (String.concat "\n" lines ^ "\n")

let visibility (request : Request.t) exports =
  let internal = request.internal_objects in
  let objects = request.user_objects @ internal in
  let in_work_dir = Filename.concat request.work_dir in
  match request.target.os, exports with
  | (Darwin | Ios | Ios_sim), Some symbols ->
      let path = in_work_dir "exports.txt" in
      write_lines path (List.map ((^) "_") (List.sort_uniq String.compare symbols));
      Ok (objects, ["-Wl,-exported_symbols_list," ^ path])
  | (Linux | Android), Some symbols ->
      let path = in_work_dir "exports.ver" in
      let symbols = List.sort_uniq String.compare symbols in
      let lines = List.map (fun symbol -> "    " ^ symbol ^ ";") symbols in
      write_lines path (["{"; "  global:"] @ lines @ ["  local:"; "    *;"; "};"]);
      Ok (objects, ["-Wl,--version-script=" ^ path])
  | Windows, _ -> Ok (objects, [])
  | _, None when internal = [] -> Ok (objects, [])
  | (Darwin | Ios | Ios_sim), None ->
      let* raw = capture_cmd "nm" ("-gUj" :: internal) in
      let symbols =
        String.split_on_char '\n' raw
        |> List.map String.trim
        |> List.filter (fun name -> name <> "" && not (String.ends_with ~suffix:":" name))
        |> List.sort_uniq String.compare
      in
      if symbols = [] then Ok (objects, [])
      else
        let path = in_work_dir "unexports.txt" in
        write_lines path symbols;
        Ok (objects, ["-Wl,-unexported_symbols_list," ^ path])
  | (Linux | Android), None ->
      let internal_archive = in_work_dir "libocaml_internal.a" in
      let* () = archive ~verbose:request.verbose request.toolchain internal_archive internal in
      Ok (request.user_objects @ [internal_archive], ["-Wl,--exclude-libs,ALL"])

let link (request : Request.t) =
  let { Request.mode; target; toolchain; output; user_objects; internal_objects;
        extra_ldflags; verbose; _ } = request in
  let objects = user_objects @ internal_objects in
  let link_c_driver mode objects flags =
    let platform =
      match target.os with
      | Windows -> []
      | Linux -> ["-lm"; "-pthread"]
      | Darwin | Ios | Ios_sim | Android -> ["-lm"]
    in
    let args =
      toolchain.cc_base_args @ mode @ objects @ flags @ platform @ extra_ldflags
      @ ["-o"; output]
    in
    let+ () = run_cmd ~verbose toolchain.cc_prog args in
    output
  in
  match mode with
  | Static ->
      let+ () = archive ~verbose toolchain output objects in
      output
  | Executable -> link_c_driver [] objects []
  | Shared exports ->
      let* objects, flags = visibility request exports in
      link_c_driver ["-shared"] objects flags

let xcframework ?header_dirs ~verbose ~work_dir ~output ~header libraries =
  if Sys.file_exists output then rm_rf output;
  let headers =
    match header with
    | None -> []
    | Some source ->
        let dir = Filename.concat work_dir "xcf_headers" in
        mkdir_p dir;
        write_file (Filename.concat dir (Filename.basename source)) (read_file source);
        ["-headers"; dir]
  in
  let libraries =
    match header_dirs with
    | None -> List.concat_map (fun file -> ["-library"; file] @ headers) libraries
    | Some dirs ->
        List.concat (List.map2 (fun file dir ->
          ["-library"; file] @ Option.fold ~none:[] ~some:(fun dir -> ["-headers"; dir]) dir)
          libraries dirs)
  in
  let args = ["-create-xcframework"] @ libraries @ ["-output"; output] in
  let stdout_file = if verbose then None else Some "/dev/null" in
  let+ () = run_cmd ~verbose ?stdout_file "xcodebuild" args in
  output

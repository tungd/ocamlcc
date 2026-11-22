open Sys_util
open Result_syntax

type t = {
  target : Target.t;
  commands : Target.Toolchain.t;
  qbe : string;
  stdlib : string;
  fingerprint : Sha256.t;
  single_thread : bool;
  cflags : string list;
  verbose : bool;
  cache : string;
  index : Digest_index.t;
}

let self () =
  let executable = Sys.executable_name in
  let executable =
    if Filename.is_implicit executable then
      Option.value (find_in_path executable) ~default:executable
    else executable
  in
  executable

let compiler_binary () =
  let executable = self () in
  let sibling = Filename.concat (Filename.dirname executable) in
  let names = if Filename.basename executable = "ocpkg_main.exe" then ["occ"; "main.exe"] else ["occ"] in
  match List.find_opt Sys.file_exists (List.map sibling names) with
  | Some _ as compiler -> compiler
  | None -> find_in_path "occ"

let matching_files directory extensions =
  if not (Sys.file_exists directory && Sys.is_directory directory) then []
  else
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun name -> List.exists (Filename.check_suffix name) extensions)
    |> List.sort String.compare |> List.map (Filename.concat directory)

let require what = function Some file -> Ok file | None -> Error ("cannot locate " ^ what)

let archive_tool ~verbose tc path objects =
  run_cmd ~verbose tc.Target.Toolchain.ar_prog (["rcs"; path] @ objects)

let assemble tools ssa output =
  let asm = Filename.remove_extension output ^ ".s" in
  let* () = run_cmd ~verbose:tools.verbose ~stdout_file:asm tools.qbe
      ["-t"; tools.target.qbe_target; ssa] in
  let flags = if tools.target.os = Windows then [] else ["-fPIC"] in
  let+ () = Linker.compile_source ~verbose:tools.verbose tools.commands flags asm output in
  Sys.remove asm

let compile_c tools ~flags input output =
  let pic = if tools.target.os = Windows then [] else ["-fPIC"] in
  Linker.compile_source ~verbose:tools.verbose tools.commands (pic @ tools.cflags @ flags) input output

let archive tools path objects = archive_tool ~verbose:tools.verbose tools.commands path objects

let copy_into directory source =
  let target = Filename.concat directory (Filename.basename source) in
  write_file target (read_file source)

let pack_stdlib ~index ~cache ~stdlib_source ~fingerprint ~qbe ~target ~commands ~verbose =
  let store = Filename.concat cache "stdlib" in
  let+ entry =
    Build_cache.ensure ~index ~store ~key:fingerprint (fun destination ->
      let work = Filename.temp_dir "occ-stdlib-" "" in
      Fun.protect ~finally:(fun () -> rm_rf work) (fun () ->
        let* plan = Stdlib_build.prepare ~disabled:false ~prefer_prebuilt:false ~prefer_archive:false
            ~sources:(Some stdlib_source) ~prebuilt:None ~work_dir:work in
        let* directory = Stdlib_build.interface_dir plan |> require "stdlib interfaces" in
        let* objects = Stdlib_build.link_inputs ~verbose ~qbe ~target ~toolchain:commands plan in
        let archive = Filename.concat destination "libocamlstdlib.a" in
        let* () = archive_tool ~verbose commands archive objects in
        let opts = List.map (fun obj -> Filename.remove_extension obj ^ ".opt") objects in
        Export_summary.write_archive ~archive ~units:opts;
        List.iter (copy_into destination)
          (matching_files directory [".cmi"; ".o"; ".exports"]);
        Ok ())) in
  entry.directory

module Stdlib_input = struct
  type t = Prebuilt of string | Source of string

  let files = function
    | Prebuilt directory -> matching_files directory [".cmi"; ".a"; ".a.opt"; ".o"; ".exports"]
    | Source path -> [path]
end

let prepare ~index ~cache ~target:name ~single_thread ~cflags ~verbose =
  let* target = Target.resolve name in
  let* qbe = Target.qbe None in
  let* commands = Target.toolchain target in
  let* compiler = compiler_binary () |> require "occ" in
  let host = Target.is_host target in
  let* stdlib_input =
    match Target.prebuilt_stdlib None with
    | Some dir when host && Sys.file_exists (Filename.concat dir "stdlib.cmi")
                        && Option.is_some (Export_summary.find_archive dir) ->
        Ok (Stdlib_input.Prebuilt dir)
    | _ ->
        let+ source = Target.stdlib_sources None |> require "standard library sources" in
        Stdlib_input.Source source
  in
  let rt_sources = Option.fold ~none:[] ~some:(fun dir ->
        matching_files dir [".c"; ".h"; ".inc"; ".S"]) (Target.runtime_sources None) in
  let rt_objects =
    if host then
      Option.fold ~none:[] ~some:(fun dir -> matching_files dir [".a"; ".o"])
        (Target.prebuilt_runtime ~single_thread None)
    else []
  in
  let* digests = Build_cache.fingerprints ~index
      (compiler :: self () :: qbe :: Stdlib_input.files stdlib_input @ rt_sources @ rt_objects) in
  let options =
    ["schema", "1"; "target", target.name; "qbe-target", target.qbe_target;
     "rc", string_of_bool single_thread; "cc", commands.cc_prog; "ar", commands.ar_prog]
    @ List.map (fun flag -> "cc-base", flag) commands.cc_base_args
    @ List.map (fun flag -> "cflag", flag) cflags
  in
  let fingerprint = Build_cache.key (options @ digests) in
  let* stdlib, fingerprint = match stdlib_input with
    | Prebuilt directory -> Ok (directory, fingerprint)
    | Source stdlib_source ->
        let* stdlib =
          pack_stdlib ~index ~cache ~stdlib_source ~fingerprint ~qbe ~target ~commands ~verbose in
        let+ artifacts = Build_cache.fingerprints ~index (matching_files stdlib [".cmi"; ".a"; ".a.opt"]) in
        stdlib, Build_cache.key (("source toolchain", Sha256.to_hex fingerprint) :: artifacts)
  in
  Ok {target; commands; qbe; stdlib; fingerprint; single_thread; cflags; verbose; cache; index}

let runtime tools ~include_main =
  let key = Build_cache.key
      ["toolchain", Sha256.to_hex tools.fingerprint; "main", string_of_bool include_main] in
  let store = Filename.concat tools.cache "runtime" in
  let+ entry = Build_cache.ensure ~index:tools.index ~store ~key (fun directory ->
    let work = Filename.temp_dir "occ-runtime-" "" in
    Fun.protect ~finally:(fun () -> rm_rf work) (fun () ->
      let* inputs = Runtime_build.link_inputs
          { single_thread = tools.single_thread; prefer_prebuilt = Target.is_host tools.target;
            include_main; prebuilt_dir = None; source_dir = None; work_dir = work;
            toolchain = tools.commands; verbose = tools.verbose } in
      List.iter (copy_into directory) inputs;
      Ok ())) in
  matching_files entry.directory [".a"; ".o"]

let stdlib_link_inputs tools ~archive =
  match (if archive then Export_summary.find_archive tools.stdlib else None) with
  | Some library -> [library]
  | None -> matching_files tools.stdlib [".o"]

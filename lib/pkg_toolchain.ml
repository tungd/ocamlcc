open Sys_util
open Result_syntax

type t = {
  target : Target.t;
  commands : Target.Toolchain.t;
  qbe : string;
  stdlib : string;
  fingerprint : Sha256.t;
  single_thread : bool;
  mode : Build_mode.t;
  debug_info : bool;
  cflags : string list;
  verbose : bool;
  cache : string;
  index : Digest_index.t;
  pool : Pkg_parallel.Pool.t;
  progress : Pkg_progress.t;
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
  let pic = if tools.target.os = Windows then [] else ["-fPIC"] in
  let mode_flags = Build_mode.cflags ~debug_info:tools.debug_info tools.mode in
  let flags = pic @ mode_flags @ tools.cflags in
  let+ () = Linker.compile_source ~verbose:tools.verbose tools.commands flags asm output in
  Sys.remove asm

let compile_c tools ~flags input output =
  let pic = if tools.target.os = Windows then [] else ["-fPIC"] in
  let mode_flags = Build_mode.cflags ~debug_info:tools.debug_info tools.mode in
  Linker.compile_source ~verbose:tools.verbose tools.commands (pic @ mode_flags @ tools.cflags @ flags) input output

let archive tools path objects = archive_tool ~verbose:tools.verbose tools.commands path objects

let copy_into directory source =
  let target = Filename.concat directory (Filename.basename source) in
  write_file target (read_file source)

let parallel_run ~pool ~held ~progress ~prefix ~summary_label tasks =
  let total = List.length tasks in
  let scope = Pkg_progress.start_scope progress ~prefix ~total in
  let names = Array.of_list (List.map fst tasks) in
  let fns = List.map (fun (_, f) -> fun _report -> f ()) tasks in
  let started = Unix.gettimeofday () in
  let res =
    Pkg_parallel.map ~pool ~held
      ~on_start:(fun i -> Pkg_progress.task_started scope ~id:i ~name:names.(i))
      ~on_done:(fun i _ -> Pkg_progress.task_finished ~id:i ~cached:false scope)
      fns
  in
  let elapsed = Pkg_progress.format_duration (Unix.gettimeofday () -. started) in
  let summary =
    match res with
    | Ok _ -> Some (Printf.sprintf "Built %s (%d units, %s)" summary_label total elapsed)
    | Error _ -> None
  in
  Pkg_progress.end_scope ?summary scope;
  res

let pack_stdlib ~pool ~held ~progress ~index ~cache ~stdlib_source ~fingerprint ~mode ~debug_info ~qbe ~target ~commands ~verbose =
  let store = Filename.concat cache "stdlib" in
  let+ entry =
    Build_cache.ensure ~hasher:(Digest_index.hasher index) ~store ~key:fingerprint (fun destination ->
      let work = Filename.temp_dir "occ-stdlib-" "" in
      Fun.protect ~finally:(fun () -> rm_rf work) (fun () ->
        let started = Unix.gettimeofday () in
        let compile_scope = ref None in
        let prev_idx = ref (-1) in
        let on_step idx total name =
          let s = match !compile_scope with
            | Some s -> s
            | None ->
                let s = Pkg_progress.start_scope progress ~prefix:"stdlib" ~total in
                compile_scope := Some s;
                s
          in
          if !prev_idx >= 0 then Pkg_progress.task_finished ~id:!prev_idx ~cached:false s;
          prev_idx := idx - 1;
          Pkg_progress.task_started s ~id:(idx - 1) ~name
        in
        let* plan = Stdlib_build.compile ~on_step ~mode ~debug_info
            ~directory:(Filename.concat work "stdlib") stdlib_source in
        Option.iter (fun s ->
          if !prev_idx >= 0 then Pkg_progress.task_finished ~id:!prev_idx ~cached:false s;
          Pkg_progress.end_scope s) !compile_scope;
        let* directory = Stdlib_build.interface_dir plan |> require "stdlib interfaces" in
        let* objects =
          Stdlib_build.link_inputs
            ~parallel:(parallel_run ~pool ~held ~progress ~prefix:"stdlib-asm" ~summary_label:"standard library")
            ~mode ~debug_info ~verbose ~qbe ~target ~toolchain:commands plan
        in
        let archive = Filename.concat destination "libocamlstdlib.a" in
        let* () = archive_tool ~verbose commands archive objects in
        let opts = List.map (fun obj -> Filename.remove_extension obj ^ ".opt") objects in
        Export_summary.write_archive ~archive ~units:opts;
        List.iter (copy_into destination)
          (matching_files directory [".cmi"; ".o"; ".exports"]);
        let elapsed = Pkg_progress.format_duration (Unix.gettimeofday () -. started) in
        Pkg_progress.milestone progress (Printf.sprintf "Prepared standard library (%s)" elapsed);
        Ok ())) in
  entry.directory

module Stdlib_input = struct
  type t = Prebuilt of string | Source of string

  let files = function
    | Prebuilt directory -> matching_files directory [".cmi"; ".a"; ".a.opt"; ".o"; ".exports"]
    | Source path -> [path]
end

let prepare ~index ~cache ~target:name ~single_thread ~cflags ~verbose
    ?(mode = Build_mode.Release) ?debug_info ?pool ?(held = false) ?progress () =
  let debug_info = match debug_info with Some b -> b | None -> mode = Build_mode.Debug in
  let pool = match pool with Some p -> p | None -> Pkg_parallel.Pool.create 1 in
  let progress = match progress with Some p -> p | None -> Pkg_progress.create ~enabled:false ~verbose in
  let* target = Target.resolve name in
  let* qbe = Target.qbe None in
  let* commands = Target.toolchain target in
  let* compiler = compiler_binary () |> require "occ" in
  let host = Target.is_host target in
  let allow_prebuilt = host && mode = Build_mode.Release && not debug_info in
  let* stdlib_input =
    match Target.prebuilt_stdlib None with
    | Some dir when allow_prebuilt && Sys.file_exists (Filename.concat dir "stdlib.cmi")
                        && Option.is_some (Export_summary.find_archive dir) ->
        Ok (Stdlib_input.Prebuilt dir)
    | _ ->
        let+ source = Target.stdlib_sources None |> require "standard library sources" in
        Stdlib_input.Source source
  in
  let rt_sources = Option.fold ~none:[] ~some:(fun dir ->
        matching_files dir [".c"; ".h"; ".inc"; ".S"]
        @ matching_files (Filename.concat dir "caml") [".h"]) (Target.runtime_sources None) in
  let rt_objects =
    if allow_prebuilt then
      Option.fold ~none:[] ~some:(fun dir -> matching_files dir [".a"; ".o"])
        (Target.prebuilt_runtime ~single_thread None)
    else []
  in
  let hasher = Digest_index.hasher index in
  let* digests = Build_cache.fingerprints ~hasher
      (compiler :: self () :: qbe :: Stdlib_input.files stdlib_input @ rt_sources @ rt_objects) in
  let options =
    ["schema", "1"; "target", target.name; "qbe-target", target.qbe_target;
     "rc", string_of_bool single_thread; "mode", Build_mode.to_string mode;
     "debug-info", string_of_bool debug_info;
     "cc", commands.cc_prog; "ar", commands.ar_prog]
    @ List.map (fun flag -> "cc-base", flag) commands.cc_base_args
    @ List.map (fun flag -> "cflag", flag) cflags
  in
  let fingerprint = Build_cache.key (options @ digests) in
  let* stdlib, fingerprint = match stdlib_input with
    | Prebuilt directory -> Ok (directory, fingerprint)
    | Source stdlib_source ->
        let* stdlib =
          pack_stdlib ~pool ~held ~progress ~index ~cache ~stdlib_source ~fingerprint ~mode ~debug_info ~qbe ~target ~commands ~verbose in
        let+ artifacts = Build_cache.fingerprints ~hasher (matching_files stdlib [".cmi"; ".a"; ".a.opt"]) in
        stdlib, Build_cache.key (("source toolchain", Sha256.to_hex fingerprint) :: artifacts)
  in
  Ok {target; commands; qbe; stdlib; fingerprint; single_thread; mode; debug_info; cflags; verbose; cache; index; pool; progress}

let runtime ?(held = false) tools ~include_main =
  let key = Build_cache.key
      ["toolchain", Sha256.to_hex tools.fingerprint; "main", string_of_bool include_main] in
  let store = Filename.concat tools.cache "runtime" in
  let+ entry = Build_cache.ensure ~hasher:(Digest_index.hasher tools.index) ~store ~key (fun directory ->
    let work = Filename.temp_dir "occ-runtime-" "" in
    Fun.protect ~finally:(fun () -> rm_rf work) (fun () ->
      let* inputs = Runtime_build.link_inputs
          ~parallel:(parallel_run ~pool:tools.pool ~held ~progress:tools.progress ~prefix:"runtime" ~summary_label:"runtime")
          ~mode:tools.mode ~debug_info:tools.debug_info ~extra_cflags:tools.cflags
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

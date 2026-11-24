open Sys_util

module Request = struct
  type t = {
    single_thread : bool;
    prefer_prebuilt : bool;
    include_main : bool;
    prebuilt_dir : string option;
    source_dir : string option;
    work_dir : string;
    toolchain : Target.Toolchain.t;
    verbose : bool;
  }
end

let runtime_parts = [ "slab.c"; "cycle.c"; "weak.c"; "primitives.c" ]

let runtime_units ~split ~include_main =
  [ "pal.c"; "pal_ctx.S"; "arc.c" ]
  @ (if split then runtime_parts else [])
  @ [ "closure.c"; "fiber.c"; "builtins.c" ]
  @ (if include_main then [ "main_entry.c" ] else [])

let runtime_sources ~include_main dir =
  runtime_units ~split:true ~include_main |> List.map (Filename.concat dir)

let runtime_objects ~include_main dir =
  let object_path unit = Filename.concat dir (Filename.remove_extension unit ^ ".o") in
  (* Accept object directories from the same ABI before the source split. *)
  let split = List.exists (fun unit -> Sys.file_exists (object_path unit)) runtime_parts in
  runtime_units ~split ~include_main |> List.map object_path

let compile_runtime_objs ?parallel ~verbose (tc : Target.Toolchain.t) ~include_main
    ~single_thread ~mode ~debug_info ~extra_cflags runtime_dir out_dir =
  mkdir_p out_dir;
  let srcs = runtime_sources ~include_main runtime_dir in
  let mode_flags = Build_mode.cflags ~debug_info mode in
  let tasks =
    List.map (fun src ->
      let base_file = Filename.basename src in
      let base = Filename.chop_extension base_file in
      let obj = Filename.concat out_dir (base ^ ".o") in
      let flags =
        if Filename.check_suffix src ".S" then []
        else
          let flags = ["-std=c11"] @ mode_flags @ ["-fPIC"; "-I" ^ runtime_dir] @ extra_cflags in
          if single_thread && List.mem base_file ("arc.c" :: "fiber.c" :: runtime_parts)
          then "-DOCAMLCC_SINGLE_THREAD_RC" :: flags else flags
      in
      base_file, (fun () ->
        match Linker.compile_source ~verbose tc flags src obj with
        | Error _ as e -> e
        | Ok () -> Ok obj)) srcs
  in
  match parallel with
  | Some run -> run tasks
  | None ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | (_, f) :: rest ->
            match f () with
            | Error _ as e -> e
            | Ok obj -> go (obj :: acc) rest
      in
      go [] tasks

let header_files dir =
  let caml_dir = Filename.concat dir "caml" in
  let base_headers =
    if Sys.file_exists dir && Sys.is_directory dir then
      Sys.readdir dir |> Array.to_list
      |> List.filter (fun name ->
             Filename.check_suffix name ".h" || Filename.check_suffix name ".inc")
      |> List.sort String.compare |> List.map (Filename.concat dir)
    else []
  in
  let caml_headers =
    if Sys.file_exists caml_dir && Sys.is_directory caml_dir then
      Sys.readdir caml_dir |> Array.to_list
      |> List.filter (fun name -> Filename.check_suffix name ".h")
      |> List.sort String.compare |> List.map (Filename.concat caml_dir)
    else []
  in
  base_headers @ caml_headers

let link_inputs ?parallel ?(mode = Build_mode.Release) ?debug_info
    ?(extra_cflags = []) ?cache_dir (request : Request.t) =
  let open Result_syntax in
  let { Request.single_thread; prefer_prebuilt; include_main; prebuilt_dir;
        source_dir; work_dir; toolchain; verbose } = request in
  let debug_info =
    match debug_info with Some b -> b | None -> mode = Build_mode.Debug
  in
  let allow_prebuilt =
    prefer_prebuilt && (Option.is_some prebuilt_dir || mode = Build_mode.Release)
  in
  let prebuilt =
    if allow_prebuilt then Target.prebuilt_runtime ~single_thread prebuilt_dir
    else None
  in
  let archive_name = if single_thread then "libocamlrt_st.a" else "libocamlrt.a" in
  let select_prebuilt dir =
    let archive = Filename.concat dir archive_name in
    if include_main && Sys.file_exists archive && Option.is_none prebuilt_dir
    then Some [archive]
    else
      let objects = runtime_objects ~include_main dir in
      if List.for_all Sys.file_exists objects then Some objects else None
  in
  match Option.bind prebuilt select_prebuilt with
  | Some inputs -> Ok inputs
  | None ->
      match Target.runtime_sources source_dir with
      | Some dir -> (
          match cache_dir with
          | None ->
              compile_runtime_objs ?parallel ~verbose toolchain ~include_main
                ~single_thread ~mode ~debug_info ~extra_cflags dir work_dir
          | Some cache ->
              let inputs = runtime_sources ~include_main dir @ header_files dir in
              let* digests = Build_cache.fingerprints inputs in
              let key =
                Build_cache.key
                  (["schema", "1"; "kind", "runtime";
                    "mode", Build_mode.to_string mode;
                    "debug-info", string_of_bool debug_info;
                    "rc", string_of_bool single_thread;
                    "main", string_of_bool include_main;
                    "cc", toolchain.cc_prog]
                  @ List.map (fun f -> "cc-base", f) toolchain.cc_base_args
                  @ List.map (fun f -> "cflag", f) extra_cflags
                  @ digests)
              in
              let store = Filename.concat cache "runtime" in
              let+ entry =
                Build_cache.ensure ~store ~key (fun directory ->
                  let* _ =
                    compile_runtime_objs ?parallel ~verbose toolchain ~include_main
                      ~single_thread ~mode ~debug_info ~extra_cflags dir directory
                  in
                  Ok ())
              in
              let objects = runtime_objects ~include_main entry.directory in
              mkdir_p work_dir;
              List.map (fun src ->
                let dst = Filename.concat work_dir (Filename.basename src) in
                write_if_changed dst (read_file src);
                dst) objects)
      | None ->
          Error (if prefer_prebuilt then "cannot locate runtime/ directory"
                 else "cannot locate runtime/ directory for cross build")

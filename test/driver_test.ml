(* Tests for single-binary Driver (dependency sorting, targets, exe/lib builds,
   cross-target QBE asm, and main_entry.o exclusion on library targets). *)

let has_substr ~sub s =
  let sl = String.length sub in
  let n = String.length s in
  if sl = 0 then true
  else if sl > n then false
  else
    let rec go i =
      if i > n - sl then false
      else if String.sub s i sl = sub then true
      else go (i + 1)
    in
    go 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let run_capture prog args =
  let r_fd, w_fd = Unix.pipe () in
  let pid =
    Unix.create_process prog (Array.of_list (prog :: args)) Unix.stdin w_fd
      Unix.stderr
  in
  Unix.close w_fd;
  let ic = Unix.in_channel_of_descr r_fd in
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_string buf (input_line ic);
       Buffer.add_char buf '\n'
     done
   with End_of_file -> ());
  close_in_noerr ic;
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with Unix.WEXITED c -> c | Unix.WSIGNALED s -> 128 + s | Unix.WSTOPPED s -> 128 + s
  in
  (code, Buffer.contents buf)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter
        (fun e -> rm_rf (Filename.concat path e))
        (Sys.readdir path);
      Sys.rmdir path
    end
    else Sys.remove path

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base (Printf.sprintf "ocamlcc_driver_%d" (Unix.getpid ()))
  in
  if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let find_repo_root () =
  let rec up dir =
    if
      Sys.file_exists (Filename.concat dir "dune-project")
      && Sys.file_exists (Filename.concat dir "runtime/arc.c")
    then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then failwith "cannot find repo root" else up parent
  in
  up (Sys.getcwd ())

let () =
  let failures = ref 0 in
  let check name ok =
    Printf.printf "%s: %s\n" name (if ok then "PASS" else "FAIL");
    if not ok then incr failures
  in
  let root = find_repo_root () in
  let qbe = Filename.concat root "build/qbe/qbe" in
  let runtime_dir = Filename.concat root "runtime" in
  let stdlib_src_dir = Filename.concat root "stdlib" in
  let stdlib_build_dir = Filename.concat root "build/stdlib" in
  let rt_build_dir = Filename.concat root "build/rt" in

  (* 1. Target parsing *)
  let targets_ok =
    List.for_all
      (fun t ->
        match Driver.resolve_target t with Ok _ -> true | Error _ -> false)
      [ "host"; "arm64_apple"; "arm64"; "amd64_sysv"; "rv64"; "ios-arm64";
        "ios-sim-arm64"; "android-arm64" ]
    &&
    match Driver.resolve_target "bogus-arch" with
    | Error _ -> true
    | Ok _ -> false
  in
  check "target resolution" targets_ok;

  (* 2. Out-of-order dependency resolution *)
  let mod_main_ml = Filename.concat root "examples/mod_main.ml" in
  let mod_lib_ml = Filename.concat root "examples/mod_lib.ml" in
  let mod_lib_mli = Filename.concat root "examples/mod_lib.mli" in
  (match Driver.plan_build_order [ mod_main_ml; mod_lib_ml; mod_lib_mli ] with
  | Error msg ->
      Printf.printf "dep order error: %s\n" msg;
      check "dependency ordering" false
  | Ok steps ->
      let names =
        List.map
          (fun (s : Driver.build_step) ->
            let ext = match s.kind with `Mli -> ".mli" | `Ml -> ".ml" in
            s.modname ^ ext)
          steps
      in
      check "dependency ordering"
        (names = [ "Mod_lib.mli"; "Mod_lib.ml"; "Mod_main.ml" ]));

  (* 3. Full driver builds inside temp dir *)
  with_temp_dir (fun tmp ->
      (* 3a. Multi-module executable (inputs reversed) *)
      let exe_out = Filename.concat tmp "mod_app" in
      let base_cfg =
        { (Driver.default_config ()) with
          qbe_path = Some qbe;
          runtime_dir = Some runtime_dir;
          prebuilt_rt_dir = Some rt_build_dir;
          stdlib_src_dir = Some stdlib_src_dir;
          prebuilt_stdlib_dir = Some stdlib_build_dir }
      in
      (match
         Driver.build
           { base_cfg with
             inputs = [ mod_main_ml; mod_lib_ml; mod_lib_mli ];
             output = Some exe_out;
             work_dir = Some (Filename.concat tmp "work_exe") }
       with
      | Error msg ->
          Printf.printf "exe build error: %s\n" msg;
          check "exe build" false
      | Ok _ ->
          let code, out = run_capture exe_out [] in
          let expected =
            read_file (Filename.concat root "tests/mod_main.expected")
          in
          check "exe build" (code = 0 && out = expected));

      (* 3b. Shared library + --emit-header + C host (verifying no main_entry.o) *)
      let bindgen_mli = Filename.concat root "examples/bindgen_lib.mli" in
      let bindgen_ml = Filename.concat root "examples/bindgen_lib.ml" in
      let bindgen_host_c = Filename.concat root "tests/bindgen_host.c" in
      let is_darwin =
        let _, u = run_capture "uname" [ "-s" ] in
        String.trim u = "Darwin"
      in
      let shared_ext = if is_darwin then ".dylib" else ".so" in
      let shared_out = Filename.concat tmp ("libbindgen" ^ shared_ext) in
      let hdr_out = Filename.concat tmp "bindgen_lib.h" in
      (match
         Driver.build
           { base_cfg with
             nostdlib = true;
             include_dirs = [ stdlib_build_dir ];
             inputs = [ bindgen_ml; bindgen_mli ];
             kind = Some Driver.Kind_shared;
             emit_header = Some hdr_out;
             output = Some shared_out;
             work_dir = Some (Filename.concat tmp "work_shared") }
       with
      | Error msg ->
          Printf.printf "shared build error: %s\n" msg;
          check "shared library + header" false
      | Ok _ ->
          let _nm_code, nm_out = run_capture "nm" [ "-g"; shared_out ] in
          let no_main =
            not
              (has_substr ~sub:" _main\n" nm_out
              || has_substr ~sub:" T main\n" nm_out
              || has_substr ~sub:" T _main\n" nm_out)
          in
          let host_bin = Filename.concat tmp "host_app" in
          let cc_code, cc_out =
            run_capture "cc"
              [ "-std=c99"; "-Wall"; "-Wextra"; "-Werror"; "-I" ^ tmp;
                bindgen_host_c; shared_out; "-Wl,-rpath," ^ tmp; "-lm"; "-o";
                host_bin ]
          in
          if cc_code <> 0 then begin
            Printf.printf "host link failed: %s\n" cc_out;
            check "shared library + header" false
          end
          else
            let rcode, rout = run_capture host_bin [] in
            let expected =
              read_file (Filename.concat root "tests/bindgen_host.expected")
            in
            check "shared library + header"
              (no_main && rcode = 0 && rout = expected));

      (* 3c. Static library (verifying no main_entry.o) *)
      let static_out = Filename.concat tmp "libmod_lib.a" in
      (match
         Driver.build
           { base_cfg with
             inputs = [ mod_lib_mli; mod_lib_ml ];
             kind = Some Driver.Kind_static;
             output = Some static_out;
             work_dir = Some (Filename.concat tmp "work_static") }
       with
      | Error msg ->
          Printf.printf "static build error: %s\n" msg;
          check "static library no main" false
      | Ok _ ->
          let _nm_code, nm_out = run_capture "nm" [ static_out ] in
          let no_main =
            not
              (has_substr ~sub:"main_entry.o" nm_out
              || has_substr ~sub:" T _main\n" nm_out
              || has_substr ~sub:" T main\n" nm_out)
          in
          check "static library no main" no_main);

      (* 3d. Cross-target QBE assembly emission *)
      let asm_ok =
        List.for_all
          (fun (tname, needle) ->
            let out_s = Filename.concat tmp (tname ^ ".s") in
            match
              Driver.build
                { base_cfg with
                  target = Some tname;
                  inputs = [ mod_lib_mli; mod_lib_ml ];
                  kind = Some Driver.Kind_asm;
                  output = Some out_s;
                  work_dir = Some (Filename.concat tmp ("work_" ^ tname)) }
            with
            | Ok _ ->
                let s = read_file out_s in
                has_substr ~sub:needle s
            | Error msg ->
                Printf.printf "asm %s error: %s\n" tname msg;
                false)
          [ ("arm64_apple", "_ocamlcc_init_Mod_lib");
            ("arm64", "ocamlcc_init_Mod_lib");
            ("amd64_sysv", "ocamlcc_init_Mod_lib");
            ("rv64", "ocamlcc_init_Mod_lib") ]
      in
      check "cross-target asm emission" asm_ok);

  exit (if !failures = 0 then 0 else 1)

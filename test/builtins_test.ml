(* Builtin resolution test: verifies Stdlib.cmi slot resolution works
   against an active -I stdlib.cmi without compiling probe snippets
   against the host switch's Stdlib. *)

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

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "ocamlcc_builtins_%d" (Unix.getpid ())) in
  if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun entry -> Sys.remove (Filename.concat dir entry))
        (Sys.readdir dir);
      Sys.rmdir dir)
    (fun () -> f dir)

let () =
  let failures = ref 0 in
  with_temp_dir (fun dir ->
      let mli_path = Filename.concat dir "stdlib.mli" in
      let prefix = Filename.concat dir "stdlib" in
      let mli_src =
        "val print_int : int -> unit\nval print_endline : string -> unit\n"
      in
      match
        Frontend.compile_interface ~include_dirs:[ dir ] ~output_prefix:prefix
          ~nopervasives:true ~nostdlib:true ~filename:mli_path ~modname:"Stdlib"
          mli_src
      with
      | Error { msg } ->
          Printf.printf "compile custom stdlib.mli: FAIL %s\n" msg;
          incr failures
      | Ok _cmi -> (
          let src = "let () = print_int 42; print_endline \"ok\"" in
          match
            Pipeline.compile_source
              { (Pipeline.Request.create ~filename:"custom_probe.ml" ~modname:"Custom_probe") with
                include_dirs = [ dir ] } src
          with
          | Error msg ->
              Printf.printf "custom stdlib builtins: FAIL %s\n" msg;
              incr failures
          | Ok { Pipeline.Output.ssa = il; _ } ->
              let ok =
                has_substr ~sub:"call extern $ocamlcc_print_int(" il
                && has_substr ~sub:"call extern $ocamlcc_print_endline(" il
                && not (has_substr ~sub:"ocamlcc_global_Stdlib" il)
              in
              Printf.printf "custom stdlib builtins: %s\n"
                (if ok then "PASS" else "FAIL");
              if not ok then incr failures));
  (let src = "let () = print_int 7; print_endline \"hi\"; exit 0" in
   match
     Pipeline.compile_source (Pipeline.Request.create ~filename:"host_probe.ml" ~modname:"Host_probe") src
   with
   | Error msg ->
       Printf.printf "host stdlib builtins: FAIL %s\n" msg;
       incr failures
   | Ok { Pipeline.Output.ssa = il; _ } ->
       let ok =
         has_substr ~sub:"call extern $ocamlcc_print_int(" il
         && has_substr ~sub:"call extern $ocamlcc_print_endline(" il
         && has_substr ~sub:"call extern $ocamlcc_exit(" il
       in
       Printf.printf "host stdlib builtins: %s\n"
         (if ok then "PASS" else "FAIL");
       if not ok then incr failures);
  exit (if !failures = 0 then 0 else 1)

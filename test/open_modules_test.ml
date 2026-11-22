(* TDD contract test for [-open <Module>] support in Frontend/Pipeline/CLI. *)

let write_file path data =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc data)

let () =
  let tmp = Filename.temp_dir "ocamlcc_open_test" "" in
  let helper_mli = Filename.concat tmp "open_helper.mli" in
  let helper_ml = Filename.concat tmp "open_helper.ml" in
  let user_mli = Filename.concat tmp "open_user.mli" in
  let user_ml = Filename.concat tmp "open_user.ml" in
  write_file helper_mli "type secret = int\nval magic_offset : secret\n";
  write_file helper_ml "type secret = int\nlet magic_offset = 41\n";
  write_file user_mli "val answer : secret\n";
  write_file user_ml "let answer = magic_offset + 1\n";

  (* Compile Open_helper .cmi first. *)
  (match
     Pipeline.compile_interface_file
       { (Pipeline.Request.create ~filename:helper_mli ~modname:"Open_helper") with
         include_dirs = [ tmp ]; output_prefix = Some (Filename.concat tmp "open_helper") }
   with
  | Ok _ -> ()
  | Error msg -> failwith ("helper mli failed: " ^ msg));

  (* Without ~open_modules, Open_user fails (unbound type secret). *)
  (match
     Pipeline.compile_interface_file
       { (Pipeline.Request.create ~filename:user_mli ~modname:"Open_user") with
         include_dirs = [ tmp ]; output_prefix = Some (Filename.concat tmp "open_user") }
   with
  | Error _ -> ()
  | Ok _ -> failwith "expected failure without ~open_modules");

  (* With ~open_modules:["Open_helper"], both .mli and .ml succeed. *)
  let saved_before = !Clflags.open_modules in
  (match
     Pipeline.compile_interface_file
       { (Pipeline.Request.create ~filename:user_mli ~modname:"Open_user") with
         include_dirs = [ tmp ]; output_prefix = Some (Filename.concat tmp "open_user");
         open_modules = [ "Open_helper" ] }
   with
  | Ok _ -> ()
  | Error msg -> failwith ("user mli with -open failed: " ^ msg));
  assert (!Clflags.open_modules = saved_before);

  (match
     Pipeline.compile_file
       { (Pipeline.Request.create ~filename:user_ml ~modname:"Open_user") with
         include_dirs = [ tmp ]; open_modules = [ "Open_helper" ]; emit_entry = false }
   with
  | Ok { Pipeline.Output.ssa = ssa; _ } ->
      assert (String.length ssa > 0);
      assert (!Clflags.open_modules = saved_before)
  | Error msg -> failwith ("user ml with -open failed: " ^ msg));

  (* Precedence check: later -open shadows earlier -open, matching ocamlc. *)
  let first_mli = Filename.concat tmp "open_first.mli" in
  let second_mli = Filename.concat tmp "open_second.mli" in
  write_file first_mli "val v : string\n";
  write_file second_mli "val v : int\n";
  ignore
    (Result.get_ok
       (Pipeline.compile_interface_file
         { (Pipeline.Request.create ~filename:first_mli ~modname:"Open_first") with
           include_dirs = [ tmp ]; output_prefix = Some (Filename.concat tmp "open_first") }));
  ignore
    (Result.get_ok
       (Pipeline.compile_interface_file
         { (Pipeline.Request.create ~filename:second_mli ~modname:"Open_second") with
           include_dirs = [ tmp ]; output_prefix = Some (Filename.concat tmp "open_second") }));
  (match
     Pipeline.compile_source
       { (Pipeline.Request.create ~filename:(Filename.concat tmp "prec.ml") ~modname:"Prec") with
         include_dirs = [ tmp ]; open_modules = [ "Open_first"; "Open_second" ];
         emit_entry = false } "let x : int = v\n"
   with
  | Ok _ -> ()
  | Error msg -> failwith ("open precedence failed: " ^ msg));
  print_endline "open_modules_test: PASS"

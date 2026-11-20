exception MyExn of int * string

let () =
  at_exit (fun () -> print_endline "at_exit=ok");

  Callback.register "user_cb" (fun x -> x + 1);
  Callback.register_exception "user_exn" (MyExn (0, ""));

  Printf.printf "cfg=%s,%d,%d,%b,iobuf=%d,var=[%s],par_ok=%b,exe_nonempty=%b,tmp_nonempty=%b\n"
    Sys.os_type Sys.word_size Sys.int_size Sys.big_endian Sys.io_buffer_size
    (Sys.runtime_variant ()) (String.length (Sys.runtime_parameters ()) >= 0)
    (String.length Sys.executable_name > 0)
    (String.length (Filename.get_temp_dir_name ()) > 0);

  let old_warn = Sys.runtime_warnings_enabled () in
  Sys.enable_runtime_warnings true;
  let w_on = Sys.runtime_warnings_enabled () in
  Sys.enable_runtime_warnings old_warn;
  let w_restored = Sys.runtime_warnings_enabled () in
  Printf.printf "warn=%b,%b,%b\n" old_warn w_on w_restored;

  let prev_sig = Sys.signal Sys.sigint Sys.Signal_default in
  let _ = Sys.signal Sys.sigint prev_sig in
  let s_rt = Sys.signal_to_int (Sys.signal_of_int 2) in
  Printf.printf "sig=%b,rt=%b\n"
    (prev_sig = Sys.Signal_default) (s_rt >= 0 || s_rt < 0);

  Printexc.record_backtrace true;
  let bt_on = Printexc.backtrace_status () in
  Printexc.record_backtrace false;
  let bt_off = Printexc.backtrace_status () in
  let cs = Printexc.get_callstack 4 in
  let cs_ok = Printexc.raw_backtrace_length cs >= 0 in
  let rbt = Printexc.get_raw_backtrace () in
  let oob_slot =
    try ignore (Printexc.get_raw_backtrace_slot rbt 99); false
    with Invalid_argument _ -> true
  in
  let conv_ok =
    match Printexc.backtrace_slots rbt with
    | Some a -> Array.length a >= 0
    | None -> true
  in
  Printexc.register_printer (function
    | MyExn (n, s) -> Some (Printf.sprintf "custom(%d,%s)" n s)
    | _ -> None);
  let ex_str1 = Printexc.to_string (Failure "boom") in
  let ex_str2 = Printexc.to_string (MyExn (7, "ok")) in
  let slot_name = Printexc.exn_slot_name (MyExn (1, "a")) in
  Printf.printf "bt=%b,%b,cs=%b,oob=%b,conv=%b,ex1=%s,ex2=%s,slot=%s\n"
    bt_on bt_off cs_ok oob_slot conv_ok ex_str1 ex_str2 slot_name;

  (* Lazy re-raise exercises Lazy.Mutexed get_raw_backtrace + raise_with_backtrace *)
  let lz = lazy (failwith "lazy_err") in
  let r1 = try ignore (Lazy.force lz); "" with Failure s -> s in
  let r2 = try ignore (Lazy.force lz); "" with Failure s -> s in
  Printf.printf "lazy=%s,%s\n" r1 r2

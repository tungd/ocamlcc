(* Negative controls: each faulty assertion must fail the current test. *)
open B0_testing
let () =
  let code = Test.main (fun () ->
    Test.test "int mismatch" (fun () -> Test.int 1 2);
    Test.test "bool mismatch" (fun () -> Test.bool true false);
    Test.test "float mismatch" (fun () -> Test.float 1.0 2.0);
    Test.test "string mismatch" (fun () -> Test.string "a" "b");
    Test.test "option mismatch" (fun () -> Test.option ~some:Test.Eq.int (Some 1) None);
    Test.test "result mismatch" (fun () -> Test.result' ~ok:Test.Eq.int ~error:Test.Eq.int (Ok 1) (Error 1));
    Test.test "get_some None" (fun () -> ignore (Test.get_some None));
    Test.test "get_ok Error" (fun () -> ignore (Test.get_ok (Error "wrong")));
    Test.test "block propagates failure" (fun () -> Test.block (fun () -> Test.holds false)))
  in
  if code <> 1 || !(Test.failed) <> 9 || !(Test.passed) <> 0 then exit 2;
  print_endline "negative controls: 9/9 detected"

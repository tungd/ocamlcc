let il =
  match Pipeline.compile_source ~nostdlib:true ~nopervasives:true
    ~filename:"finalizer_poll.ml" ~modname:"Finalizer_poll" {|
      external ( + ) : int -> int -> int = "%addint"
      external ( - ) : int -> int -> int = "%subint"
      external ( = ) : int -> int -> bool = "%equal"
      external side_effect : int -> unit = "test_unknown_primitive"
      type row = { width : int }
      let width row = row.width + 1
      let select enabled row = if enabled then row.width else 0
      let allocate x = (x, x)
      let foreign x = side_effect x
      let rec recurse n = if n = 0 then n else recurse (n - 1)
      let loop n = for i = 0 to n do () done
      let reverse n = for i = n downto 0 do () done
      let loop_with_call n = for i = 0 to n do side_effect i done
    |}
  with
  | Ok il -> il
  | Error message -> failwith message

let has_instruction name text =
  let find text start = Str.search_forward (Str.regexp_string text) il start in
  let start = find ("function l $ocamlcc_Finalizer_poll_" ^ name ^ "(") 0 in
  let finish = find "\n}" start in
  match find text start with
  | index -> index < finish
  | exception Not_found -> false

let check name text expected =
  if has_instruction name text <> expected then
    failwith (Printf.sprintf "%s: expected %S = %b" name text expected)

let () =
  let poll = "call extern $ocamlcc_finalizers_due(" in
  List.iter (fun name -> check name poll false) ["width"; "select"];
  List.iter (fun name -> check name poll true)
    ["allocate"; "foreign"; "recurse"; "loop"; "reverse"; "loop_with_call"];
  List.iter (fun name -> check name " =l and " true) ["loop"; "reverse"];
  check "loop_with_call" " =l and " false

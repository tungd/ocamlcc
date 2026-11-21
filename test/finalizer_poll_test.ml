let il =
  match Pipeline.compile_source ~nostdlib:true ~nopervasives:true
    ~filename:"finalizer_poll.ml" ~modname:"Finalizer_poll" {|
      external ( + ) : int -> int -> int = "%addint"
      external ( / ) : int -> int -> int = "%divint"
      external ( mod ) : int -> int -> int = "%modint"
      external ( - ) : int -> int -> int = "%subint"
      external ( = ) : int -> int -> bool = "%equal"
      external ( < ) : int -> int -> bool = "%lessthan"
      external side_effect : int -> unit = "test_unknown_primitive"
      external unsafe_get : 'a array -> int -> 'a = "%array_unsafe_get"
      type row = { width : int }
      type choice = Empty | Fixed | Left of int | Right of int
      type local = { mutable index : int }
      let width row = row.width + 1
      let select enabled row = if enabled then row.width else 0
      let classify = function Empty -> 0 | Fixed -> 1 | Left _ -> 2 | Right _ -> 3
      let join = function Empty -> 0 | Fixed -> 1 | Left n | Right n -> n + 1
      let mutate n = let v = { index = n } in v.index <- v.index + 1; v.index
      let match_with_call = function
        | Empty | Fixed -> ()
        | Left n | Right n -> side_effect n
      let generic_get a = unsafe_get a 0
      type links = { mutable next : links option }
      let store cell value = cell.next <- value
      let constant_div n = n / 2 + n mod (-8)
      let dynamic_div n d = n / d
      let allocate x = (x, x)
      let after_allocate x = let _ = allocate x in x + 1
      let after_dynamic n d = dynamic_div n d + 1
      let foreign x = side_effect x
      let rec recurse n = if n = 0 then n else recurse (n - 1)
      let loop n = for i = 0 to n do () done
      let reverse n = for i = n downto 0 do () done
      let loop_with_call n = for i = 0 to n do side_effect i done
      let while_local n =
        let v = { index = 0 } in
        while v.index < n do v.index <- v.index + 1 done;
        v.index
      let while_field r n =
        while r.index < n do r.index <- r.index + 1 done
      let while_call n =
        let v = { index = 0 } in
        while v.index < n do side_effect v.index; v.index <- v.index + 1 done;
        v.index
    |}
  with
  | Ok il -> il
  | Error message -> failwith message

let has_instruction name pattern =
  let find text start = Str.search_forward (Str.regexp_string text) il start in
  let start = find ("function l $ocamlcc_Finalizer_poll_" ^ name ^ "(") 0 in
  let finish = find "\n}" start in
  match Str.search_forward pattern il start with
  | index -> index < finish
  | exception Not_found -> false

let check ?(literal = true) name text expected =
  let pattern = (if literal then Str.regexp_string else Str.regexp) text in
  if has_instruction name pattern <> expected then
    failwith (Printf.sprintf "%s: expected %S = %b" name text expected)

let () =
  let poll = "call extern $ocamlcc_finalizers_due(" in
  List.iter (fun name -> check name poll false)
    ["width"; "select"; "classify"; "join"; "mutate"; "store"; "constant_div"];
  List.iter (fun name -> check name poll true)
    ["allocate"; "foreign"; "recurse"; "loop"; "reverse"; "loop_with_call";
     "while_local"; "while_field"; "while_call"; "match_with_call"; "generic_get"];
  check "loop_with_call" "loadl extern $ocamlcc_finalizer_count" true;
  check "width" "loadl extern $ocamlcc_finalizer_count" false;
  check "generic_get" "call extern $ocamlcc_gen_array_get(" true;
  let phase_mask = " =l and [^,\n]+, 127\n" in
  List.iter (fun name -> check ~literal:false name phase_mask true)
    ["loop"; "reverse"; "loop_with_call"; "while_local"; "while_field"];
  List.iter (fun name -> check ~literal:false name phase_mask false)
    ["while_call"];
  check "constant_div" "ocamlcc_global_Division_by_zero" false;
  check "dynamic_div" "ocamlcc_global_Division_by_zero" true;
  let guard = "loadw extern $ocamlcc_automatic_finalizer_raised" in
  check "after_allocate" guard true;
  check "after_dynamic" guard false

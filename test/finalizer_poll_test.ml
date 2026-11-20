let il =
  match Pipeline.compile_source ~nostdlib:true ~nopervasives:true
    ~filename:"finalizer_poll.ml" ~modname:"Finalizer_poll" {|
      external ( + ) : int -> int -> int = "%addint"
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
      let allocate x = (x, x)
      let foreign x = side_effect x
      let rec recurse n = if n = 0 then n else recurse (n - 1)
      let loop n = for i = 0 to n do () done
      let reverse n = for i = n downto 0 do () done
      let loop_with_call n = for i = 0 to n do side_effect i done
      let while_local n =
        let v = { index = 0 } in
        while v.index < n do v.index <- v.index + 1 done;
        v.index
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
    ["width"; "select"; "classify"; "join"; "mutate"];
  List.iter (fun name -> check name poll true)
    ["allocate"; "foreign"; "recurse"; "loop"; "reverse"; "loop_with_call";
     "while_local"; "while_call"; "match_with_call"; "generic_get"];
  check "generic_get" "call extern $ocamlcc_gen_array_get(" true;
  let phase_mask = " =l and [^,\n]+, 127\n" in
  List.iter (fun name -> check ~literal:false name phase_mask true)
    ["loop"; "reverse"; "while_local"];
  List.iter (fun name -> check ~literal:false name phase_mask false)
    ["loop_with_call"; "while_call"]

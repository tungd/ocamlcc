let check ?(owner_releases = Some 1) ~retains name source =
  let il =
    match
      Pipeline.compile_source ~nopervasives:true ~nostdlib:true
        ~filename:(name ^ ".ml") ~modname:(String.capitalize_ascii name) source
    with
    | Ok il -> il
    | Error message -> failwith message
  in
  let count_calls name =
    let call = Str.regexp_string ("call extern $" ^ name ^ "(") in
    let rec count from acc =
      match Str.search_forward call il from with
      | index -> count (index + 1) (acc + 1)
      | exception Not_found -> acc
    in
    count 0 0
  in
  let actual = count_calls "arc_retain_val" + count_calls "arc_retain" in
  if actual <> retains then
    failwith (Printf.sprintf "%s: expected %d retains, got %d" name retains actual);
  if retains = 0 then
    Option.iter (fun expected ->
      let actual = count_calls "arc_release_val" + count_calls "arc_release" in
      if actual <> expected then
        failwith (Printf.sprintf "%s: expected only the owner's releases, got %d" name actual))
      owner_releases

let () =
  check ~retains:0 "int_field"
    {|type t = { mutable v : int }
      external ( = ) : int -> int -> bool = "%equal"
      let f r = if r.v = 0 then 1 else 2|};
  check ~retains:0 "int_array"
    {|external get : 'a array -> int -> 'a = "%array_unsafe_get"
      external ( = ) : int -> int -> bool = "%equal"
      let f (a : int array) i = if get a i = 0 then 1 else 2|};
  check ~retains:0 "local_immutable_field"
    {|type t = { v : string }
      external length : string -> int = "%string_length"
      let f r = length r.v|};
  check ~retains:0 "local_mutable_field"
    {|type t = { mutable v : string }
      external length : string -> int = "%string_length"
      let f r = length r.v|};
  check ~retains:1 "field_passed_to_c"
    {|type t = { v : string }
      external use : string -> int = "foreign_use"
      let f r = use r.v|};
  check ~retains:1 "field_live_across_callback"
    {|type t = { v : string }
      external length : string -> int = "%string_length"
      let f r callback = let value = r.v in callback (); length value|};
  check ~retains:1 "mutable_field_live_across_callback"
    {|type t = { mutable v : string }
      external length : string -> int = "%string_length"
      let f r callback = let value = r.v in callback (); length value|};
  check ~retains:0 "nested_immutable_fields"
    {|type inner = { data : string }
      type outer = { inner : inner }
      external length : string -> int = "%string_length"
      let f r = let item = r.inner in length item.data|};
  check ~owner_releases:(Some 2) ~retains:0 "field_used_for_dispatch"
    {|type choice = Empty | Filled of string
      type t = { choice : choice }
      let f r = match r.choice with Empty -> 1 | Filled _ -> 2|};
  check ~retains:0 "array_store_via_field"
    {|type t = { data : int array }
      external set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
      let f r i v = set r.data i v|};
  check ~retains:0 "array_read_and_store_via_field"
    {|type t = { data : int array }
      external get : 'a array -> int -> 'a = "%array_unsafe_get"
      external set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
      external ( + ) : int -> int -> int = "%addint"
      let f r i =
        let data = r.data in
        let previous = get data i in
        set data i (previous + 1);
        previous|};
  check ~retains:1 "array_store_transfers_field"
    {|type t = { data : int array }
      external set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
      let f r destination = set destination 0 r.data|};
  check ~retains:0 "array_store_via_mutable_field"
    {|type t = { mutable data : int array }
      external set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
      let f r i v = set r.data i v|};
  check ~retains:1 "pointer_field"
    {|type t = { v : string }
      let f r = r.v|};
  check ~retains:1 "pointer_array"
    {|external get : 'a array -> int -> 'a = "%array_unsafe_get"
      let f (a : string array) i = get a i|};
  check ~owner_releases:None ~retains:0 "field_reads_in_loops"
    {|type t = { data : int array; label : string }
      external length : string -> int = "%string_length"
      external get : 'a array -> int -> 'a = "%array_unsafe_get"
      external set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
      external ( < ) : int -> int -> bool = "%lessthan"
      external ( + ) : int -> int -> int = "%addint"
      let f r high =
        let data = r.data in
        let label = r.label in
        for i = 0 to high do
          set data i (get data i + length label)
        done;
        while get data 0 < high do set data 0 (get data 0 + 1) done|}

let () =
  let source = {|
    type rect = { top : int; bottom : int; left : int; right : int }
    type mutable_rect = { mutable top : int; bottom : int; left : int; right : int }
    let rect top bottom left right : rect = { top; bottom; left; right }
    let mutable_rect top bottom left right : mutable_rect = { top; bottom; left; right }
  |} in
  match Pipeline.compile_source ~nopervasives:true ~nostdlib:true
    ~filename:"immediate_blocks.ml" ~modname:"Immediate_blocks" source with
  | Error message -> failwith message
  | Ok il ->
      let require call =
        if not (try ignore (Str.search_forward (Str.regexp_string call) il 0); true
          with Not_found -> false)
        then failwith ("missing block layout: " ^ call)
      in
      require "call extern $arc_alloc(l 0, l 0, l 32)";
      require "call extern $arc_alloc(l 0, l 4, l 32)"

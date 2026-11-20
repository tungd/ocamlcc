let check ?(owner_releases = 2) ~retains name source =
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
  let actual = count_calls "arc_retain_val" in
  if actual <> retains then
    failwith (Printf.sprintf "%s: expected %d retains, got %d" name retains actual);
  if retains = 0 then
    let actual = count_calls "arc_release_val" in
    if actual <> owner_releases then
      failwith (Printf.sprintf "%s: expected only the owner's releases, got %d" name actual)

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
  check ~retains:1 "local_mutable_field"
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
  check ~retains:0 "nested_immutable_fields"
    {|type inner = { data : string }
      type outer = { inner : inner }
      external length : string -> int = "%string_length"
      let f r = let item = r.inner in length item.data|};
  check ~owner_releases:3 ~retains:0 "field_used_for_dispatch"
    {|type choice = Empty | Filled of string
      type t = { choice : choice }
      let f r = match r.choice with Empty -> 1 | Filled _ -> 2|};
  check ~retains:1 "pointer_field"
    {|type t = { v : string }
      let f r = r.v|};
  check ~retains:1 "pointer_array"
    {|external get : 'a array -> int -> 'a = "%array_unsafe_get"
      let f (a : string array) i = get a i|}

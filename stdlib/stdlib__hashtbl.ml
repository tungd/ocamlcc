external raise : exn -> 'a = "%raise"
external ignore : 'a -> unit = "%ignore"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external ( land ) : int -> int -> int = "%andint"
external ( lsl ) : int -> int -> int = "%lslint"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external not : bool -> bool = "%boolnot"

external seeded_hash_param : int -> int -> int -> 'a -> int = "caml_hash"

let hash_param n1 n2 x = seeded_hash_param n1 n2 0 x
let seeded_hash seed x = seeded_hash_param 10 100 seed x
let hash x = seeded_hash_param 10 100 0 x

type ('a, 'b) bucketlist =
  | Empty
  | Cons of { mutable key : 'a; mutable data : 'b; mutable next : ('a, 'b) bucketlist }

type ('a, 'b) t = {
  mutable size : int;
  mutable data : ('a, 'b) bucketlist array;
  mutable seed : int;
  initial_size : int;
}

let rec power_2_above x n =
  if x >= n then x
  else if x * 2 > 1073741823 then x
  else power_2_above (x * 2) n

let create ?(random = false) initial_size =
  ignore random;
  let s = power_2_above 16 initial_size in
  { initial_size = s; size = 0; seed = 0; data = Stdlib__array.make s Empty }

let clear h =
  h.size <- 0;
  let len = Stdlib__array.length h.data in
  for i = 0 to len - 1 do
    Stdlib__array.unsafe_set h.data i Empty
  done

let reset h =
  let len = Stdlib__array.length h.data in
  if Stdlib__array.length h.data = h.initial_size then clear h
  else begin
    ignore len;
    h.size <- 0;
    h.data <- Stdlib__array.make h.initial_size Empty
  end

let copy_bucketlist = function
  | Empty -> Empty
  | Cons { key; data; next } ->
      let rec loop prec = function
        | Empty -> ()
        | Cons { key; data; next } ->
            let r = Cons { key; data; next = Empty } in
            (match prec with
            | Cons p -> p.next <- r
            | Empty -> ());
            loop r next
      in
      let r = Cons { key; data; next = Empty } in
      loop r next;
      r

let copy h =
  { size = h.size;
    data = Stdlib__array.map copy_bucketlist h.data;
    seed = h.seed;
    initial_size = h.initial_size }

let length h = h.size

let resize indexfun h =
  let odata = h.data in
  let osize = Stdlib__array.length odata in
  let nsize = osize * 2 in
  if nsize < 1073741823 then begin
    let ndata = Stdlib__array.make nsize Empty in
    h.data <- ndata;
    let rec insert_bucket = function
      | Empty -> ()
      | Cons { key; data; next } ->
          insert_bucket next;
          let nidx = indexfun h key in
          Stdlib__array.unsafe_set ndata nidx
            (Cons { key; data; next = Stdlib__array.unsafe_get ndata nidx })
    in
    for i = 0 to osize - 1 do
      insert_bucket (Stdlib__array.unsafe_get odata i)
    done
  end

let key_index h key =
  seeded_hash_param 10 100 h.seed key land (Stdlib__array.length h.data - 1)

let add h key data =
  let i = key_index h key in
  let bucket = Cons { key; data; next = Stdlib__array.unsafe_get h.data i } in
  Stdlib__array.unsafe_set h.data i bucket;
  h.size <- h.size + 1;
  if h.size > Stdlib__array.length h.data lsl 1 then resize key_index h

let remove h key =
  let i = key_index h key in
  let rec remove_bucket prev = function
    | Empty -> ()
    | Cons { key = k; next; _ } as c ->
        if k = key then begin
          h.size <- h.size - 1;
          match prev with
          | Empty -> Stdlib__array.unsafe_set h.data i next
          | Cons p -> p.next <- next
        end
        else remove_bucket c next
  in
  remove_bucket Empty (Stdlib__array.unsafe_get h.data i)

let rec find_rec key = function
  | Empty -> raise Not_found
  | Cons { key = k; data; next } ->
      if key = k then data else find_rec key next

let find h key =
  let i = key_index h key in
  find_rec key (Stdlib__array.unsafe_get h.data i)

let rec find_rec_opt key = function
  | Empty -> None
  | Cons { key = k; data; next } ->
      if key = k then Some data else find_rec_opt key next

let find_opt h key =
  let i = key_index h key in
  find_rec_opt key (Stdlib__array.unsafe_get h.data i)

let find_all h key =
  let rec find_in_bucket = function
    | Empty -> []
    | Cons { key = k; data; next } ->
        if k = key then data :: find_in_bucket next
        else find_in_bucket next
  in
  find_in_bucket (Stdlib__array.unsafe_get h.data (key_index h key))

let replace h key data =
  let i = key_index h key in
  let l = Stdlib__array.unsafe_get h.data i in
  let rec replace_bucket = function
    | Empty ->
        Stdlib__array.unsafe_set h.data i (Cons { key; data; next = l });
        h.size <- h.size + 1;
        if h.size > Stdlib__array.length h.data lsl 1 then resize key_index h
    | Cons ({ key = k; next; _ } as slot) ->
        if k = key then (slot.key <- key; slot.data <- data)
        else replace_bucket next
  in
  replace_bucket l

let mem h key =
  let rec mem_in_bucket = function
    | Empty -> false
    | Cons { key = k; next; _ } -> k = key || mem_in_bucket next
  in
  mem_in_bucket (Stdlib__array.unsafe_get h.data (key_index h key))

let iter f h =
  let rec do_bucket = function
    | Empty -> ()
    | Cons { key; data; next } ->
        f key data;
        do_bucket next
  in
  let d = h.data in
  for i = 0 to Stdlib__array.length d - 1 do
    do_bucket (Stdlib__array.unsafe_get d i)
  done

let fold f h init =
  let rec do_bucket b accu =
    match b with
    | Empty -> accu
    | Cons { key; data; next } -> do_bucket next (f key data accu)
  in
  let d = h.data in
  let rec loop i accu =
    if i >= Stdlib__array.length d then accu
    else loop (i + 1) (do_bucket (Stdlib__array.unsafe_get d i) accu)
  in
  loop 0 init

let filter_map_inplace f h =
  let rec do_bucket = function
    | Empty -> Empty
    | Cons { key; data; next } -> (
        match f key data with
        | None ->
            h.size <- h.size - 1;
            do_bucket next
        | Some new_data -> Cons { key; data = new_data; next = do_bucket next })
  in
  let d = h.data in
  for i = 0 to Stdlib__array.length d - 1 do
    Stdlib__array.unsafe_set d i (do_bucket (Stdlib__array.unsafe_get d i))
  done

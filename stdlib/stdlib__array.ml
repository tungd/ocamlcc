external raise : exn -> 'a = "%raise"
external ignore : 'a -> unit = "%ignore"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( == ) : 'a -> 'a -> bool = "%eq"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"

external length : 'a array -> int = "%array_length"
external get : 'a array -> int -> 'a = "%array_safe_get"
external set : 'a array -> int -> 'a -> unit = "%array_safe_set"
external unsafe_get : 'a array -> int -> 'a = "%array_unsafe_get"
external unsafe_set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
external make : int -> 'a -> 'a array = "caml_array_make"

let invalid_arg s = raise (Invalid_argument s)
let create = make

let init l f =
  if l < 0 then invalid_arg "Array.init"
  else if l = 0 then [||]
  else begin
    let res = make l (f 0) in
    for i = 1 to l - 1 do
      unsafe_set res i (f i)
    done;
    res
  end

let make_matrix sx sy init_v =
  if sx < 0 || sy < 0 then invalid_arg "Array.make_matrix"
  else if sx = 0 then [||]
  else begin
    let res = make sx (make sy init_v) in
    for i = 1 to sx - 1 do
      unsafe_set res i (make sy init_v)
    done;
    res
  end

let create_matrix = make_matrix

let copy a =
  let l = length a in
  if l = 0 then [||]
  else begin
    let res = make l (unsafe_get a 0) in
    for i = 1 to l - 1 do
      unsafe_set res i (unsafe_get a i)
    done;
    res
  end

let append a1 a2 =
  let l1 = length a1 and l2 = length a2 in
  if l1 = 0 then copy a2
  else if l2 = 0 then copy a1
  else begin
    let res = make (l1 + l2) (unsafe_get a1 0) in
    for i = 1 to l1 - 1 do
      unsafe_set res i (unsafe_get a1 i)
    done;
    for i = 0 to l2 - 1 do
      unsafe_set res (l1 + i) (unsafe_get a2 i)
    done;
    res
  end

let concat l =
  let total = Stdlib__list.fold_left (fun acc a -> acc + length a) 0 l in
  if total = 0 then [||]
  else
    let rec first_elem = function
      | [] -> invalid_arg "Array.concat"
      | a :: tl -> if length a > 0 then unsafe_get a 0 else first_elem tl
    in
    let res = make total (first_elem l) in
    let rec fill_all pos = function
      | [] -> ()
      | a :: tl ->
          let al = length a in
          for i = 0 to al - 1 do
            unsafe_set res (pos + i) (unsafe_get a i)
          done;
          fill_all (pos + al) tl
    in
    fill_all 0 l;
    res

let sub a ofs len =
  if ofs < 0 || len < 0 || ofs > length a - len then
    invalid_arg "Array.sub"
  else if len = 0 then [||]
  else begin
    let res = make len (unsafe_get a ofs) in
    for i = 1 to len - 1 do
      unsafe_set res i (unsafe_get a (ofs + i))
    done;
    res
  end

let fill a ofs len v =
  if ofs < 0 || len < 0 || ofs > length a - len then
    invalid_arg "Array.fill"
  else
    CamlinternalBulkOps.unsafe_array_fill a ofs len v

let blit = CamlinternalBulkOps.array_blit

let to_list a =
  let rec tolist i res =
    if i < 0 then res else tolist (i - 1) (unsafe_get a i :: res)
  in
  tolist (length a - 1) []

let of_list = function
  | [] -> [||]
  | hd :: tl as l ->
      let len = Stdlib__list.length l in
      let a = make len hd in
      let rec fill i = function
        | [] -> a
        | x :: xs -> unsafe_set a i x; fill (i + 1) xs
      in
      fill 1 tl

let iter f a =
  for i = 0 to length a - 1 do
    f (unsafe_get a i)
  done

let iteri f a =
  for i = 0 to length a - 1 do
    f i (unsafe_get a i)
  done

let map f a =
  let l = length a in
  if l = 0 then [||]
  else begin
    let r = make l (f (unsafe_get a 0)) in
    for i = 1 to l - 1 do
      unsafe_set r i (f (unsafe_get a i))
    done;
    r
  end

let mapi f a =
  let l = length a in
  if l = 0 then [||]
  else begin
    let r = make l (f 0 (unsafe_get a 0)) in
    for i = 1 to l - 1 do
      unsafe_set r i (f i (unsafe_get a i))
    done;
    r
  end

let fold_left f x a =
  let rec go acc i n =
    if i >= n then acc else go (f acc (unsafe_get a i)) (i + 1) n
  in
  go x 0 (length a)

let fold_right f a x =
  let rec go acc i =
    if i < 0 then acc else go (f (unsafe_get a i) acc) (i - 1)
  in
  go x (length a - 1)

let iter2 f a b =
  let la = length a in
  if la <> length b then invalid_arg "Array.iter2"
  else
    for i = 0 to la - 1 do
      f (unsafe_get a i) (unsafe_get b i)
    done

let map2 f a b =
  let la = length a and lb = length b in
  if la <> lb then invalid_arg "Array.map2"
  else if la = 0 then [||]
  else begin
    let r = make la (f (unsafe_get a 0) (unsafe_get b 0)) in
    for i = 1 to la - 1 do
      unsafe_set r i (f (unsafe_get a i) (unsafe_get b i))
    done;
    r
  end

let for_all p a =
  let n = length a in
  let rec loop i =
    if i = n then true
    else if p (unsafe_get a i) then loop (i + 1)
    else false
  in
  loop 0

let exists p a =
  let n = length a in
  let rec loop i =
    if i = n then false
    else if p (unsafe_get a i) then true
    else loop (i + 1)
  in
  loop 0

let mem x a =
  let n = length a in
  let rec loop i =
    if i = n then false
    else if unsafe_get a i = x then true
    else loop (i + 1)
  in
  loop 0

let memq x a =
  let n = length a in
  let rec loop i =
    if i = n then false
    else if unsafe_get a i == x then true
    else loop (i + 1)
  in
  loop 0

let find_opt p a =
  let n = length a in
  let rec loop i =
    if i = n then None
    else
      let x = unsafe_get a i in
      if p x then Some x else loop (i + 1)
  in
  loop 0

let sort cmp a =
  let n = length a in
  if n > 1 then begin
    let swap i j =
      let tmp = unsafe_get a i in
      unsafe_set a i (unsafe_get a j);
      unsafe_set a j tmp
    in
    let rec siftdown i len =
      let child = (2 * i) + 1 in
      if child < len then begin
        let best =
          if child + 1 < len && cmp (unsafe_get a child) (unsafe_get a (child + 1)) < 0
          then child + 1
          else child
        in
        if cmp (unsafe_get a i) (unsafe_get a best) < 0 then begin
          swap i best;
          siftdown best len
        end
      end
    in
    for i = (n / 2) - 1 downto 0 do
      siftdown i n
    done;
    for i = n - 1 downto 1 do
      swap 0 i;
      siftdown 0 i
    done
  end

let stable_sort cmp a =
  let l = Stdlib__list.stable_sort cmp (to_list a) in
  let i = length a in
  let rec write k = function
    | [] -> ()
    | x :: xs -> unsafe_set a k x; write (k + 1) xs
  in
  ignore i;
  write 0 l

let fast_sort = sort

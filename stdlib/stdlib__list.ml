external raise : exn -> 'a = "%raise"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
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
external not : bool -> bool = "%boolnot"

let invalid_arg s = raise (Invalid_argument s)
let failwith s = raise (Failure s)

let is_empty = function
  | [] -> true
  | _ :: _ -> false

let cons a l = a :: l

let hd = function
  | [] -> failwith "hd"
  | a :: _ -> a

let tl = function
  | [] -> failwith "tl"
  | _ :: l -> l

let length l =
  let rec aux n = function
    | [] -> n
    | _ :: tl -> aux (n + 1) tl
  in
  aux 0 l

let nth l n =
  if n < 0 then invalid_arg "List.nth"
  else
    let rec aux l n =
      match l with
      | [] -> failwith "nth"
      | a :: tl -> if n = 0 then a else aux tl (n - 1)
    in
    aux l n

let nth_opt l n =
  if n < 0 then invalid_arg "List.nth_opt"
  else
    let rec aux l n =
      match l with
      | [] -> None
      | a :: tl -> if n = 0 then Some a else aux tl (n - 1)
    in
    aux l n

let rec rev_append l1 l2 =
  match l1 with
  | [] -> l2
  | a :: l -> rev_append l (a :: l2)

let rev l = rev_append l []

let init len f =
  if len < 0 then invalid_arg "List.init"
  else
    let rec aux acc i =
      if i < 0 then acc else aux (f i :: acc) (i - 1)
    in
    aux [] (len - 1)

let rec append l1 l2 =
  match l1 with
  | [] -> l2
  | a :: tl -> a :: append tl l2

let rec concat = function
  | [] -> []
  | l :: tl -> append l (concat tl)

let flatten = concat

let rec compare_lengths l1 l2 =
  match (l1, l2) with
  | [], [] -> 0
  | [], _ -> -1
  | _, [] -> 1
  | _ :: a, _ :: b -> compare_lengths a b

let rec compare_length_with l n =
  match l with
  | [] -> if n = 0 then 0 else if n > 0 then -1 else 1
  | _ :: tl -> if n <= 0 then 1 else compare_length_with tl (n - 1)

let rec equal eq l1 l2 =
  match (l1, l2) with
  | [], [] -> true
  | a1 :: t1, a2 :: t2 -> eq a1 a2 && equal eq t1 t2
  | _ -> false

let rec compare cmp l1 l2 =
  match (l1, l2) with
  | [], [] -> 0
  | [], _ -> -1
  | _, [] -> 1
  | a1 :: t1, a2 :: t2 ->
      let c = cmp a1 a2 in
      if c <> 0 then c else compare cmp t1 t2

let rec iter f = function
  | [] -> ()
  | a :: l -> f a; iter f l

let iteri f l =
  let rec aux i = function
    | [] -> ()
    | a :: l -> f i a; aux (i + 1) l
  in
  aux 0 l

let rec map f = function
  | [] -> []
  | a :: l ->
      let r = f a in
      r :: map f l

let mapi f l =
  let rec aux i = function
    | [] -> []
    | a :: l ->
        let r = f i a in
        r :: aux (i + 1) l
  in
  aux 0 l

let rev_map f l =
  let rec aux acc = function
    | [] -> acc
    | a :: l -> aux (f a :: acc) l
  in
  aux [] l

let rec filter_map f = function
  | [] -> []
  | x :: l -> (
      match f x with
      | None -> filter_map f l
      | Some v -> v :: filter_map f l)

let rec concat_map f = function
  | [] -> []
  | x :: xs -> append (f x) (concat_map f xs)

let rec fold_left f accu = function
  | [] -> accu
  | a :: l -> fold_left f (f accu a) l

let rec fold_right f l accu =
  match l with
  | [] -> accu
  | a :: l -> f a (fold_right f l accu)

let rec iter2 f l1 l2 =
  match (l1, l2) with
  | [], [] -> ()
  | a1 :: l1, a2 :: l2 -> f a1 a2; iter2 f l1 l2
  | _, _ -> invalid_arg "List.iter2"

let rec map2 f l1 l2 =
  match (l1, l2) with
  | [], [] -> []
  | a1 :: l1, a2 :: l2 ->
      let r = f a1 a2 in
      r :: map2 f l1 l2
  | _, _ -> invalid_arg "List.map2"

let rev_map2 f l1 l2 =
  let rec aux accu l1 l2 =
    match (l1, l2) with
    | [], [] -> accu
    | a1 :: l1, a2 :: l2 -> aux (f a1 a2 :: accu) l1 l2
    | _, _ -> invalid_arg "List.rev_map2"
  in
  aux [] l1 l2

let rec fold_left2 f accu l1 l2 =
  match (l1, l2) with
  | [], [] -> accu
  | a1 :: l1, a2 :: l2 -> fold_left2 f (f accu a1 a2) l1 l2
  | _, _ -> invalid_arg "List.fold_left2"

let rec fold_right2 f l1 l2 accu =
  match (l1, l2) with
  | [], [] -> accu
  | a1 :: l1, a2 :: l2 -> f a1 a2 (fold_right2 f l1 l2 accu)
  | _, _ -> invalid_arg "List.fold_right2"

let rec for_all p = function
  | [] -> true
  | a :: l -> p a && for_all p l

let rec exists p = function
  | [] -> false
  | a :: l -> p a || exists p l

let rec for_all2 p l1 l2 =
  match (l1, l2) with
  | [], [] -> true
  | a1 :: l1, a2 :: l2 -> p a1 a2 && for_all2 p l1 l2
  | _, _ -> invalid_arg "List.for_all2"

let rec exists2 p l1 l2 =
  match (l1, l2) with
  | [], [] -> false
  | a1 :: l1, a2 :: l2 -> p a1 a2 || exists2 p l1 l2
  | _, _ -> invalid_arg "List.exists2"

let rec mem x = function
  | [] -> false
  | a :: l -> a = x || mem x l

let rec memq x = function
  | [] -> false
  | a :: l -> a == x || memq x l

let rec find p = function
  | [] -> raise Not_found
  | x :: l -> if p x then x else find p l

let rec find_opt p = function
  | [] -> None
  | x :: l -> if p x then Some x else find_opt p l

let find_index p l =
  let rec aux i = function
    | [] -> None
    | x :: xs -> if p x then Some i else aux (i + 1) xs
  in
  aux 0 l

let rec find_map f = function
  | [] -> None
  | x :: l -> (
      match f x with
      | Some _ as r -> r
      | None -> find_map f l)

let filter p l =
  let rec aux accu = function
    | [] -> rev accu
    | x :: l -> if p x then aux (x :: accu) l else aux accu l
  in
  aux [] l

let find_all = filter

let partition p l =
  let rec aux yes no = function
    | [] -> (rev yes, rev no)
    | x :: l -> if p x then aux (x :: yes) no l else aux yes (x :: no) l
  in
  aux [] [] l

let rec assoc x = function
  | [] -> raise Not_found
  | (a, b) :: l -> if a = x then b else assoc x l

let rec assoc_opt x = function
  | [] -> None
  | (a, b) :: l -> if a = x then Some b else assoc_opt x l

let rec assq x = function
  | [] -> raise Not_found
  | (a, b) :: l -> if a == x then b else assq x l

let rec assq_opt x = function
  | [] -> None
  | (a, b) :: l -> if a == x then Some b else assq_opt x l

let rec mem_assoc x = function
  | [] -> false
  | (a, _) :: l -> a = x || mem_assoc x l

let rec mem_assq x = function
  | [] -> false
  | (a, _) :: l -> a == x || mem_assq x l

let rec remove_assoc x = function
  | [] -> []
  | ((a, _) as pair) :: l ->
      if a = x then l else pair :: remove_assoc x l

let rec remove_assq x = function
  | [] -> []
  | ((a, _) as pair) :: l ->
      if a == x then l else pair :: remove_assq x l

let rec split = function
  | [] -> ([], [])
  | (x, y) :: l ->
      let rx, ry = split l in
      (x :: rx, y :: ry)

let rec combine l1 l2 =
  match (l1, l2) with
  | [], [] -> []
  | a1 :: l1, a2 :: l2 -> (a1, a2) :: combine l1 l2
  | _, _ -> invalid_arg "List.combine"

let rec merge cmp l1 l2 =
  match (l1, l2) with
  | [], l2 -> l2
  | l1, [] -> l1
  | h1 :: t1, h2 :: t2 ->
      if cmp h1 h2 <= 0 then h1 :: merge cmp t1 l2 else h2 :: merge cmp l1 t2

let rec chop_sort k l =
  if k = 0 then l
  else
    match l with
    | _ :: t -> chop_sort (k - 1) t
    | [] -> []

let rec rev_merge cmp l1 l2 accu =
  match (l1, l2) with
  | [], l2 -> rev_append l2 accu
  | l1, [] -> rev_append l1 accu
  | h1 :: t1, h2 :: t2 ->
      if cmp h1 h2 <= 0 then rev_merge cmp t1 l2 (h1 :: accu)
      else rev_merge cmp l1 t2 (h2 :: accu)

let rec rev_merge_rev cmp l1 l2 accu =
  match (l1, l2) with
  | [], l2 -> rev_append l2 accu
  | l1, [] -> rev_append l1 accu
  | h1 :: t1, h2 :: t2 ->
      if cmp h1 h2 > 0 then rev_merge_rev cmp t1 l2 (h1 :: accu)
      else rev_merge_rev cmp l1 t2 (h2 :: accu)

let rec sort_n cmp n l =
  match (n, l) with
  | 2, x1 :: x2 :: _ -> if cmp x1 x2 <= 0 then [ x1; x2 ] else [ x2; x1 ]
  | 3, x1 :: x2 :: x3 :: _ ->
      if cmp x1 x2 <= 0 then
        if cmp x2 x3 <= 0 then [ x1; x2; x3 ]
        else if cmp x1 x3 <= 0 then [ x1; x3; x2 ]
        else [ x3; x1; x2 ]
      else if cmp x1 x3 <= 0 then [ x2; x1; x3 ]
      else if cmp x2 x3 <= 0 then [ x2; x3; x1 ]
      else [ x3; x2; x1 ]
  | n, l ->
      let n1 = n / 2 in
      let n2 = n - n1 in
      let l2 = chop_sort n1 l in
      let s1 = rev_sort_n cmp n1 l in
      let s2 = rev_sort_n cmp n2 l2 in
      rev_merge_rev cmp s1 s2 []

and rev_sort_n cmp n l =
  match (n, l) with
  | 2, x1 :: x2 :: _ -> if cmp x1 x2 > 0 then [ x1; x2 ] else [ x2; x1 ]
  | 3, x1 :: x2 :: x3 :: _ ->
      if cmp x1 x2 > 0 then
        if cmp x2 x3 > 0 then [ x1; x2; x3 ]
        else if cmp x1 x3 > 0 then [ x1; x3; x2 ]
        else [ x3; x1; x2 ]
      else if cmp x1 x3 > 0 then [ x2; x1; x3 ]
      else if cmp x2 x3 > 0 then [ x2; x3; x1 ]
      else [ x3; x2; x1 ]
  | n, l ->
      let n1 = n / 2 in
      let n2 = n - n1 in
      let l2 = chop_sort n1 l in
      let s1 = sort_n cmp n1 l in
      let s2 = sort_n cmp n2 l2 in
      rev_merge cmp s1 s2 []

let stable_sort cmp l =
  let len = length l in
  if len < 2 then l else sort_n cmp len l

let sort = stable_sort
let fast_sort = stable_sort

let sort_uniq cmp l =
  let rec dedup prev acc = function
    | [] -> rev (prev :: acc)
    | x :: xs ->
        if cmp prev x = 0 then dedup prev acc xs
        else dedup x (prev :: acc) xs
  in
  match stable_sort cmp l with
  | [] -> []
  | x :: xs -> dedup x [] xs

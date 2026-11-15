external raise : exn -> 'a = "%raise"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( || ) : bool -> bool -> bool = "%sequor"

type 'a t

external create : int -> 'a t = "ocamlcc_weak_create"
external length : 'a t -> int = "ocamlcc_weak_length"
external set : 'a t -> int -> 'a option -> unit = "ocamlcc_weak_set"
external get : 'a t -> int -> 'a option = "ocamlcc_weak_get"
external check : 'a t -> int -> bool = "ocamlcc_weak_check"

let get_copy = get

let fill ar ofs len x =
  if ofs < 0 || len < 0 || ofs > length ar - len then
    raise (Invalid_argument "Weak.fill")
  else
    for i = ofs to ofs + len - 1 do
      set ar i x
    done

let blit ar1 of1 ar2 of2 len =
  if len < 0 || of1 < 0 || of1 > length ar1 - len
     || of2 < 0 || of2 > length ar2 - len
  then raise (Invalid_argument "Weak.blit")
  else if of1 < of2 then
    for i = len - 1 downto 0 do
      set ar2 (of2 + i) (get ar1 (of1 + i))
    done
  else
    for i = 0 to len - 1 do
      set ar2 (of2 + i) (get ar1 (of1 + i))
    done

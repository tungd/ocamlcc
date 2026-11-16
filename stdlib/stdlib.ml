external raise : exn -> 'a = "%raise"
external ignore : 'a -> unit = "%ignore"
external fst : 'a * 'b -> 'a = "%field0"
external snd : 'a * 'b -> 'b = "%field1"

external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external compare : 'a -> 'a -> int = "%compare"
external ( == ) : 'a -> 'a -> bool = "%eq"
external ( != ) : 'a -> 'a -> bool = "%noteq"

external not : bool -> bool = "%boolnot"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"

external ( ~- ) : int -> int = "%negint"
external ( ~+ ) : int -> int = "%identity"
external succ : int -> int = "%succint"
external pred : int -> int = "%predint"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external ( land ) : int -> int -> int = "%andint"
external ( lor ) : int -> int -> int = "%orint"
external ( lxor ) : int -> int -> int = "%xorint"
external ( lsl ) : int -> int -> int = "%lslint"
external ( lsr ) : int -> int -> int = "%lsrint"
external ( asr ) : int -> int -> int = "%asrint"

external int_of_char : char -> int = "%identity"
external unsafe_char_of_int : int -> char = "%identity"

type ('a, 'b) result = ('a, 'b) Stdlib__result.t =
  | Ok of 'a
  | Error of 'b

type ('a, 'b, 'c, 'd, 'e, 'f) format6 =
  ('a, 'b, 'c, 'd, 'e, 'f) CamlinternalFormatBasics.format6

type ('a, 'b, 'c, 'd) format4 = ('a, 'b, 'c, 'c, 'c, 'd) format6
type ('a, 'b, 'c) format = ('a, 'b, 'c, 'c) format4

type 'a ref = { mutable contents : 'a }

external ref : 'a -> 'a ref = "%makemutable"
external ( ! ) : 'a ref -> 'a = "%field0"
external ( := ) : 'a ref -> 'a -> unit = "%setfield0"
external incr : int ref -> unit = "%incr"
external decr : int ref -> unit = "%decr"

exception Exit

let invalid_arg s = raise (Invalid_argument s)
let failwith s = raise (Failure s)

let min x y = if x <= y then x else y
let max x y = if x >= y then x else y
let abs x = if x >= 0 then x else -x
let lnot x = x lxor (-1)
let max_int = (-1) lsr 1
let min_int = max_int + 1

let char_of_int n =
  if n < 0 || n > 255 then invalid_arg "char_of_int"
  else unsafe_char_of_int n

let ( ^ ) s1 s2 = Stdlib__string.cat s1 s2
let ( @ ) l1 l2 = Stdlib__list.append l1 l2

let string_of_bool = function
  | true -> "true"
  | false -> "false"

let bool_of_string = function
  | "true" -> true
  | "false" -> false
  | _ -> invalid_arg "bool_of_string"

let bool_of_string_opt = function
  | "true" -> Some true
  | "false" -> Some false
  | _ -> None

let string_of_int n =
  let neg = n < 0 in
  let rec digits acc v =
    let q = v / 10 in
    let r = abs (v - (q * 10)) in
    let c = unsafe_char_of_int (48 + r) in
    let acc = c :: acc in
    if q = 0 then acc else digits acc q
  in
  let cs = digits [] n in
  let cs = if neg then '-' :: cs else cs in
  let len = Stdlib__list.length cs in
  let b = Stdlib__bytes.create len in
  let rec fill i = function
    | [] -> Stdlib__bytes.unsafe_to_string b
    | c :: rest ->
        Stdlib__bytes.unsafe_set b i c;
        fill (i + 1) rest
  in
  fill 0 cs

let int_of_string_opt s =
  let len = Stdlib__string.length s in
  if len = 0 then None
  else
    let neg, start =
      match Stdlib__string.unsafe_get s 0 with
      | '-' -> (true, 1)
      | '+' -> (false, 1)
      | _ -> (false, 0)
    in
    if start >= len then None
    else
      let base, start, checked =
        if Stdlib__string.unsafe_get s start = '0' && start + 1 < len then
          match Stdlib__string.unsafe_get s (start + 1) with
          | 'x' | 'X' -> (16, start + 2, false)
          | 'o' | 'O' -> (8, start + 2, false)
          | 'b' | 'B' -> (2, start + 2, false)
          | 'u' | 'U' -> (10, start + 2, false)
          | _ -> (10, start, true)
        else (10, start, true)
      in
      if start >= len then None
      else
        let digit_value c =
          if c >= '0' && c <= '9' then int_of_char c - 48
          else if c >= 'a' && c <= 'f' then int_of_char c - 87
          else if c >= 'A' && c <= 'F' then int_of_char c - 55
          else base (* sentinel: not a digit in [base] *)
        in
        (* Accumulate negatively so [min_int] stays representable.
           Underscores are skipped after the first digit. *)
        let floor_min d = (if neg then min_int else min_int + 1) + d in
        let rec go i acc seen_digit =
          if i >= len then
            if seen_digit then Some (if neg then acc else -acc) else None
          else
            let c = Stdlib__string.unsafe_get s i in
            if c = '_' && seen_digit then go (i + 1) acc true
            else
              let d = digit_value c in
              if d >= base then None
              else if checked && acc < (floor_min d / base) then None
              else go (i + 1) ((acc * base) - d) true
        in
        go start 0 false

let int_of_string s =
  match int_of_string_opt s with
  | Some n -> n
  | None -> failwith "int_of_string"

external print_int : int -> unit = "ocamlcc_print_int_val"
external print_char : char -> unit = "ocamlcc_print_char_val"
external print_string : string -> unit = "ocamlcc_print_string_val"
external print_endline : string -> unit = "ocamlcc_print_endline_val"
external exit : int -> 'a = "ocamlcc_exit_val"

let print_newline () = print_char '\n'

external ( |> ) : 'a -> ('a -> 'b) -> 'b = "%revapply"
external ( @@ ) : ('a -> 'b) -> 'a -> 'b = "%apply"

module Option = Stdlib__option
module Result = Stdlib__result
module List = Stdlib__list
module Array = Stdlib__array
module Bytes = Stdlib__bytes
module String = Stdlib__string
module Buffer = Stdlib__buffer
module Hashtbl = Stdlib__hashtbl
module Printf = Stdlib__printf
module Weak = Stdlib__weak
module Fiber = Stdlib__fiber

type t = { value : int }

exception Lib_err of int

let offset = 10

let create v = { value = v }
let get x = x.value + offset
let square x = x * x
let pair_sum (a, b) = a + b + offset
let make_adder n x = n + x

let check n =
  if n < 0 then raise (Lib_err (0 - n))
  else n * 2

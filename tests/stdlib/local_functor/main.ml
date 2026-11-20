let initialized = ref 0

module Make (Order : sig val key : int -> int end) = struct
  let index = incr initialized; !initialized
  let[@inline never] project x = Order.key x + index
end

module Asc_order = struct let key x = x end
module Desc_order = struct let key x = -x end
module Asc = Make (Asc_order)
module Desc = Make (Desc_order)


let () =
  assert (!initialized = 2);
  assert (Asc.project 41 = 42);
  assert (Desc.project (-40) = 42);
  let f = Desc.project in
  assert (f 10 = -8);
  print_endline "local functors: PASS"

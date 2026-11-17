(**************************************************************************)
(*                                                                        *)
(*  Effect stub overlay for upstream OCaml stdlib (vendor/ocaml-stdlib)   *)
(*  Effect handlers require segmented stacks not enabled in pure ARC      *)
(*  single-stack mode; stub entry points fail explicitly at runtime.      *)
(*                                                                        *)
(**************************************************************************)

type 'a t = 'a eff = ..

exception Unhandled : 'a t -> exn
exception Continuation_already_resumed

external perform : 'a t -> 'a = "%perform"

module Deep = struct
  type nonrec ('a, 'b) continuation = ('a, 'b) continuation

  let continue _k _x = failwith "Effect: handlers unsupported"
  let discontinue _k _e = failwith "Effect: handlers unsupported"
  let discontinue_with_backtrace _k _e _bt =
    failwith "Effect: handlers unsupported"

  type ('a, 'b) handler =
    { retc: 'a -> 'b;
      exnc: exn -> 'b;
      effc: 'c.'c t -> (('c, 'b) continuation -> 'b) option }

  let match_with f v h =
    match f v with
    | x -> h.retc x
    | exception e -> h.exnc e

  type 'a effect_handler =
    { effc: 'b. 'b t -> (('b, 'a) continuation -> 'a) option }

  let try_with f v _h = f v

  external get_callstack :
    ('a, 'b) continuation -> int -> Printexc.raw_backtrace =
    "caml_get_continuation_callstack"
end

module Shallow = struct
  type ('a, 'b) continuation

  let fiber _f = failwith "Effect.Shallow: handlers unsupported"

  type ('a, 'b) handler =
    { retc: 'a -> 'b;
      exnc: exn -> 'b;
      effc: 'c.'c t -> (('c, 'a) continuation -> 'b) option }

  let continue_with _k _v _h = failwith "Effect.Shallow: handlers unsupported"
  let discontinue_with _k _e _h = failwith "Effect.Shallow: handlers unsupported"
  let discontinue_with_backtrace _k _e _bt _h =
    failwith "Effect.Shallow: handlers unsupported"

  external get_callstack :
    ('a, 'b) continuation -> int -> Printexc.raw_backtrace =
    "caml_get_continuation_callstack"
end

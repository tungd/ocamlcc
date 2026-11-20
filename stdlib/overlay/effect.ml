(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*      KC Sivaramakrishnan, Indian Institute of Technology, Madras       *)
(*                                                                        *)
(*   Copyright 2021 Indian Institute of Technology, Madras                *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

type 'a t = 'a eff = ..
external perform : 'a t -> 'a = "%perform"

type exn += Unhandled: 'a t -> exn
exception Continuation_already_resumed

(* Wire the public constructors into the coroutine primitives. *)
type _ t += Register_unhandled : unit t

external register_exceptions : exn -> exn -> unit =
  "ocamlcc_effect_register_exceptions"

let () = register_exceptions (Unhandled Register_unhandled)
    Continuation_already_resumed

type ('a, 'b) stack
type last_fiber [@@immediate]

external resume :
  ('a, 'b) stack -> ('c -> 'a) -> 'c -> last_fiber -> 'b = "%resume"
external runstack : ('a, 'b) stack -> ('c -> 'a) -> 'c -> 'b = "%runstack"

module Deep = struct

  type nonrec ('a,'b) continuation = ('a,'b) continuation

  external take_cont_noexc : ('a, 'b) continuation -> ('a, 'b) stack =
    "caml_continuation_use_noexc" [@@noalloc]
  external alloc_stack :
    ('a -> 'b) ->
    (exn -> 'b) ->
    ('c t -> ('c, 'b) continuation -> last_fiber -> 'b) ->
    ('a, 'b) stack = "caml_alloc_stack"
  external cont_last_fiber : ('a, 'b) continuation -> last_fiber = "%field1"

  let continue k v =
    resume (take_cont_noexc k) (fun x -> x) v (cont_last_fiber k)

  let discontinue k e =
    resume (take_cont_noexc k) (fun e -> raise e) e (cont_last_fiber k)

  let discontinue_with_backtrace k e bt =
    resume (take_cont_noexc k) (fun e -> Printexc.raise_with_backtrace e bt)
      e (cont_last_fiber k)

  type ('a,'b) handler =
    { retc: 'a -> 'b;
      exnc: exn -> 'b;
      effc: 'c.'c t -> (('c,'b) continuation -> 'b) option }

  external reperform :
    'a t -> ('a, 'b) continuation -> last_fiber -> 'b = "%reperform"

  let match_with comp arg handler =
    let effc eff k last_fiber =
      match handler.effc eff with
      | Some f -> f k
      | None -> reperform eff k last_fiber
    in
    let s = alloc_stack handler.retc handler.exnc effc in
    runstack s comp arg

  type 'a effect_handler =
    { effc: 'b. 'b t -> (('b,'a) continuation -> 'a) option }

  let try_with comp arg handler =
    let effc' eff k last_fiber =
      match handler.effc eff with
      | Some f -> f k
      | None -> reperform eff k last_fiber
    in
    let s = alloc_stack (fun x -> x) (fun e -> raise e) effc' in
    runstack s comp arg

  external get_callstack :
    ('a,'b) continuation -> int -> Printexc.raw_backtrace =
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

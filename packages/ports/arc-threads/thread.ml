(* OS-thread implementation of the stock systhreads [Thread] API subset.
   Each thread runs its function on its own OS thread; blocking calls park
   that thread.  The function result is discarded; uncaught exceptions go
   to the configured handler and are not propagated to [join]. *)

type t

external spawn : (unit -> unit) -> t = "caml_ml_thread_spawn"
external join_prim : t -> unit = "caml_ml_thread_join"
external self_prim : unit -> t = "caml_ml_thread_self"
external id_prim : t -> int = "caml_ml_thread_id"
external yield_prim : unit -> unit = "caml_ml_thread_yield"
external delay_us_prim : int -> unit = "caml_ml_thread_delay_us"
external set_name_prim : string -> unit = "caml_ml_thread_set_name"

exception Exit

let default_uncaught_exception_handler exn =
  prerr_endline ("Thread killed on uncaught exception: " ^ Printexc.to_string exn)

let uncaught_handler = ref default_uncaught_exception_handler

let set_uncaught_exception_handler f = uncaught_handler := f

let create f arg =
  spawn (fun () ->
      match f arg with
      | _ -> ()
      | exception Exit -> ()
      | exception exn -> !uncaught_handler exn)

let self () = self_prim ()
let id = id_prim
let join = join_prim
let yield = yield_prim

let delay d =
  let capped = if d > 1e12 then 1e12 else d in
  delay_us_prim (if capped <= 0. then 0 else int_of_float (capped *. 1e6))

let set_current_thread_name = set_name_prim

let exit () = raise Exit

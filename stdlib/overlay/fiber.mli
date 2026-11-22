(** Stackful coroutines and cooperative tasks on the calling OS thread. *)

type ('a, 'b) coro

val create : ('a -> 'b) -> ('a, 'b) coro
val resume : ('a, 'b) coro -> 'a -> 'b
val suspend : 'b -> 'a
val is_done : ('a, 'b) coro -> bool

type 'a t

val spawn : (unit -> 'a) -> 'a t
val await : 'a t -> 'a
val yield : unit -> unit
val sleep_ms : int -> unit
val run_all : unit -> unit

module Cancel : sig
  type t
  val create : unit -> t
  val cancel : t -> unit
  val is_cancelled : t -> bool
end
(** A one-way token shared by waits on the same scheduler thread. *)

module Direction : sig
  type t = Read | Write
end

module Wait_result : sig
  type t = Ready | Timed_out | Cancelled
end

val fd_wait : ?timeout_ms:int -> ?cancel:Cancel.t -> int -> Direction.t -> Wait_result.t
(** Wait for descriptor readiness. A zero timeout polls once. Cancellation is
    checked before each poll. Readiness returned by that poll wins over expiry.
    Only this wait's registration is removed on cancellation or timeout. *)

val fd_wait_read : int -> unit
val fd_wait_write : int -> unit

val pipe : unit -> int * int
val fd_read : int -> bytes -> int -> int -> int
val fd_write : int -> bytes -> int -> int -> int
val fd_close : int -> unit

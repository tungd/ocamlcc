type ('a, 'b) coro
type 'a t

external create : ('a -> 'b) -> ('a, 'b) coro = "ocamlcc_fiber_create"
external resume : ('a, 'b) coro -> 'a -> 'b = "ocamlcc_fiber_resume"
external suspend : 'b -> 'a = "ocamlcc_fiber_suspend"
external is_done : ('a, 'b) coro -> bool = "ocamlcc_fiber_is_done"

external spawn : (unit -> 'a) -> 'a t = "ocamlcc_fiber_spawn"
external yield : unit -> unit = "ocamlcc_fiber_yield"
external sleep_ms : int -> unit = "ocamlcc_fiber_sleep_ms"
external fd_wait_read : int -> unit = "ocamlcc_fiber_fd_wait_read"
external fd_wait_write : int -> unit = "ocamlcc_fiber_fd_wait_write"
external await : 'a t -> 'a = "ocamlcc_fiber_await"
external run_all : unit -> unit = "ocamlcc_fiber_run_all"

external pipe : unit -> int * int = "ocamlcc_pipe"
external fd_read : int -> bytes -> int -> int -> int = "ocamlcc_fd_read"
external fd_write : int -> bytes -> int -> int -> int = "ocamlcc_fd_write"
external fd_close : int -> unit = "ocamlcc_fd_close"

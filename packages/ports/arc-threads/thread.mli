(** [Thread] over OS threads: each thread runs its function concurrently
    with the other threads of the program.  Port of the stock systhreads
    API subset; blocking calls park the calling OS thread. *)

type t

val create : ('a -> 'b) -> 'a -> t
(** [Thread.create funct arg] creates a new thread running [funct arg]
    concurrently with the other threads.  It returns the handle of the new
    thread.  The result of [funct arg] is discarded.  If the thread
    terminates on an uncaught exception, the exception is passed to
    {!set_uncaught_exception_handler} and not propagated to {!join}.
    [Thread.Exit] reaching the top of [funct arg] terminates the thread
    silently. *)

val self : unit -> t
(** The handle of the calling thread. *)

val id : t -> int
(** A unique integer identifying the thread. *)

val set_current_thread_name : string -> unit
(** Name the calling thread.  Does nothing when unsupported. *)

exception Exit
(** Terminate the current thread silently when it reaches the top of the
    function passed to {!create}. *)

val exit : unit -> unit
[@@deprecated "Use 'raise Thread.Exit' instead."]
(** Raise {!Exit}. *)

val delay : float -> unit
(** [delay d] suspends the calling thread for [d] seconds. *)

val join : t -> unit
(** [join th] waits until thread [th] has terminated. *)

val yield : unit -> unit
(** Re-schedule the calling thread without suspending it. *)

val default_uncaught_exception_handler : exn -> unit
(** Prints the exception on standard error. *)

val set_uncaught_exception_handler : (exn -> unit) -> unit
(** Install the handler for uncaught exceptions in threads. *)

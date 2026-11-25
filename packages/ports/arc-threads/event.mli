(** Synchronous inter-thread communication over channels, in the style of
    John Reppy's Concurrent ML: communication events are first-class
    values that can be built and combined before being offered. *)

type 'a channel

val new_channel : unit -> 'a channel
(** A fresh channel. *)

type +'a event
(** An event describing a communication and its result. *)

val send : 'a channel -> 'a -> unit event
(** [send ch v] offers to send [v] on [ch].  Its result is [()]. *)

val receive : 'a channel -> 'a event
(** [receive ch] offers to receive a value from [ch].  Its result is the
    received value. *)

val always : 'a -> 'a event
(** [always v] is an event always ready with result [v]. *)

val choose : 'a event list -> 'a event
(** [choose evl] offers all the events of [evl] and commits to exactly one. *)

val wrap : 'a event -> ('a -> 'b) -> 'b event
(** [wrap ev fn] behaves as [ev] and applies [fn] to the result. *)

val wrap_abort : 'a event -> (unit -> unit) -> 'a event
(** [wrap_abort ev fn] behaves as [ev]; [fn] runs after synchronization
    when [ev] was not selected. *)

val guard : (unit -> 'a event) -> 'a event
(** [guard fn] evaluates [fn ()] at synchronization time. *)

val sync : 'a event -> 'a
(** [sync ev] offers the communications of [ev] and blocks until one
    commits, returning its result. *)

val select : 'a event list -> 'a
(** [select evl] is [sync (choose evl)]. *)

val poll : 'a event -> 'a option
(** [poll ev] tries [ev] without blocking; [None] when nothing is ready. *)

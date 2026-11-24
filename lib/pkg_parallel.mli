module Pool : sig
  type t

  val create : int -> t
  val jobs : t -> int
  val close : t -> unit
end

val default_jobs : unit -> int

val run_dag :
  ?pool:Pool.t ->
  ?held:bool ->
  ?index:Digest_index.t ->
  ?on_start:(int -> unit) ->
  ?on_event:(int -> 'e -> unit) ->
  ?on_done:(int -> 'a -> unit) ->
  deps:(int -> int list) ->
  prepare:(int -> 'a option array ->
    ([ `Ready of 'a | `Run of (('e -> unit) -> ('a, string) result) ], string) result) ->
  int ->
  ('a array, string) result

val map :
  ?pool:Pool.t ->
  ?held:bool ->
  ?index:Digest_index.t ->
  ?on_start:(int -> unit) ->
  ?on_event:(int -> 'e -> unit) ->
  ?on_done:(int -> 'a -> unit) ->
  (('e -> unit) -> ('a, string) result) list ->
  ('a list, string) result

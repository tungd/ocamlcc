(* Domain overlay backed by OS threads (matching upstream domain.mli).
   [spawn f] runs [f] on a fresh OS thread; [join] returns its result or
   re-raises its exception.  [count] stays 1 and DLS stays a single shared
   slot per key: neither models per-domain state on this runtime. *)

type !'a t

external spawn_prim : (unit -> 'a) -> 'a t = "caml_ml_thread_spawn"
external join_prim : 'a t -> 'a = "caml_ml_thread_join_value"
external self_prim : unit -> 'a t = "caml_ml_thread_self"
external id_prim : 'a t -> int = "caml_ml_thread_id"
external cpu_relax_prim : unit -> unit = "caml_ml_cpu_relax"
external recommended_prim : unit -> int = "caml_ml_cpu_count"

let spawn (f : unit -> 'a) : 'a t = spawn_prim f

let join (d : 'a t) : 'a = join_prim d

type id = int

let get_id (d : 'a t) : id = id_prim d
let self () : id = id_prim (self_prim ())
let before_first_spawn (f : unit -> unit) : unit = f ()
let at_exit (f : unit -> unit) : unit = Stdlib.at_exit f
let cpu_relax () : unit = cpu_relax_prim ()
let is_main_domain () : bool = self () = 0
let count () : int = 1
let recommended_domain_count () : int = recommended_prim ()
let self_index () : int = 0

module DLS = struct
  type 'a key = {
    init : unit -> 'a;
    mutable value : 'a option;
  }

  let new_key ?split_from_parent:_ init = { init; value = None }

  let get k =
    match k.value with
    | Some v -> v
    | None ->
        let v = k.init () in
        k.value <- Some v;
        v

  let set k v = k.value <- Some v
end

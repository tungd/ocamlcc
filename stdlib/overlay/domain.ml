(* Minimal single-domain overlay for Domain (matching upstream domain.mli). *)

type 'a t = { _val : 'a }

let spawn (_f : unit -> 'a) : 'a t =
  failwith "Domain.spawn: unsupported in single-domain runtime"

let join (d : 'a t) : 'a = d._val

type id = int

let get_id (_d : 'a t) : id = 0
let self () : id = 0
let before_first_spawn (f : unit -> unit) : unit = f ()
let at_exit (f : unit -> unit) : unit = Stdlib.at_exit f
let cpu_relax () : unit = ()
let is_main_domain () : bool = true
let count () : int = 1
let recommended_domain_count () : int = 1
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

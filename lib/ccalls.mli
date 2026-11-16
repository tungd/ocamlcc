(* C-call ABI registry: classification for every C external lowered to
   [Anf.Ccall] (see the header of [ccalls.ml] for the ownership contract). *)

type abi = {
  argc : int;      (* declared arity of the external *)
  raises : bool;   (* stores to [ocamlcc_exn_slot] on failure *)
  yields : bool;   (* can suspend the current fiber *)
}

val find_opt : string -> abi option
(** The known ABI of a C external, if it is in the registry. *)

val find : string -> abi
(** [find name] returns the registered ABI, or the conservative default for
    unknown user externals ([argc = 0; raises = true; yields = false]). *)

val is_known : string -> bool
(** [true] iff [name] is registered. Unknown [caml_*] primitives must not be
    lowered to [Ccall]. *)

module Step : sig
  type t = {
    modname : string;
    kind : [ `Mli | `Ml ];
    path : string;
  }
end

val plan_build_order : string list -> (Step.t list, string) result
(** Scan source dependencies and order compilation steps. Interfaces can
    break implementation cycles. Independent steps preserve input order. *)

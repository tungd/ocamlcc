module Step : sig
  type t = {
    modname : string;
    kind : [ `Mli | `Ml ];
    path : string;
  }
end

module Plan : sig
  type group = {
    steps : Step.t list;
    deps : int list;
  }
end

val plan_build_dag : string list -> (Plan.group list, string) result
(** Scan source dependencies and return topologically ordered step groups with
    prerequisite group indices. Groups with >1 step represent .mli-mediated
    implementation cycles that must run sequentially in the given order. *)

val plan_build_order : string list -> (Step.t list, string) result
(** Scan source dependencies and order compilation steps. Interfaces can
    break implementation cycles. Independent steps preserve input order. *)

val references : Step.t -> (string list, string) result

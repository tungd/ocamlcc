module Request : sig
  type t = {
    single_thread : bool;
    prefer_prebuilt : bool;
    include_main : bool;
    prebuilt_dir : string option;
    source_dir : string option;
    work_dir : string;
    toolchain : Target.Toolchain.t;
    verbose : bool;
  }
end

val link_inputs : Request.t -> (string list, string) result
(** Select the runtime profile and prepare its link inputs for the target. *)

module Request : sig
  type t = {
    steps : Dep_graph.Step.t list;
    work_dir : string;
    include_dirs : string list;
    stdlib : Stdlib_build.t;
    nostdlib : bool;
    nopervasives : bool;
    single_thread : bool;
    include_main : bool;
    publish_object : bool;
    qbe : string;
    target : Target.t;
    verbose : bool;
  }
end

type compiled = {
  assemblies : string list;
  object_interface : (string * string * Anf.exports) option;
}

val compile : Request.t -> (compiled, string) result

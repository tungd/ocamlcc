module Package_name : sig
  type t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val compare : t -> t -> int
end

module Rel_path : sig
  type t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val resolve : root:string -> t -> string
end

module Comp_input : sig
  type t
  val create : name:string -> source:string -> (t, string) result
  val name : t -> string
  val source : t -> Rel_path.t
end

type requirement = { name : Package_name.t; version : string }
type kind = Exe | Shared | Static
type test = { name : Package_name.t; entry : Rel_path.t; source_dir : Rel_path.t }

type manifest = {
  project : Package_name.t;
  kind : kind;
  entry : Rel_path.t option;
  source_dirs : Rel_path.t list;
  snapshot : Rel_path.t;
  requirements : requirement list;
  c_sources : Rel_path.t list;
  cflags : string list;
  ldflags : string list;
  public_mli : Rel_path.t list;
  single_thread_rc : bool;
  replacements : (Package_name.t * string) list;
  tests : test list;
}

val project : Package_name.t -> manifest

type archive = { url : string; digest : Sha256.t; root : Rel_path.t }
type source = Archive of archive | Local of Rel_path.t | Replacement of string
type wrapping = Flat | Wrapped of string

type recipe = {
  package : requirement;
  dependencies : Package_name.t list;
  source : source;
  tree : Sha256.t;
  wrapping : wrapping;
  files : Comp_input.t list;
  exports : string list;
  executable : Package_name.t option;
  license : string option;
}

type lock = { catalog : Rel_path.t; digest : Sha256.t; packages : recipe list }

val parse_manifest : string -> (manifest, string) result
val print_manifest : manifest -> string
val parse_snapshot : string -> (recipe list, string) result
val print_snapshot : recipe list -> string
val parse_lock : string -> (lock, string) result
val print_lock : lock -> string

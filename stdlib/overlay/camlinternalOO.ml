(**************************************************************************)
(*                                                                        *)
(*  Minimal CamlinternalOO overlay for upstream OCaml stdlib              *)
(*  Supports instance-variable-only dummy objects (e.g. Dynarray/Pqueue)  *)
(*  and fails explicitly on dynamic OO method dispatch.                   *)
(*                                                                        *)
(**************************************************************************)

type tag = int
type label = int
type meth = Obj.t
type t = Obj.t
type obj = Obj.t
type closure = Obj.t

type table = {
  mutable size : int;
  methods : meth array;
}

type init_table = table option ref
type tables = unit

type impl =
    GetConst
  | GetVar
  | GetEnv
  | GetMeth
  | SetVar
  | AppConst
  | AppVar
  | AppEnv
  | AppMeth
  | AppConstConst
  | AppConstVar
  | AppConstEnv
  | AppConstMeth
  | AppVarConst
  | AppEnvConst
  | AppMethConst
  | MethAppConst
  | MethAppVar
  | MethAppEnv
  | MethAppMeth
  | SendConst
  | SendVar
  | SendEnv
  | SendMeth
  | Closure of closure

type params = {
  mutable compact_table : bool;
  mutable copy_parent : bool;
  mutable clean_when_copying : bool;
  mutable retry_count : int;
  mutable bucket_small_size : int;
}

type stats = {
  classes : int;
  methods : int;
  inst_vars : int;
}

external caml_fresh_oo_id : unit -> int = "caml_fresh_oo_id" [@@noalloc]

let params = {
  compact_table = true;
  copy_parent = true;
  clean_when_copying = true;
  retry_count = 3;
  bucket_small_size = 16;
}

let stats () = { classes = 0; methods = 0; inst_vars = 0 }

let public_method_label s =
  let acc = ref 0 in
  for i = 0 to String.length s - 1 do
    acc := 223 * !acc + Char.code (String.unsafe_get s i)
  done;
  let a = !acc land ((1 lsl 31) - 1) in
  if a > 0x3fffffff then a - (1 lsl 31) else a

let dummy_table = { size = 2; methods = [| |] }

let create_table _pub_meths =
  { size = 2; methods = [| Obj.repr 0 |] }

let new_variable tbl _name =
  let idx = tbl.size in
  tbl.size <- idx + 1;
  idx

let new_variables tbl names =
  Array.map (new_variable tbl) names

let get_variable _tbl _name = 2
let get_variables tbl names = Array.map (get_variable tbl) names
let new_method _tbl = 0
let new_methods_variables tbl meths vars =
  ignore meths;
  new_variables tbl vars
let get_method_label _tbl _name = 0
let get_method_labels _tbl names = Array.make (Array.length names) 0
let get_method _tbl _lbl = Obj.repr 0
let set_method _tbl _lbl _m = ()
let set_methods _tbl _lbls = ()
let narrow _tbl _a _b _c = ()
let widen _tbl = ()
let add_initializer _tbl _f = ()
let init_class _tbl = ()

let inherits _tbl _a _b _c _parent _top = [| |]

let make_class _names _init =
  failwith "CamlinternalOO: classes unsupported"

let make_class_store _names _init _tbl_ref = ()

let dummy_class _info =
  failwith "CamlinternalOO: classes unsupported"

let copy o =
  let r = Obj.dup (Obj.repr o) in
  Obj.set_field r 1 (Obj.repr (caml_fresh_oo_id ()));
  Obj.obj r

let create_object tbl =
  let o = Obj.new_block Obj.object_tag tbl.size in
  Obj.set_field o 0 (Obj.repr tbl.methods);
  Obj.set_field o 1 (Obj.repr (caml_fresh_oo_id ()));
  o

let create_object_opt opt tbl =
  if Obj.repr opt == Obj.repr 0 then create_object tbl else opt

let run_initializers _o _tbl = ()
let run_initializers_opt _o0 o _tbl = o
let create_object_and_run_initializers _o tbl = create_object tbl

external send : obj -> tag -> t = "%send"
external sendcache : obj -> tag -> t -> int -> t = "%sendcache"
external sendself : obj -> label -> t = "%sendself"
external get_public_method : obj -> tag -> closure
  = "caml_get_public_method" [@@noalloc]

let lookup_tables _ts _cs = ()

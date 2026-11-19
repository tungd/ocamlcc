(* Codegen builder, per-function state, value-tagging helpers, and static
   data emission.

   Value representation (design doc §4.2): the least-significant bit tags
   immediates — [val land 1 = 1] is an unboxed 63-bit integer (OCaml [int],
   bool, char, constant constructor); even words are pointers to heap or
   immortal static objects prefixed by a 16-byte [ArcHeader]. *)

open Qbe_il

(* Module-level or local function registry entry. Members of a mutually
   tail-recursive group share one QBE function (the trampoline) selected by
   [tag]; [group_arity] is the group's uniform arity. [has_closure] is true
   when the function takes a hidden [ArcClosure*] first parameter. *)
type fn_info = {
  global : string;
  arity : int;
  tag : int64 option;
  group_arity : int;
  group_name : string option;
  has_closure : bool;
}

(* A static catch handler (pattern-match lowering): raise sites record their
   predecessor block and argument values for the handler's phis. *)
type handler = {
  hlabel : string;
  hbinders : Ident.t list;
  mutable hpreds : (string * t list) list; (* reversed *)
}

(* Per-function emission state, swapped atomically by [with_fn_state] when
   lowering nested functions or trampoline groups. *)
type fn_state = {
  mutable open_label : string;
  mutable insts : inst list;   (* reversed *)
  mutable start_allocs : inst list; (* reversed, hoisted to @start *)
  mutable term : term option;
  mutable blocks : block list; (* reversed, closed blocks *)
  mutable fn_params : (ty * string) list;
  handlers : (int, handler) Hashtbl.t;
  entry_label : string;
  self : Ident.t option;
  cur_group : string option;
  mutable tail_sites : (string * t list) list;
  mutable try_stack : string list;
  in_init : bool;
}

type t = {
  prefix : string;
  mutable temp_counter : int;
  mutable label_counter : int;
  mutable data_counter : int;
  vars : (Ident.t, Qbe_il.t) Hashtbl.t;
  mut_vars : (Ident.t, Qbe_il.t) Hashtbl.t;
  funs : (Ident.t, fn_info) Hashtbl.t;
  clos_wrappers : (Ident.t, string) Hashtbl.t;
  groups : (string, (Ident.t * Anf.lfunction) list) Hashtbl.t;
  compiled_groups : (string, unit) Hashtbl.t;
  mutable group_counter : int;
  used_globals : (string, unit) Hashtbl.t;
  mutable funcs : func list; (* reversed *)
  mutable datas : data list; (* reversed *)
  mutable cur_fn : fn_state;
}

let fresh_fn_state ?(entry_label = "start") ?(self = None) ?(cur_group = None)
    ?(in_init = false) () =
  { open_label = "start";
    insts = [];
    start_allocs = [];
    term = None;
    blocks = [];
    fn_params = [];
    handlers = Hashtbl.create 8;
    entry_label;
    self;
    cur_group;
    tail_sites = [];
    try_stack = [];
    in_init }

let create prefix =
  { prefix;
    temp_counter = 0;
    label_counter = 0;
    data_counter = 0;
    vars = Hashtbl.create 16;
    mut_vars = Hashtbl.create 8;
    funs = Hashtbl.create 16;
    clos_wrappers = Hashtbl.create 16;
    groups = Hashtbl.create 8;
    compiled_groups = Hashtbl.create 8;
    group_counter = 0;
    used_globals = Hashtbl.create 16;
    funcs = [];
    datas = [];
    cur_fn = fresh_fn_state ~in_init:true () }

(* Execute [f ()] with an isolated [fn_state], restoring the enclosing
   function's state even if [f] raises. *)
let with_fn_state b ~self ~cur_group ~entry_label ~in_init f =
  let saved = b.cur_fn in
  b.cur_fn <- fresh_fn_state ~entry_label ~self ~cur_group ~in_init ();
  Fun.protect ~finally:(fun () -> b.cur_fn <- saved) f

(* Temporarily shadow [b.vars] entries for [bindings] and restore prior
   values (or remove new ones) on exit. *)
let with_shadowed_vars b ids f =
  let saved = List.map (fun vid -> (vid, Hashtbl.find_opt b.vars vid)) ids in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (vid, prev) ->
          match prev with
          | Some v -> Hashtbl.replace b.vars vid v
          | None -> Hashtbl.remove b.vars vid)
        saved)
    f

(* QBE identifiers allow alphanumerics, '.', '_' and '$'. *)
let sanitize name =
  String.map
    (fun c ->
      if
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '.' || c = '_' || c = '$'
      then c
      else '_')
    name

let alloc_global_name b id =
  let base =
    Printf.sprintf "ocamlcc_%s_%s" b.prefix (sanitize (Ident.name id))
  in
  let rec pick n =
    let cand = if n = 0 then base else Printf.sprintf "%s_%d" base n in
    if not (Hashtbl.mem b.used_globals cand) then begin
      Hashtbl.replace b.used_globals cand ();
      cand
    end
    else pick (n + 1)
  in
  pick 0

let fresh_name b base =
  let n = Printf.sprintf "%s.%d" base b.temp_counter in
  b.temp_counter <- b.temp_counter + 1;
  n

let fresh_temp b base = Temp (fresh_name b base)

let fresh_label b base =
  let l = Printf.sprintf "%s.%d" base b.label_counter in
  b.label_counter <- b.label_counter + 1;
  l

let emit b inst =
  if b.cur_fn.term <> None then invalid_arg "codegen: instruction after terminator";
  b.cur_fn.insts <- inst :: b.cur_fn.insts

(* Hoist fixed-size alloc8 slots to @start so QBE treats them as static frame
   slots rather than dynamic alloca inside loops or tail-recursive @loop. *)
let emit_start_alloc b dst bytes =
  b.cur_fn.start_allocs <-
    Alloc8 (dst, Int (Int64.of_int bytes)) :: b.cur_fn.start_allocs

let finish_blocks b =
  let allocs = List.rev b.cur_fn.start_allocs in
  let blocks = List.rev b.cur_fn.blocks in
  if allocs = [] then blocks
  else
    List.map
      (fun blk ->
        if String.equal blk.label "start" then
          { blk with insts = allocs @ blk.insts }
        else blk)
      blocks

let close_block b term =
  match b.cur_fn.term with
  | Some _ -> invalid_arg "codegen: block already terminated"
  | None ->
      b.cur_fn.blocks <-
        { label = b.cur_fn.open_label; insts = List.rev b.cur_fn.insts; term }
        :: b.cur_fn.blocks;
      b.cur_fn.insts <- [];
      b.cur_fn.term <- Some term

let start_block b label =
  (match b.cur_fn.term with
  | None -> if b.cur_fn.insts <> [] then close_block b (Jmp label)
  | Some _ -> ());
  b.cur_fn.open_label <- label;
  b.cur_fn.term <- None

let close_ret b value =
  match b.cur_fn.term with
  | Some _ -> ()
  | None -> close_block b (Ret value)

(* ------------------------------------------------------------------ *)
(* Value representation & static data helpers                          *)
(* ------------------------------------------------------------------ *)

let arc_tag_array = 245
let arc_tag_closure = 247
let arc_tag_string = 252
let arc_tag_float = 253
let arc_tag_float_array = 254
let arc_tag_custom = 255

let custom_kind_int32 = 0l
let custom_kind_int64 = 1l
let custom_kind_nativeint = 2l

let unit_const = Int 1L

let tag_int n = Int64.logor (Int64.mul (Int64.of_int n) 2L) 1L

let ptr_offset b base off_bytes base_name =
  if off_bytes = 0 then base
  else
    let dst = fresh_temp b base_name in
    emit b (Binop (Add, Long, dst, base, Int (Int64.of_int off_bytes)));
    dst

let untag b v =
  let t = fresh_temp b "untag" in
  emit b (Binop (Sar, Long, t, v, Int 1L));
  t

let retag b v =
  let t = fresh_temp b "retag" in
  emit b (Binop (Shl, Long, t, v, Int 1L));
  let t' = fresh_temp b "tag" in
  emit b (Binop (Add, Long, t', t, Int 1L));
  t'

(* Emits an immortal ArcHeader + NUL-terminated bytes for a string literal
   and returns the data symbol (payload starts at offset 16). *)
let string_data b s =
  let name = Printf.sprintf "str.%d" b.data_counter in
  b.data_counter <- b.data_counter + 1;
  let len = String.length s in
  let plain c =
    let c = Char.code c in
    c >= 0x20 && c <= 0x7e && c <> Char.code '"' && c <> Char.code '\\'
  in
  let byte_items =
    let rec go run acc i =
      if i >= len then
        List.rev (D_byte 0 :: (if run = "" then acc else D_str run :: acc))
      else if plain s.[i] then
        go (String.concat "" [ run; String.make 1 s.[i] ]) acc (i + 1)
      else
        go ""
          (D_byte (Char.code s.[i]) :: (if run = "" then acc else D_str run :: acc))
          (i + 1)
    in
    go "" [] 0
  in
  let hdr_items =
    [ D_word (-1l);
      D_half arc_tag_string;
      D_half 0;
      D_word (Int32.of_int (len + 1));
      D_word (Int32.of_int len) ]
  in
  b.datas <-
    { name; export = false; align = Some 16; items = hdr_items @ byte_items }
    :: b.datas;
  name

let immortal_box_data b ~prefix ~tag ~byte_size ?(reserved = 0l) items =
  let name = Printf.sprintf "%s.%d" prefix b.data_counter in
  b.data_counter <- b.data_counter + 1;
  let hdr_items =
    [ D_word (-1l);
      D_half tag;
      D_half 0;
      D_word byte_size;
      D_word reserved ]
  in
  b.datas <-
    { name; export = false; align = Some 16; items = hdr_items @ items }
    :: b.datas;
  name

let float_data b f =
  immortal_box_data b ~prefix:"flt" ~tag:arc_tag_float ~byte_size:8l
    [ D_long (Int64.bits_of_float f) ]

let custom_data b kind bits =
  immortal_box_data b ~prefix:"cst" ~tag:arc_tag_custom ~byte_size:8l
    ~reserved:kind [ D_long bits ]

let float_array_data b fs =
  let items = List.map (fun f -> D_long (Int64.bits_of_float f)) fs in
  immortal_box_data b ~prefix:"fa" ~tag:arc_tag_float_array
    ~byte_size:(Int32.of_int (8 * List.length fs)) items

let rec const_data_item b (c : Anf.const_item) : data_item =
  match c with
  | C_int n -> D_long (tag_int n)
  | C_char ch -> D_long (tag_int (Char.code ch))
  | C_string s -> D_ref (string_data b s, 16L)
  | C_float f -> D_ref (float_data b f, 16L)
  | C_int32 n -> D_ref (custom_data b custom_kind_int32 (Int64.of_int32 n), 16L)
  | C_int64 n -> D_ref (custom_data b custom_kind_int64 n, 16L)
  | C_nativeint n ->
      D_ref (custom_data b custom_kind_nativeint (Int64.of_nativeint n), 16L)
  | C_float_array fs -> D_ref (float_array_data b fs, 16L)
  | C_block (tag, items) ->
      let sym = emit_const_block b tag items in
      D_ref (sym, 16L)

and emit_const_block b tag items =
  let name = Printf.sprintf "cblk.%d" b.data_counter in
  b.data_counter <- b.data_counter + 1;
  let nfields = List.length items in
  let field_items = List.map (const_data_item b) items in
  let hdr_items =
    [ D_word (-1l);
      D_half tag;
      D_half nfields;
      D_word (Int32.of_int (8 * nfields));
      D_word 0l ]
  in
  b.datas <-
    { name; export = false; align = Some 16; items = hdr_items @ field_items }
    :: b.datas;
  name

(* ------------------------------------------------------------------ *)
(* Shared runtime/lowering helpers                                     *)
(* ------------------------------------------------------------------ *)

let pad_to n (vs : Qbe_il.t list) : Qbe_il.t list =
  vs @ List.init (max 0 (n - List.length vs)) (fun _ -> unit_const)

let split_at n xs =
  let rec go acc i = function
    | rest when i <= 0 -> (List.rev acc, rest)
    | [] -> (List.rev acc, [])
    | x :: rest -> go (x :: acc) (i - 1) rest
  in
  go [] n xs

let cmp_of_ocaml : Lambda.integer_comparison -> Cmp.t = function
  | Ceq -> Eq
  | Cne -> Ne
  | Clt -> Slt
  | Cle -> Sle
  | Cgt -> Sgt
  | Cge -> Sge

let compile_bounds_guarded b ?drop_on_oob idx_untagged len_val
    (on_ok : unit -> Qbe_il.t) : Qbe_il.t =
  let ok = fresh_temp b "bnd" in
  emit b (Cmp (Ult, Long, ok, idx_untagged, len_val));
  let lok = fresh_label b "bnd_ok" in
  let loob = fresh_label b "bnd_oob" in
  let ldone = fresh_label b "bnd_done" in
  close_block b (Br (ok, lok, loob));
  start_block b lok;
  let ok_res = on_ok () in
  let lok_end = b.cur_fn.open_label in
  close_block b (Jmp ldone);
  start_block b loob;
  Option.iter
    (fun v ->
      emit b
        (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] }))
    drop_on_oob;
  emit b
    (Call_void { fn = Global "ocamlcc_raise_invalid_arg_oob"; args = [] });
  let loob_end = b.cur_fn.open_label in
  close_block b (Jmp ldone);
  start_block b ldone;
  let dst = fresh_temp b "bndv" in
  emit b (Phi (Long, dst, [ (lok_end, ok_res); (loob_end, unit_const) ]));
  dst

let string_len_raw b sv =
  let addr = fresh_temp b "slenp" in
  emit b (Binop (Sub, Long, addr, sv, Int 4L));
  let len = fresh_temp b "slen" in
  emit b (Load (Loaduw, Long, len, addr));
  len

let array_len_raw b av =
  let addr = fresh_temp b "alenp" in
  emit b (Binop (Sub, Long, addr, av, Int 8L));
  let bsz = fresh_temp b "absz" in
  emit b (Load (Loaduw, Long, bsz, addr));
  let len = fresh_temp b "alen" in
  emit b (Binop (Shr, Long, len, bsz, Int 3L));
  len

let emit_block_alloc b ?reuse_tok (tag : int) (vs : Qbe_il.t list) : Qbe_il.t =
  match vs with
  | [] -> unit_const
  | _ ->
      let n = List.length vs in
      let obj = fresh_temp b "blk" in
      let call =
        match reuse_tok with
        | Some tok ->
            { fn = Global "arc_alloc_reuse";
              args =
                [ (Long, tok);
                  (Long, Int (Int64.of_int tag));
                  (Long, Int (Int64.of_int n));
                  (Long, Int (Int64.of_int (8 * n))) ] }
        | None ->
            { fn = Global "arc_alloc";
              args =
                [ (Long, Int (Int64.of_int tag));
                  (Long, Int (Int64.of_int n));
                  (Long, Int (Int64.of_int (8 * n))) ] }
      in
      emit b (Call (Long, obj, call));
      List.iteri
        (fun i v ->
          let addr = ptr_offset b obj (8 * i) "fldp" in
          emit b (Store (Storel, v, addr)))
        vs;
      obj

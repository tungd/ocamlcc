(* ANF -> QBE IL code generation.

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

(* ------------------------------------------------------------------ *)
(* Builder                                                             *)
(* ------------------------------------------------------------------ *)

type builder = {
  prefix : string;
  mutable temp_counter : int;
  mutable label_counter : int;
  mutable data_counter : int;
  mutable open_label : string;
  mutable insts : inst list;   (* reversed *)
  mutable term : term option;
  mutable blocks : block list; (* reversed, closed blocks *)
  mutable fn_params : (ty * string) list;
  vars : (Ident.t, t) Hashtbl.t;
  mut_vars : (Ident.t, t) Hashtbl.t;
  funs : (Ident.t, fn_info) Hashtbl.t;
  clos_wrappers : (Ident.t, string) Hashtbl.t;
  groups : (string, (Ident.t * Anf.lfunction) list) Hashtbl.t;
  compiled_groups : (string, unit) Hashtbl.t;
  mutable group_counter : int;
  mutable handlers : (int, handler) Hashtbl.t;
  used_globals : (string, unit) Hashtbl.t;
  mutable funcs : func list; (* reversed *)
  mutable datas : data list; (* reversed *)
  mutable entry_label : string;
  mutable self : Ident.t option;
  mutable cur_group : string option;
  mutable tail_sites : (string * t list) list;
  mutable try_stack : string list;
  mutable in_init : bool;
}

let builder prefix =
  { prefix;
    temp_counter = 0;
    label_counter = 0;
    data_counter = 0;
    open_label = "start";
    insts = [];
    term = None;
    blocks = [];
    fn_params = [];
    vars = Hashtbl.create 16;
    mut_vars = Hashtbl.create 8;
    funs = Hashtbl.create 16;
    clos_wrappers = Hashtbl.create 16;
    groups = Hashtbl.create 8;
    compiled_groups = Hashtbl.create 8;
    group_counter = 0;
    handlers = Hashtbl.create 8;
    used_globals = Hashtbl.create 16;
    funcs = [];
    datas = [];
    entry_label = "start";
    self = None;
    cur_group = None;
    tail_sites = [];
    try_stack = [];
    in_init = true }

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
  if b.term <> None then invalid_arg "codegen: instruction after terminator";
  b.insts <- inst :: b.insts

let close_block b term =
  match b.term with
  | Some _ -> invalid_arg "codegen: block already terminated"
  | None ->
      b.blocks <-
        { label = b.open_label; insts = List.rev b.insts; term }
        :: b.blocks;
      b.insts <- [];
      b.term <- Some term

let start_block b label =
  (match b.term with
  | None -> if b.insts <> [] then close_block b (Jmp label)
  | Some _ -> ());
  b.open_label <- label;
  b.term <- None

let close_ret b value =
  match b.term with
  | Some _ -> ()
  | None -> close_block b (Ret value)

(* ------------------------------------------------------------------ *)
(* Value representation & static data helpers                          *)
(* ------------------------------------------------------------------ *)

let arc_tag_array = 245
let arc_tag_closure = 247
let arc_tag_string = 252

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

let rec const_data_item b (c : Anf.const_item) : data_item =
  match c with
  | C_int n -> D_long (tag_int n)
  | C_char ch -> D_long (tag_int (Char.code ch))
  | C_string s -> D_ref (string_data b s, 16L)
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
(* Helpers                                                             *)
(* ------------------------------------------------------------------ *)

let pad_to n (vs : t list) : t list =
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
    (on_ok : unit -> t) : t =
  let ok = fresh_temp b "bnd" in
  emit b (Cmp (Ult, Long, ok, idx_untagged, len_val));
  let lok = fresh_label b "bnd_ok" in
  let loob = fresh_label b "bnd_oob" in
  let ldone = fresh_label b "bnd_done" in
  close_block b (Br (ok, lok, loob));
  start_block b lok;
  let ok_res = on_ok () in
  let lok_end = b.open_label in
  close_block b (Jmp ldone);
  start_block b loob;
  Option.iter
    (fun v ->
      emit b
        (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] }))
    drop_on_oob;
  emit b
    (Call_void { fn = Global "ocamlcc_raise_invalid_arg_oob"; args = [] });
  let loob_end = b.open_label in
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

let free_vars_of b ?self_id (lf : Anf.lfunction) : Ident.t list =
  Anf.free_vars lf.body
  |> Ident.Set.filter (fun v ->
         not (List.exists (fun (p, _) -> Ident.same p v) lf.params)
         && (match self_id with Some s -> not (Ident.same s v) | None -> true)
         &&
         match Hashtbl.find_opt b.funs v with
         | Some info -> info.has_closure
         | None -> true)
  |> Ident.Set.elements

(* ------------------------------------------------------------------ *)
(* Atoms, computations, and ANF expressions                            *)
(* ------------------------------------------------------------------ *)

let emit_block_alloc b ?reuse_tok (tag : int) (vs : t list) : t =
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

let rec compile_atom b (a : Anf.atom) : t =
  match a with
  | Int n -> Int (tag_int n)
  | Char c -> Int (tag_int (Char.code c))
  | Unit -> unit_const
  | String s ->
      let sym = string_data b s in
      let dst = fresh_temp b "str" in
      emit b (Binop (Add, Long, dst, Global sym, Int 16L));
      dst
  | ConstBlock (tag, items) ->
      let sym = emit_const_block b tag items in
      let dst = fresh_temp b "cblk" in
      emit b (Binop (Add, Long, dst, Global sym, Int 16L));
      dst
  | Var id -> (
      match Hashtbl.find_opt b.vars id with
      | Some v -> v
      | None -> (
          match Hashtbl.find_opt b.funs id with
          | Some info when not info.has_closure -> closure_value_of b id
          | _ ->
              failwith
                (Printf.sprintf "codegen: unbound variable %s"
                   (sanitize (Ident.name id)))))
  | MutVar id -> (
      match Hashtbl.find_opt b.mut_vars id with
      | Some slot ->
          let dst = fresh_temp b "mut" in
          emit b (Load (Loadl, Long, dst, slot));
          dst
      | None -> (
          match Hashtbl.find_opt b.vars id with
          | Some v -> v
          | None ->
              failwith
                (Printf.sprintf "codegen: unbound mutable variable %s"
                   (sanitize (Ident.name id)))))

and compile_div_mod b qop (av : t) (cv : t) : t =
  let ua = untag b av in
  let uc = untag b cv in
  let lok = fresh_label b "div_ok" in
  let lzero = fresh_label b "div_zero" in
  let ldone = fresh_label b "div_done" in
  close_block b (Br (uc, lok, lzero));
  start_block b lok;
  let raw = fresh_temp b "divr" in
  emit b (Binop (qop, Long, raw, ua, uc));
  let res = retag b raw in
  let lok_end = b.open_label in
  close_block b (Jmp ldone);
  start_block b lzero;
  let ex = fresh_temp b "divex" in
  emit b (Load (Loadl, Long, ex, Global "ocamlcc_global_Division_by_zero"));
  emit b (Store (Storel, ex, Global "ocamlcc_exn_slot"));
  let lzero_end = b.open_label in
  close_block b (Jmp ldone);
  start_block b ldone;
  let dst = fresh_temp b "divv" in
  emit b (Phi (Long, dst, [ (lok_end, res); (lzero_end, unit_const) ]));
  dst

and compile_binop b (op : Anf.binop) (a : Anf.atom) (c : Anf.atom) : t =
  let av = compile_atom b a in
  let cv = compile_atom b c in
  match op with
  | Add ->
      let sum = fresh_temp b "sum" in
      let dst = fresh_temp b "arith" in
      emit b (Binop (Add, Long, sum, av, cv));
      emit b (Binop (Sub, Long, dst, sum, Int 1L));
      dst
  | Sub ->
      let diff = fresh_temp b "sub" in
      let dst = fresh_temp b "arith" in
      emit b (Binop (Sub, Long, diff, av, cv));
      emit b (Binop (Add, Long, dst, diff, Int 1L));
      dst
  | Mul ->
      let ua = untag b av in
      let uc = untag b cv in
      let prod = fresh_temp b "mul" in
      emit b (Binop (Mul, Long, prod, ua, uc));
      retag b prod
  | Div -> compile_div_mod b Div av cv
  | Mod -> compile_div_mod b Rem av cv
  | And ->
      let dst = fresh_temp b "land" in
      emit b (Binop (And, Long, dst, av, cv));
      dst
  | Or ->
      let dst = fresh_temp b "lor" in
      emit b (Binop (Or, Long, dst, av, cv));
      dst
  | Xor ->
      let x = fresh_temp b "lxor" in
      let dst = fresh_temp b "lxor_t" in
      emit b (Binop (Xor, Long, x, av, cv));
      emit b (Binop (Or, Long, dst, x, Int 1L));
      dst
  | Lsl ->
      let ua = untag b av in
      let uc = untag b cv in
      let s = fresh_temp b "lsl" in
      emit b (Binop (Shl, Long, s, ua, uc));
      retag b s
  | Asr ->
      let ua = untag b av in
      let uc = untag b cv in
      let s = fresh_temp b "asr" in
      emit b (Binop (Sar, Long, s, ua, uc));
      retag b s
  | Lsr ->
      let ua = fresh_temp b "lsru" in
      emit b (Binop (Shr, Long, ua, av, Int 1L));
      let uc = untag b cv in
      let s = fresh_temp b "lsr" in
      emit b (Binop (Shr, Long, s, ua, uc));
      retag b s
  | Cmp cmp ->
      let raw = fresh_temp b "cmp" in
      emit b (Cmp (cmp_of_ocaml cmp, Long, raw, av, cv));
      retag b raw
  | Compare_ints ->
      let gt = fresh_temp b "cgt" in
      let lt = fresh_temp b "clt" in
      let diff = fresh_temp b "cdiff" in
      emit b (Cmp (Sgt, Long, gt, av, cv));
      emit b (Cmp (Slt, Long, lt, av, cv));
      emit b (Binop (Sub, Long, diff, gt, lt));
      retag b diff
  | Isout ->
      let raw = fresh_temp b "isout" in
      emit b (Cmp (Ult, Long, raw, av, cv));
      retag b raw

and compile_unop b (op : Anf.unop) (a : Anf.atom) : t =
  let av = compile_atom b a in
  match op with
  | Neg ->
      let dst = fresh_temp b "neg" in
      emit b (Binop (Sub, Long, dst, Int 2L, av));
      dst
  | Not ->
      let dst = fresh_temp b "not" in
      emit b (Binop (Sub, Long, dst, Int 4L, av));
      dst
  | Offset k ->
      let dst = fresh_temp b "off" in
      emit b (Binop (Add, Long, dst, av, Int (Int64.mul (Int64.of_int k) 2L)));
      dst
  | Isint ->
      let bit = fresh_temp b "isint" in
      emit b (Binop (And, Long, bit, av, Int 1L));
      retag b bit
  | String_length ->
      let len = string_len_raw b av in
      retag b len
  | Array_length ->
      let len = array_len_raw b av in
      retag b len

and compile_cexpr b ~tail (ce : Anf.cexpr) : t =
  match ce with
  | Atom a -> compile_atom b a
  | Binop (op, a, c) -> compile_binop b op a c
  | Unop (op, a) -> compile_unop b op a
  | MakeBlock (tag, args) ->
      emit_block_alloc b tag (List.map (compile_atom b) args)
  | AllocReuse (tok_id, tag, args) ->
      let tok = Hashtbl.find b.vars tok_id in
      emit_block_alloc b ~reuse_tok:tok tag (List.map (compile_atom b) args)
  | MakeArray (kind, args) ->
      let vs = List.map (compile_atom b) args in
      let n = List.length vs in
      let scan =
        match kind with
        | Lambda.Pintarray | Pfloatarray -> 0
        | Pgenarray | Paddrarray -> min n 0xffff
      in
      let arr = fresh_temp b "arr" in
      emit b
        (Call
           ( Long,
             arr,
             { fn = Global "arc_alloc";
               args =
                 [ (Long, Int (Int64.of_int arc_tag_array));
                   (Long, Int (Int64.of_int scan));
                   (Long, Int (Int64.of_int (8 * n))) ] } ));
      List.iteri
        (fun i v ->
          let addr = ptr_offset b arr (8 * i) "arrp" in
          emit b (Store (Storel, v, addr)))
        vs;
      arr
  | Field (i, arg) ->
      let obj = compile_atom b arg in
      let addr = ptr_offset b obj (8 * i) "fldp" in
      let dst = fresh_temp b "fld" in
      emit b (Load (Loadl, Long, dst, addr));
      emit b (Call_void { fn = Global "arc_retain_val"; args = [ (Long, dst) ] });
      dst
  | SetField (i, arg, rhs) ->
      let obj = compile_atom b arg in
      let v = compile_atom b rhs in
      let addr = ptr_offset b obj (8 * i) "fldp" in
      let old_v = fresh_temp b "oldf" in
      emit b (Load (Loadl, Long, old_v, addr));
      emit b (Store (Storel, v, addr));
      emit b (Call_void { fn = Global "arc_release_val"; args = [ (Long, old_v) ] });
      unit_const
  | OffsetRef (k, arg) ->
      let obj = compile_atom b arg in
      let cur = fresh_temp b "refv" in
      emit b (Load (Loadl, Long, cur, obj));
      let next = fresh_temp b "refn" in
      emit b (Binop (Add, Long, next, cur, Int (Int64.mul (Int64.of_int k) 2L)));
      emit b (Store (Storel, next, obj));
      unit_const
  | StringGet (safe, s, idx) ->
      let sv = compile_atom b s in
      let iv = compile_atom b idx in
      let ui = untag b iv in
      let do_read () =
        let caddr = fresh_temp b "strp" in
        emit b (Binop (Add, Long, caddr, sv, ui));
        let ch = fresh_temp b "chr" in
        emit b (Load (Loadub, Long, ch, caddr));
        retag b ch
      in
      if safe then
        let len = string_len_raw b sv in
        compile_bounds_guarded b ui len do_read
      else do_read ()
  | BytesSet (safe, bs, idx, ch) ->
      let bsv = compile_atom b bs in
      let iv = compile_atom b idx in
      let cv = compile_atom b ch in
      let ui = untag b iv in
      let uc = untag b cv in
      let do_write () =
        let caddr = fresh_temp b "strp" in
        emit b (Binop (Add, Long, caddr, bsv, ui));
        emit b (Store (Storeb, uc, caddr));
        unit_const
      in
      if safe then
        let len = string_len_raw b bsv in
        compile_bounds_guarded b ui len do_write
      else do_write ()
  | ArrayGet (safe, _, arr, idx) ->
      let av = compile_atom b arr in
      let iv = compile_atom b idx in
      let ui = untag b iv in
      let do_read () =
        let off = fresh_temp b "aoff" in
        emit b (Binop (Shl, Long, off, ui, Int 3L));
        let eaddr = fresh_temp b "arrp" in
        emit b (Binop (Add, Long, eaddr, av, off));
        let dst = fresh_temp b "avel" in
        emit b (Load (Loadl, Long, dst, eaddr));
        emit b
          (Call_void { fn = Global "arc_retain_val"; args = [ (Long, dst) ] });
        dst
      in
      if safe then
        let len = array_len_raw b av in
        compile_bounds_guarded b ui len do_read
      else do_read ()
  | ArraySet (safe, kind, arr, idx, v) ->
      let av = compile_atom b arr in
      let iv = compile_atom b idx in
      let vv = compile_atom b v in
      let ui = untag b iv in
      let do_write () =
        let off = fresh_temp b "aoff" in
        emit b (Binop (Shl, Long, off, ui, Int 3L));
        let eaddr = fresh_temp b "arrp" in
        emit b (Binop (Add, Long, eaddr, av, off));
        (match kind with
        | Lambda.Pintarray | Lambda.Pfloatarray ->
            emit b (Store (Storel, vv, eaddr))
        | Pgenarray | Paddrarray ->
            let old_v = fresh_temp b "olda" in
            emit b (Load (Loadl, Long, old_v, eaddr));
            emit b (Store (Storel, vv, eaddr));
            emit b
              (Call_void
                 { fn = Global "arc_release_val"; args = [ (Long, old_v) ] }));
        unit_const
      in
      if safe then
        let len = array_len_raw b av in
        compile_bounds_guarded b ~drop_on_oob:vv ui len do_write
      else do_write ()
  | CreateBytes len ->
      let lv = compile_atom b len in
      let ul = untag b lv in
      let dst = fresh_temp b "bytes" in
      emit b (Call (Long, dst, { fn = Global "arc_alloc_bytes"; args = [ (Long, ul) ] }));
      dst
  | MakeArrayInit (len, init) ->
      let lv = compile_atom b len in
      let iv = compile_atom b init in
      let ul = untag b lv in
      let dst = fresh_temp b "arr" in
      emit b
        (Call
           ( Long,
             dst,
             { fn = Global "arc_alloc_array"; args = [ (Long, ul); (Long, iv) ] } ));
      dst
  | Builtin (symbol, arg_kind, arg) ->
      let v = compile_atom b arg in
      let raw =
        match arg_kind with
        | Builtins.Int_arg -> untag b v
        | Builtins.String_arg -> v
      in
      let args =
        match arg_kind with
        | Builtins.Int_arg -> [ (Long, raw) ]
        | Builtins.String_arg -> [ (Long, raw); (Long, string_len_raw b v) ]
      in
      emit b (Call_void { fn = Global symbol; args });
      unit_const
  | Ccall (sym, args) ->
      let dst = fresh_temp b "cc" in
      let cargs = List.map (fun a -> (Long, compile_atom b a)) args in
      emit b (Call (Long, dst, { fn = Global sym; args = cargs }));
      dst
  | GetGlobal mod_name ->
      let gsym = "ocamlcc_global_" ^ sanitize mod_name in
      let gv = fresh_temp b "glob" in
      emit b (Load (Loadl, Long, gv, Global gsym));
      emit b (Call_void { fn = Global "arc_retain_val"; args = [ (Long, gv) ] });
      gv
  | App (fn, args) -> apply b tail fn args
  | Fun _ -> failwith "codegen: Fun must be bound by Let"
  | Assign (id, rhs) -> (
      let v = compile_atom b rhs in
      match Hashtbl.find_opt b.mut_vars id with
      | Some slot ->
          let old_v = fresh_temp b "oldm" in
          emit b (Load (Loadl, Long, old_v, slot));
          emit b (Store (Storel, v, slot));
          emit b
            (Call_void
               { fn = Global "arc_release_val"; args = [ (Long, old_v) ] });
          unit_const
      | None ->
          failwith
            (Printf.sprintf "codegen: assignment to non-mutable %s"
               (sanitize (Ident.name id))))

and apply_closure b clos_val (arg_vals : t list) : t =
  let n = List.length arg_vals in
  let dst = fresh_temp b "capp" in
  let call_helper sym args =
    emit b
      (Call
         ( Long,
           dst,
           { fn = Global sym;
             args = (Long, clos_val) :: List.map (fun v -> (Long, v)) args } ));
    dst
  in
  match n with
  | 0 -> clos_val
  | 1 -> call_helper "ocamlcc_apply1" arg_vals
  | 2 -> call_helper "ocamlcc_apply2" arg_vals
  | 3 -> call_helper "ocamlcc_apply3" arg_vals
  | 4 -> call_helper "ocamlcc_apply4" arg_vals
  | _ ->
      let arr = fresh_temp b "argv" in
      emit b (Alloc8 (arr, Int (Int64.of_int (8 * n))));
      List.iteri
        (fun i v ->
          let addr = ptr_offset b arr (8 * i) "argp" in
          emit b (Store (Storel, v, addr)))
        arg_vals;
      emit b
        (Call
           ( Long,
             dst,
             { fn = Global "ocamlcc_apply_n";
               args =
                 [ (Long, clos_val); (Long, Int (Int64.of_int n)); (Long, arr) ] } ));
      dst

and apply b tail (fn_atom : Anf.atom) (ap_args : Anf.atom list) : t =
  let is_self id =
    match b.self with
    | Some s -> Ident.same s id
    | None -> false
  in
  match fn_atom with
  | Var id -> (
      match Hashtbl.find_opt b.funs id with
      | Some info when List.length ap_args = info.arity -> (
          if info.has_closure then begin
            if tail && is_self id then begin
              let vs = List.map (compile_atom b) ap_args in
              b.tail_sites <- (b.open_label, vs) :: b.tail_sites;
              close_block b (Jmp b.entry_label);
              unit_const
            end
            else begin
              let clos_val = Hashtbl.find b.vars id in
              let arg_vals = List.map (compile_atom b) ap_args in
              let dst = fresh_temp b "call" in
              emit b
                (Call
                   ( Long,
                     dst,
                     { fn = Global info.global;
                       args =
                         (Long, clos_val)
                         :: List.map (fun v -> (Long, v)) arg_vals } ));
              dst
            end
          end
          else
            match (info.tag, tail) with
            | Some tag, true when b.cur_group = info.group_name ->
                let vs =
                  pad_to info.group_arity (List.map (compile_atom b) ap_args)
                in
                b.tail_sites <- (b.open_label, Int tag :: vs) :: b.tail_sites;
                close_block b (Jmp b.entry_label);
                unit_const
            | Some tag, _ ->
                let vs =
                  pad_to info.group_arity (List.map (compile_atom b) ap_args)
                in
                let dst = fresh_temp b "call" in
                emit b
                  (Call
                     ( Long,
                       dst,
                       { fn = Global info.global;
                         args =
                           (Long, Int tag) :: List.map (fun v -> (Long, v)) vs } ));
                dst
            | None, true when is_self id ->
                let vs = List.map (compile_atom b) ap_args in
                b.tail_sites <- (b.open_label, vs) :: b.tail_sites;
                close_block b (Jmp b.entry_label);
                unit_const
            | None, _ ->
                let args =
                  List.map (fun a -> (Long, compile_atom b a)) ap_args
                in
                let dst = fresh_temp b "call" in
                emit b (Call (Long, dst, { fn = Global info.global; args }));
                dst)
      | Some info when List.length ap_args > info.arity ->
          let first_args, rest_args = split_at info.arity ap_args in
          let clos_res = apply b false fn_atom first_args in
          let rest_vals = List.map (compile_atom b) rest_args in
          let ex = fresh_temp b "oex" in
          emit b (Load (Loadl, Long, ex, Global "ocamlcc_exn_slot"));
          let lerr = fresh_label b "oapp_err" in
          let lok = fresh_label b "oapp_ok" in
          let ljoin = fresh_label b "oapp_join" in
          close_block b (Br (ex, lerr, lok));
          start_block b lerr;
          List.iter
            (fun v ->
              emit b
                (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] }))
            rest_vals;
          let lerr_end = b.open_label in
          close_block b (Jmp ljoin);
          start_block b lok;
          let final_v = apply_closure b clos_res rest_vals in
          emit b
            (Call_void
               { fn = Global "arc_release_val"; args = [ (Long, clos_res) ] });
          let lok_end = b.open_label in
          close_block b (Jmp ljoin);
          start_block b ljoin;
          let dst = fresh_temp b "oapp" in
          emit b (Phi (Long, dst, [ (lerr_end, unit_const); (lok_end, final_v) ]));
          dst
      | Some info ->
          let clos_val =
            if info.has_closure then Hashtbl.find b.vars id
            else closure_value_of b id
          in
          let arg_vals = List.map (compile_atom b) ap_args in
          apply_closure b clos_val arg_vals
      | None ->
          let clos_val = compile_atom b fn_atom in
          let arg_vals = List.map (compile_atom b) ap_args in
          apply_closure b clos_val arg_vals)
  | _ ->
      let clos_val = compile_atom b fn_atom in
      let arg_vals = List.map (compile_atom b) ap_args in
      apply_closure b clos_val arg_vals

and compile_aexpr b (tail : bool) (e : Anf.aexpr) : t =
  match e with
  | Halt a -> compile_atom b a
  | Let (id, Fun lf, body) -> (
      match Hashtbl.find_opt b.funs id with
      | Some info when not info.has_closure ->
          define_pure_function b id lf info;
          compile_aexpr b tail body
      | _ ->
          let env = free_vars_of b lf in
          let g = alloc_global_name b id in
          let has_closure = env <> [] in
          Hashtbl.replace b.funs id
            { global = g;
              arity = List.length lf.params;
              tag = None;
              group_arity = List.length lf.params;
              group_name = None;
              has_closure };
          ignore (compile_function b id lf ~has_closure ~env);
          if has_closure then begin
            let clos = alloc_closure b g (List.length lf.params) env in
            Hashtbl.replace b.vars id clos;
            let res = compile_aexpr b tail body in
            Hashtbl.remove b.vars id;
            Hashtbl.remove b.funs id;
            res
          end
          else begin
            let res = compile_aexpr b tail body in
            Hashtbl.remove b.funs id;
            res
          end)
  | Let (id, (App _ as ce), Halt (Var v)) when tail && Ident.same id v ->
      compile_cexpr b ~tail:true ce
  | Let (id, ce, body) ->
      let v = compile_cexpr b ~tail:false ce in
      if b.term <> None then unit_const
      else begin
        Hashtbl.replace b.vars id v;
        let res = compile_aexpr b tail body in
        Hashtbl.remove b.vars id;
        res
      end
  | MutLet (id, ce, body) ->
      let v = compile_cexpr b ~tail:false ce in
      let slot = fresh_temp b "mslot" in
      emit b (Alloc8 (slot, Int 8L));
      emit b (Store (Storel, v, slot));
      Hashtbl.replace b.mut_vars id slot;
      let res = compile_aexpr b tail body in
      Hashtbl.remove b.mut_vars id;
      res
  | LetJoin (id, rhs, body) ->
      let v = compile_aexpr b false rhs in
      if b.term <> None then unit_const
      else begin
        Hashtbl.replace b.vars id v;
        let res = compile_aexpr b tail body in
        Hashtbl.remove b.vars id;
        res
      end
  | LetRec (bindings, body) -> compile_letrec b tail bindings body
  | If (cond, th, el) -> compile_if b tail cond th el
  | Switch (scrut, sw) -> compile_switch b tail scrut sw
  | StringSwitch (scrut, cases, fail) ->
      compile_stringswitch b tail scrut cases fail
  | StaticCatch (body, id, binders, handler) ->
      staticcatch b tail id binders body handler
  | StaticRaise (id, args) -> (
      match Hashtbl.find_opt b.handlers id with
      | Some h ->
          let vs = List.map (compile_atom b) args in
          h.hpreds <- (b.open_label, vs) :: h.hpreds;
          close_block b (Jmp h.hlabel);
          unit_const
      | None -> failwith "codegen: uncaught static raise")
  | While (cond, body) ->
      let lcond = fresh_label b "wcond" in
      close_block b (Jmp lcond);
      start_block b lcond;
      let cv_tagged = compile_aexpr b false cond in
      if b.term = None then begin
        let lbody = fresh_label b "wbody" in
        let ldone = fresh_label b "wdone" in
        let cv = fresh_temp b "wcmp" in
        emit b (Cmp (Ne, Long, cv, cv_tagged, Int 1L));
        close_block b (Br (cv, lbody, ldone));
        start_block b lbody;
        ignore (compile_aexpr b false body);
        if b.term = None then close_block b (Jmp lcond);
        start_block b ldone
      end;
      unit_const
  | For (id, start_a, stop_a, dir, body) ->
      let sv = compile_atom b start_a in
      let ev = compile_atom b stop_a in
      let enter_op, cont_op, step =
        match dir with
        | Asttypes.Upto -> (Cmp.Sle, Cmp.Slt, 2L)
        | Asttypes.Downto -> (Cmp.Sge, Cmp.Sgt, -2L)
      in
      let enter = fresh_temp b "forenter" in
      emit b (Cmp (enter_op, Long, enter, sv, ev));
      let lpre = b.open_label in
      let lbody = fresh_label b "fbody" in
      let lstep = fresh_label b "fstep" in
      let lnext = fresh_label b "fnext" in
      let ldone = fresh_label b "fdone" in
      let iv = fresh_temp b "fori" in
      let next_i = fresh_temp b "forn" in
      close_block b (Br (enter, lbody, ldone));
      start_block b lbody;
      emit b (Phi (Long, iv, [ (lpre, sv); (lnext, next_i) ]));
      let saved = Hashtbl.find_opt b.vars id in
      Hashtbl.replace b.vars id iv;
      ignore (compile_aexpr b false body);
      (match saved with
      | Some v -> Hashtbl.replace b.vars id v
      | None -> Hashtbl.remove b.vars id);
      if b.term = None then close_block b (Jmp lstep);
      start_block b lstep;
      let more = fresh_temp b "formore" in
      emit b (Cmp (cont_op, Long, more, iv, ev));
      close_block b (Br (more, lnext, ldone));
      start_block b lnext;
      emit b (Binop (Add, Long, next_i, iv, Int step));
      close_block b (Jmp lbody);
      start_block b ldone;
      unit_const
  | Retain (id, body) ->
      let v = compile_atom b (Var id) in
      emit b (Call_void { fn = Global "arc_retain_val"; args = [ (Long, v) ] });
      compile_aexpr b tail body
  | Release (id, body) ->
      let v = compile_atom b (Var id) in
      emit b (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] });
      compile_aexpr b tail body
  | ReleaseMut (id, body) ->
      (match Hashtbl.find_opt b.mut_vars id with
      | Some slot ->
          let v = fresh_temp b "mrel" in
          emit b (Load (Loadl, Long, v, slot));
          emit b
            (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] })
      | None -> ());
      compile_aexpr b tail body
  | DropReuse (v_id, tok_id, body) ->
      let v = compile_atom b (Var v_id) in
      let tok = fresh_temp b "rtok" in
      emit b
        (Call (Long, tok, { fn = Global "arc_drop_reuse"; args = [ (Long, v) ] }));
      Hashtbl.replace b.vars tok_id tok;
      let res = compile_aexpr b tail body in
      Hashtbl.remove b.vars tok_id;
      res
  | FreeReuse (tok_id, body) ->
      let tok = Hashtbl.find b.vars tok_id in
      emit b
        (Call_void { fn = Global "arc_free_reuse"; args = [ (Long, tok) ] });
      compile_aexpr b tail body
  | ShadowPush (vars, muts, rtoks, body) ->
      List.iter
        (fun id ->
          let v = compile_atom b (Var id) in
          emit b
            (Call_void { fn = Global "arc_fiber_push"; args = [ (Long, v) ] }))
        vars;
      List.iter
        (fun mid ->
          match Hashtbl.find_opt b.mut_vars mid with
          | Some slot ->
              let v = fresh_temp b "shmut" in
              emit b (Load (Loadl, Long, v, slot));
              emit b
                (Call_void
                   { fn = Global "arc_fiber_push"; args = [ (Long, v) ] })
          | None -> ())
        muts;
      List.iter
        (fun tid ->
          let tok = Hashtbl.find b.vars tid in
          emit b
            (Call_void
               { fn = Global "arc_fiber_push_reuse"; args = [ (Long, tok) ] }))
        rtoks;
      compile_aexpr b tail body
  | ShadowPop (n_vals, n_reuse, body) ->
      if n_vals > 0 then
        emit b
          (Call_void
             { fn = Global "arc_fiber_pop";
               args = [ (Long, Int (Int64.of_int n_vals)) ] });
      if n_reuse > 0 then
        emit b
          (Call_void
             { fn = Global "arc_fiber_pop_reuse";
               args = [ (Long, Int (Int64.of_int n_reuse)) ] });
      compile_aexpr b tail body
  | Unwind -> emit_unwind b
  | Raise a ->
      let v = compile_atom b a in
      emit b (Store (Storel, v, Global "ocamlcc_exn_slot"));
      emit_unwind b
  | CheckExn (on_err, on_ok) ->
      let ex = fresh_temp b "exchk" in
      emit b (Load (Loadl, Long, ex, Global "ocamlcc_exn_slot"));
      let lerr = fresh_label b "exn_err" in
      let lok = fresh_label b "exn_ok" in
      close_block b (Br (ex, lerr, lok));
      start_block b lerr;
      ignore (compile_aexpr b false on_err);
      if b.term = None then ignore (emit_unwind b);
      start_block b lok;
      compile_aexpr b tail on_ok
  | TryWith (body, exn_id, handler) ->
      let lcatch = fresh_label b "catch" in
      let ljoin = fresh_label b (if tail then "ret" else "tryj") in
      let res = fresh_temp b (if tail then "res" else "tryv") in
      let preds = ref [] in
      b.try_stack <- lcatch :: b.try_stack;
      let bv = compile_aexpr b tail body in
      b.try_stack <- List.tl b.try_stack;
      if b.term = None then begin
        preds := (b.open_label, bv) :: !preds;
        close_block b (Jmp ljoin)
      end;
      start_block b lcatch;
      let ex = fresh_temp b "exn" in
      emit b (Load (Loadl, Long, ex, Global "ocamlcc_exn_slot"));
      emit b (Store (Storel, Int 0L, Global "ocamlcc_exn_slot"));
      Hashtbl.replace b.vars exn_id ex;
      let hv = compile_aexpr b tail handler in
      Hashtbl.remove b.vars exn_id;
      if b.term = None then begin
        preds := (b.open_label, hv) :: !preds;
        close_block b (Jmp ljoin)
      end;
      (match !preds with
      | [] -> unit_const
      | _ ->
          start_block b ljoin;
          emit b (Phi (Long, res, List.rev !preds));
          res)

and emit_unwind b : t =
  match b.try_stack with
  | lcatch :: _ ->
      close_block b (Jmp lcatch);
      unit_const
  | [] ->
      if b.in_init then begin
        let ex = fresh_temp b "unex" in
        emit b (Load (Loadl, Long, ex, Global "ocamlcc_exn_slot"));
        emit b
          (Call_void { fn = Global "arc_release_val"; args = [ (Long, ex) ] });
        emit b (Store (Storel, Int 0L, Global "ocamlcc_exn_slot"));
        emit b (Call_void { fn = Global "pal_abort"; args = [] });
        close_block b Hlt;
        unit_const
      end
      else begin
        close_block b (Ret (Some unit_const));
        unit_const
      end

and compile_if b tail (cond : Anf.atom) th el =
  let v = compile_atom b cond in
  let cv = fresh_temp b "cond" in
  emit b (Cmp (Ne, Long, cv, v, Int 1L));
  let lthen = fresh_label b "then" in
  let lelse = fresh_label b "else" in
  close_block b (Br (cv, lthen, lelse));
  let lepi = fresh_label b (if tail then "ret" else "join") in
  let res = fresh_temp b (if tail then "res" else "if") in
  let preds = ref [] in
  start_block b lthen;
  let tv = compile_aexpr b tail th in
  if b.term = None then begin
    preds := (b.open_label, tv) :: !preds;
    close_block b (Jmp lepi)
  end;
  start_block b lelse;
  let ev = compile_aexpr b tail el in
  if b.term = None then begin
    preds := (b.open_label, ev) :: !preds;
    close_block b (Jmp lepi)
  end;
  (match !preds with
  | [] -> ()
  | _ ->
      start_block b lepi;
      emit b (Phi (Long, res, List.rev !preds)));
  res

and compile_switch b tail (scrut : Anf.atom) (sw : Anf.switch_cases) =
  let sv = compile_atom b scrut in
  let lfail = fresh_label b "swfail" in
  let lepi = fresh_label b (if tail then "swret" else "swjoin") in
  let res = fresh_temp b "sw" in
  let preds = ref [] in
  let emit_arm arm =
    let v = compile_aexpr b tail arm in
    if b.term = None then begin
      preds := (b.open_label, v) :: !preds;
      close_block b (Jmp lepi)
    end
  in
  let rec emit_chain scrut_val cases =
    match cases with
    | [] -> close_block b (Jmp lfail)
    | [ (_, arm) ] when sw.fail = None ->
        let larm = fresh_label b "swarm" in
        close_block b (Jmp larm);
        start_block b larm;
        emit_arm arm
    | (k, arm) :: rest ->
        let c = fresh_temp b "swcmp" in
        emit b (Cmp (Eq, Long, c, scrut_val, Int k));
        let larm = fresh_label b "swarm" in
        let lnext = fresh_label b "swnext" in
        close_block b (Br (c, larm, lnext));
        start_block b larm;
        emit_arm arm;
        start_block b lnext;
        emit_chain scrut_val rest
  in
  let const_cases = List.map (fun (k, arm) -> (tag_int k, arm)) sw.consts in
  let block_cases =
    List.map (fun (t, arm) -> (Int64.of_int t, arm)) sw.blocks
  in
  let emit_block_switch () =
    let taddr = fresh_temp b "taddr" in
    emit b (Binop (Sub, Long, taddr, sv, Int 12L));
    let tag = fresh_temp b "tag" in
    emit b (Load (Loaduh, Long, tag, taddr));
    emit_chain tag block_cases
  in
  (match (const_cases, block_cases) with
  | _ :: _, _ :: _ ->
      let isint = fresh_temp b "isint" in
      emit b (Binop (And, Long, isint, sv, Int 1L));
      let lconsts = fresh_label b "swconsts" in
      let lblocks = fresh_label b "swblocks" in
      close_block b (Br (isint, lconsts, lblocks));
      start_block b lconsts;
      emit_chain sv const_cases;
      start_block b lblocks;
      emit_block_switch ()
  | _ :: _, [] -> emit_chain sv const_cases
  | [], _ :: _ -> emit_block_switch ()
  | [], [] -> close_block b (Jmp lfail));
  (match sw.fail with
  | Some fail ->
      start_block b lfail;
      emit_arm fail
  | None -> ());
  match !preds with
  | [] -> unit_const
  | _ ->
      start_block b lepi;
      emit b (Phi (Long, res, List.rev !preds));
      res

and compile_stringswitch b tail (scrut : Anf.atom) cases fail =
  let sv = compile_atom b scrut in
  let slen = string_len_raw b sv in
  let lfail = fresh_label b "ssfail" in
  let lepi = fresh_label b (if tail then "ssret" else "ssjoin") in
  let res = fresh_temp b "ss" in
  let preds = ref [] in
  let emit_arm arm =
    let v = compile_aexpr b tail arm in
    if b.term = None then begin
      preds := (b.open_label, v) :: !preds;
      close_block b (Jmp lepi)
    end
  in
  let rec go = function
    | [] -> close_block b (Jmp lfail)
    | [ (lit, arm) ] when fail = None ->
        ignore lit;
        let larm = fresh_label b "ssarm" in
        close_block b (Jmp larm);
        start_block b larm;
        emit_arm arm
    | (lit, arm) :: rest ->
        let lit_len = String.length lit in
        let larm = fresh_label b "ssarm" in
        let lnext = fresh_label b "ssnext" in
        let eq_len = fresh_temp b "sslen" in
        emit b (Cmp (Eq, Long, eq_len, slen, Int (Int64.of_int lit_len)));
        if lit_len = 0 then begin
          close_block b (Br (eq_len, larm, lnext));
          start_block b larm;
          emit_arm arm;
          start_block b lnext;
          go rest
        end
        else begin
          let lchk = fresh_label b "sschk" in
          close_block b (Br (eq_len, lchk, lnext));
          start_block b lchk;
          let sym = string_data b lit in
          let lit_ptr = fresh_temp b "sslit" in
          emit b (Binop (Add, Long, lit_ptr, Global sym, Int 16L));
          let lpre = b.open_label in
          let lloop = fresh_label b "ssloop" in
          let lstep = fresh_label b "ssstep" in
          let lcmp = fresh_label b "sscmp" in
          let idx = fresh_temp b "ssi" in
          let next_idx = fresh_temp b "ssn" in
          close_block b (Jmp lloop);
          start_block b lloop;
          emit b (Phi (Long, idx, [ (lpre, Int 0L); (lstep, next_idx) ]));
          let done_c = fresh_temp b "ssdone" in
          emit b (Cmp (Eq, Long, done_c, idx, Int (Int64.of_int lit_len)));
          close_block b (Br (done_c, larm, lcmp));
          start_block b lcmp;
          let pa = fresh_temp b "sspa" in
          let pb = fresh_temp b "sspb" in
          let ba = fresh_temp b "ssba" in
          let bb = fresh_temp b "ssbb" in
          let eqb = fresh_temp b "sseqb" in
          emit b (Binop (Add, Long, pa, sv, idx));
          emit b (Binop (Add, Long, pb, lit_ptr, idx));
          emit b (Load (Loadub, Long, ba, pa));
          emit b (Load (Loadub, Long, bb, pb));
          emit b (Cmp (Eq, Long, eqb, ba, bb));
          close_block b (Br (eqb, lstep, lnext));
          start_block b lstep;
          emit b (Binop (Add, Long, next_idx, idx, Int 1L));
          close_block b (Jmp lloop);
          start_block b larm;
          emit_arm arm;
          start_block b lnext;
          go rest
        end
  in
  go cases;
  (match fail with
  | Some f ->
      start_block b lfail;
      emit_arm f
  | None -> ());
  match !preds with
  | [] -> unit_const
  | _ ->
      start_block b lepi;
      emit b (Phi (Long, res, List.rev !preds));
      res

and staticcatch b tail id binder_idents body handler =
  let h =
    { hlabel = fresh_label b "catch";
      hbinders = binder_idents;
      hpreds = [] }
  in
  Hashtbl.replace b.handlers id h;
  let v = compile_aexpr b tail body in
  Hashtbl.remove b.handlers id;
  let ljoin = fresh_label b "catchjoin" in
  let res = fresh_temp b "catch" in
  let preds = ref [] in
  let merge value =
    preds := (b.open_label, value) :: !preds;
    close_block b (Jmp ljoin)
  in
  if b.term = None then merge v;
  if h.hpreds <> [] then begin
    let sites = List.rev h.hpreds in
    start_block b h.hlabel;
    List.iteri
      (fun idx bid ->
        let bt = fresh_temp b "henv" in
        let args =
          List.map
            (fun (lbl, vs) ->
              match List.nth_opt vs idx with
              | Some v -> (lbl, v)
              | None -> (lbl, unit_const))
            sites
        in
        emit b (Phi (Long, bt, args));
        Hashtbl.replace b.vars bid bt)
      h.hbinders;
    let hv = compile_aexpr b tail handler in
    List.iter (fun bid -> Hashtbl.remove b.vars bid) h.hbinders;
    if b.term = None then merge hv
  end;
  match !preds with
  | [] -> unit_const
  | _ ->
      start_block b ljoin;
      emit b (Phi (Long, res, List.rev !preds));
      res

(* ------------------------------------------------------------------ *)
(* Function definitions & closures                                     *)
(* ------------------------------------------------------------------ *)

and alloc_global_name b id =
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

and closure_value_of b id : t =
  let data_sym =
    match Hashtbl.find_opt b.clos_wrappers id with
    | Some sym -> sym
    | None ->
        let info = Hashtbl.find b.funs id in
        let wrapper_name = alloc_global_name b id in
        let clos_p = fresh_name b "clos" in
        let param_names = List.init info.arity (fun _ -> fresh_name b "carg") in
        let param_vals = List.map (fun n -> (Long, Temp n)) param_names in
        let call_res = fresh_name b "wres" in
        let call_inst =
          match info.tag with
          | Some tag ->
              let padded = pad_to info.group_arity (List.map snd param_vals) in
              Call
                ( Long,
                  Temp call_res,
                  { fn = Global info.global;
                    args = (Long, Int tag) :: List.map (fun v -> (Long, v)) padded } )
          | None ->
              Call (Long, Temp call_res, { fn = Global info.global; args = param_vals })
        in
        let func =
          { name = wrapper_name;
            export = false;
            retty = Some Long;
            params = (Long, clos_p) :: List.map (fun n -> (Long, n)) param_names;
            blocks =
              [ { label = "start";
                  insts = [ call_inst ];
                  term = Ret (Some (Temp call_res)) } ] }
        in
        b.funcs <- func :: b.funcs;
        let sym = Printf.sprintf "clos.%d" b.data_counter in
        b.data_counter <- b.data_counter + 1;
        let items =
          [ D_word (-1l);
            D_half arc_tag_closure;
            D_half 0;
            D_word 16l;
            D_word 0l;
            D_ref (wrapper_name, 0L);
            D_long (Int64.of_int info.arity) ]
        in
        b.datas <- { name = sym; export = false; align = Some 16; items } :: b.datas;
        Hashtbl.replace b.clos_wrappers id sym;
        sym
  in
  let dst = fresh_temp b "pclos" in
  emit b (Binop (Add, Long, dst, Global data_sym, Int 16L));
  dst

and alloc_closure b code_sym arity (env : Ident.t list) : t =
  let n_env = List.length env in
  let byte_size = 16 + (8 * n_env) in
  let obj = fresh_temp b "clos" in
  emit b
    (Call
       ( Long,
         obj,
         { fn = Global "arc_alloc";
           args =
             [ (Long, Int (Int64.of_int arc_tag_closure));
               (Long, Int (Int64.of_int n_env));
               (Long, Int (Int64.of_int byte_size)) ] } ));
  emit b (Store (Storel, Global code_sym, obj));
  let arity_addr = ptr_offset b obj 8 "arityp" in
  emit b (Store (Storel, Int (Int64.of_int arity), arity_addr));
  List.iteri
    (fun i ev ->
      let v =
        match Hashtbl.find_opt b.vars ev with
        | Some v -> v
        | None -> (
            match Hashtbl.find_opt b.funs ev with
            | Some info when not info.has_closure -> closure_value_of b ev
            | _ ->
                failwith
                  (Printf.sprintf "codegen: unbound captured variable %s"
                     (sanitize (Ident.name ev))))
      in
      let addr = ptr_offset b obj (16 + (8 * i)) "envp" in
      emit b (Store (Storel, v, addr)))
    env;
  obj

and compile_letrec b tail (bindings : Anf.rec_binding list) body =
  match bindings with
  | [] -> compile_aexpr b tail body
  | rb :: _
    when
      match Hashtbl.find_opt b.funs rb.id with
      | Some info -> not info.has_closure
      | None -> false ->
      List.iter
        (fun (rb : Anf.rec_binding) ->
          let info = Hashtbl.find b.funs rb.id in
          define_pure_function b rb.id rb.def info)
        bindings;
      compile_aexpr b tail body
  | [ rb ] ->
      let env = free_vars_of b ~self_id:rb.id rb.def in
      let g = alloc_global_name b rb.id in
      let has_closure = env <> [] in
      Hashtbl.replace b.funs rb.id
        { global = g;
          arity = List.length rb.def.params;
          tag = None;
          group_arity = List.length rb.def.params;
          group_name = None;
          has_closure };
      ignore (compile_function b rb.id rb.def ~has_closure ~env);
      if has_closure then begin
        let clos = alloc_closure b g (List.length rb.def.params) env in
        Hashtbl.replace b.vars rb.id clos;
        let res = compile_aexpr b tail body in
        Hashtbl.remove b.vars rb.id;
        Hashtbl.remove b.funs rb.id;
        res
      end
      else begin
        let res = compile_aexpr b tail body in
        Hashtbl.remove b.funs rb.id;
        res
      end
  | _ ->
      let infos =
        List.map
          (fun (rb : Anf.rec_binding) ->
            let g = alloc_global_name b rb.id in
            let arity = List.length rb.def.params in
            Hashtbl.replace b.funs rb.id
              { global = g;
                arity;
                tag = None;
                group_arity = arity;
                group_name = None;
                has_closure = true };
            let env = free_vars_of b ~self_id:rb.id rb.def in
            let obj = fresh_temp b "clos" in
            let n_env = List.length env in
            emit b
              (Call
                 ( Long,
                   obj,
                   { fn = Global "arc_alloc";
                     args =
                       [ (Long, Int (Int64.of_int arc_tag_closure));
                         (Long, Int (Int64.of_int n_env));
                         (Long, Int (Int64.of_int (16 + (8 * n_env)))) ] } ));
            emit b (Store (Storel, Global g, obj));
            let arity_addr = ptr_offset b obj 8 "arityp" in
            emit b (Store (Storel, Int (Int64.of_int arity), arity_addr));
            Hashtbl.replace b.vars rb.id obj;
            (rb, g, env, obj))
          bindings
      in
      let cyclic_ids =
        let ids =
          List.map (fun ((rb : Anf.rec_binding), _, _, _) -> rb.id) infos
        in
        let edges_of id =
          match
            List.find_opt
              (fun ((rb : Anf.rec_binding), _, _, _) -> Ident.same rb.id id)
              infos
          with
          | Some (_, _, env, _) ->
              List.filter (fun ev -> List.exists (Ident.same ev) ids) env
          | None -> []
        in
        let can_reach src dst =
          let rec dfs visited = function
            | [] -> false
            | x :: rest ->
                if Ident.same x dst then true
                else if List.exists (Ident.same x) visited then dfs visited rest
                else dfs (x :: visited) (edges_of x @ rest)
          in
          dfs [] (edges_of src)
        in
        List.filter (fun id -> can_reach id id) ids
      in
      if cyclic_ids <> [] then
        Printf.eprintf
          "ocamlcc: warning: cyclic non-pure mutual let rec closures (%s) form an \
           ARC reference cycle; lift to top-level or call arc_collect ()\n%!"
          (String.concat ", " (List.map Ident.name cyclic_ids));
      List.iter
        (fun (_, _, env, obj) ->
          List.iteri
            (fun i ev ->
              let v = Hashtbl.find b.vars ev in
              if
                List.exists (fun (rb : Anf.rec_binding) -> Ident.same rb.id ev) bindings
              then
                emit b
                  (Call_void
                     { fn = Global "arc_retain_val"; args = [ (Long, v) ] });
              let addr = ptr_offset b obj (16 + (8 * i)) "envp" in
              emit b (Store (Storel, v, addr)))
            env)
        infos;
      List.iter
        (fun ((rb : Anf.rec_binding), _, env, _) ->
          ignore (compile_function b rb.id rb.def ~has_closure:true ~env))
        infos;
      let res = compile_aexpr b tail body in
      List.iter
        (fun ((rb : Anf.rec_binding), _, _, _) ->
          Hashtbl.remove b.vars rb.id;
          Hashtbl.remove b.funs rb.id)
        infos;
      res

and insert_header_phis b header_label binder_names start_values =
  if binder_names <> [] then begin
    let sites = List.rev b.tail_sites in
    let phis =
      List.mapi
        (fun i name ->
          let args =
            ("start", List.nth start_values i)
            :: List.filter_map
                 (fun (lbl, vs) ->
                   match List.nth_opt vs i with
                   | Some v -> Some (lbl, v)
                   | None -> None)
                 sites
          in
          Phi (Long, Temp name, args))
        binder_names
    in
    b.blocks <-
      List.map
        (fun blk ->
          if blk.label = header_label then { blk with insts = phis @ blk.insts }
          else blk)
        b.blocks
  end

and define_pure_function b id (lf : Anf.lfunction) (info : fn_info) : unit =
  match info.group_name with
  | Some gname ->
      if not (Hashtbl.mem b.compiled_groups gname) then begin
        Hashtbl.replace b.compiled_groups gname ();
        compile_group b gname (Hashtbl.find b.groups gname)
      end
  | None -> ignore (compile_function b id lf ~has_closure:false ~env:[])

and compile_function b id (lf : Anf.lfunction) ~has_closure
    ~(env : Ident.t list) : string =
  let g = (Hashtbl.find b.funs id).global in
  let saved_self = b.self in
  let saved_group = b.cur_group in
  let saved_entry = b.entry_label in
  let saved_insts = b.insts in
  let saved_term = b.term in
  let saved_blocks = b.blocks in
  let saved_open_label = b.open_label in
  let saved_tail_sites = b.tail_sites in
  let saved_fn_params = b.fn_params in
  let saved_handlers = b.handlers in
  let saved_try_stack = b.try_stack in
  let saved_in_init = b.in_init in
  let param_binders =
    List.map
      (fun (pid, _) -> (pid, fresh_name b (sanitize (Ident.name pid))))
      lf.params
  in
  let shadowed_ids =
    (if has_closure then [ id ] else [])
    @ List.map fst param_binders
    @ env
  in
  let saved_vars =
    List.map (fun vid -> (vid, Hashtbl.find_opt b.vars vid)) shadowed_ids
  in
  let clos_param = fresh_name b "clos" in
  let loop_binders = List.map (fun _ -> fresh_name b "loop") lf.params in
  b.self <- Some id;
  b.cur_group <- None;
  b.entry_label <- "loop";
  b.open_label <- "start";
  b.insts <- [];
  b.term <- None;
  b.blocks <- [];
  b.tail_sites <- [];
  b.handlers <- Hashtbl.create 8;
  b.try_stack <- [];
  b.in_init <- false;
  let ps = List.map (fun (_, n) -> (Long, n)) param_binders in
  b.fn_params <- if has_closure then (Long, clos_param) :: ps else ps;
  if has_closure then begin
    Hashtbl.replace b.vars id (Temp clos_param);
    List.iteri
      (fun i ev ->
        let addr = ptr_offset b (Temp clos_param) (16 + (8 * i)) "envp" in
        let dst = fresh_temp b "env" in
        emit b (Load (Loadl, Long, dst, addr));
        Hashtbl.replace b.vars ev dst)
      env
  end;
  close_block b (Jmp "loop");
  start_block b "loop";
  List.iter2
    (fun (pid, _) loop_name -> Hashtbl.replace b.vars pid (Temp loop_name))
    param_binders loop_binders;
  let result = compile_aexpr b true lf.body in
  close_ret b (Some result);
  insert_header_phis b "loop" loop_binders
    (List.map (fun (_, formal) -> Temp formal) param_binders);
  let func =
    { name = g;
      export = not has_closure;
      retty = Some Long;
      params = b.fn_params;
      blocks = List.rev b.blocks }
  in
  b.funcs <- func :: b.funcs;
  b.self <- saved_self;
  b.cur_group <- saved_group;
  b.entry_label <- saved_entry;
  b.insts <- saved_insts;
  b.term <- saved_term;
  b.blocks <- saved_blocks;
  b.open_label <- saved_open_label;
  b.tail_sites <- saved_tail_sites;
  b.fn_params <- saved_fn_params;
  b.handlers <- saved_handlers;
  b.try_stack <- saved_try_stack;
  b.in_init <- saved_in_init;
  List.iter
    (fun (vid, prev) ->
      match prev with
      | Some v -> Hashtbl.replace b.vars vid v
      | None -> Hashtbl.remove b.vars vid)
    saved_vars;
  g

and compile_group b gname (members : (Ident.t * Anf.lfunction) list) : unit =
  let max_arity =
    List.fold_left
      (fun acc ((_, lf) : Ident.t * Anf.lfunction) ->
        max acc (List.length lf.params))
      0 members
  in
  let formal_sel = fresh_name b "grpfn" in
  let formal_slots = List.init max_arity (fun _ -> fresh_name b "grpslot") in
  let phi_sel = fresh_name b "dspsel" in
  let phi_slots = List.init max_arity (fun _ -> fresh_name b "dspslot") in
  let saved_self = b.self in
  let saved_group = b.cur_group in
  let saved_entry = b.entry_label in
  let saved_insts = b.insts in
  let saved_term = b.term in
  let saved_blocks = b.blocks in
  let saved_open_label = b.open_label in
  let saved_tail_sites = b.tail_sites in
  let saved_fn_params = b.fn_params in
  let saved_handlers = b.handlers in
  let saved_try_stack = b.try_stack in
  let saved_in_init = b.in_init in
  b.self <- None;
  b.cur_group <- Some gname;
  b.entry_label <- "dispatch";
  b.open_label <- "start";
  b.insts <- [];
  b.term <- None;
  b.blocks <- [];
  b.tail_sites <- [];
  b.handlers <- Hashtbl.create 8;
  b.try_stack <- [];
  b.in_init <- false;
  b.fn_params <-
    (Long, formal_sel) :: List.map (fun n -> (Long, n)) formal_slots;
  close_block b (Jmp "dispatch");
  start_block b "dispatch";
  let member_entries =
    List.mapi
      (fun i (id, _) ->
        (Int64.of_int (i + 1),
         Printf.sprintf "%s_entry" (sanitize (Ident.name id))))
      members
  in
  let rec dispatch_chain = function
    | [] -> close_block b Hlt
    | [ (_, entry) ] -> close_block b (Jmp entry)
    | (tag, entry) :: rest ->
        let c = fresh_temp b "dspsel" in
        emit b (Cmp (Eq, Long, c, Temp phi_sel, Int tag));
        let lnext = fresh_label b "dspnext" in
        close_block b (Br (c, entry, lnext));
        start_block b lnext;
        dispatch_chain rest
  in
  dispatch_chain member_entries;
  let ret_preds = ref [] in
  List.iter2
    (fun (_, entry) ((_, lf) : Ident.t * Anf.lfunction) ->
      start_block b entry;
      List.iteri
        (fun j (pid, _) ->
          Hashtbl.replace b.vars pid (Temp (List.nth phi_slots j)))
        lf.params;
      let result = compile_aexpr b true lf.body in
      if b.term = None then begin
        ret_preds := (b.open_label, result) :: !ret_preds;
        close_block b (Jmp "ret")
      end;
      List.iter (fun (pid, _) -> Hashtbl.remove b.vars pid) lf.params)
    member_entries members;
  (match !ret_preds with
  | [] -> start_block b "ret"; close_block b Hlt
  | _ ->
      start_block b "ret";
      let res = fresh_temp b "grpres" in
      emit b (Phi (Long, res, List.rev !ret_preds));
      close_block b (Ret (Some res)));
  insert_header_phis b "dispatch" (phi_sel :: phi_slots)
    (Temp formal_sel :: List.map (fun n -> Temp n) formal_slots);
  let func =
    { name = gname;
      export = true;
      retty = Some Long;
      params = b.fn_params;
      blocks = List.rev b.blocks }
  in
  b.funcs <- func :: b.funcs;
  b.self <- saved_self;
  b.cur_group <- saved_group;
  b.entry_label <- saved_entry;
  b.insts <- saved_insts;
  b.term <- saved_term;
  b.blocks <- saved_blocks;
  b.open_label <- saved_open_label;
  b.tail_sites <- saved_tail_sites;
  b.fn_params <- saved_fn_params;
  b.handlers <- saved_handlers;
  b.try_stack <- saved_try_stack;
  b.in_init <- saved_in_init

(* ------------------------------------------------------------------ *)
(* Analysis: pure toplevel functions & mutual tail-call SCCs           *)
(* ------------------------------------------------------------------ *)

let collect_pure_defs (e : Anf.aexpr) : (Ident.t * Anf.lfunction) list =
  let is_pure known (lf : Anf.lfunction) =
    let params =
      List.fold_left (fun s (p, _) -> Ident.Set.add p s) Ident.Set.empty lf.params
    in
    let free = Anf.free_vars lf.body in
    Ident.Set.for_all
      (fun v -> Ident.Set.mem v params || Ident.Set.mem v known)
      free
  in
  let rec go known acc (e : Anf.aexpr) =
    match e with
    | Let (id, Fun lf, body) ->
        if is_pure known lf then
          go (Ident.Set.add id known) ((id, lf) :: acc) body
        else go known acc body
    | Let (_, _, body) | MutLet (_, _, body) | LetJoin (_, _, body)
    | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
    | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        go known acc body
    | LetRec (bindings, body) ->
        let known_grp =
          List.fold_left
            (fun s (rb : Anf.rec_binding) -> Ident.Set.add rb.id s)
            known bindings
        in
        if List.for_all (fun (rb : Anf.rec_binding) -> is_pure known_grp rb.def) bindings
        then
          go known_grp
            (List.fold_left
               (fun acc (rb : Anf.rec_binding) -> (rb.id, rb.def) :: acc)
               acc bindings)
            body
        else go known acc body
    | _ -> acc
  in
  List.rev (go Ident.Set.empty [] e)

let rec tail_callees (e : Anf.aexpr) : Ident.Set.t =
  match e with
  | Let (id, App (Var callee, _), Halt (Var v)) when Ident.same id v ->
      Ident.Set.singleton callee
  | Let (_, _, body) | MutLet (_, _, body) | LetJoin (_, _, body)
  | LetRec (_, body) | Retain (_, body) | Release (_, body)
  | ReleaseMut (_, body) | DropReuse (_, _, body) | FreeReuse (_, body)
  | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
      tail_callees body
  | If (_, th, el) -> Ident.Set.union (tail_callees th) (tail_callees el)
  | Switch (_, sw) ->
      let acc =
        List.fold_left
          (fun acc (_, arm) -> Ident.Set.union acc (tail_callees arm))
          Ident.Set.empty sw.consts
      in
      let acc =
        List.fold_left
          (fun acc (_, arm) -> Ident.Set.union acc (tail_callees arm))
          acc sw.blocks
      in
      (match sw.fail with
      | Some f -> Ident.Set.union acc (tail_callees f)
      | None -> acc)
  | StringSwitch (_, cases, fail) ->
      let acc =
        List.fold_left
          (fun acc (_, arm) -> Ident.Set.union acc (tail_callees arm))
          Ident.Set.empty cases
      in
      (match fail with
      | Some f -> Ident.Set.union acc (tail_callees f)
      | None -> acc)
  | StaticCatch (body, _, _, handler)
  | TryWith (body, _, handler) ->
      Ident.Set.union (tail_callees body) (tail_callees handler)
  | CheckExn (_, on_ok) -> tail_callees on_ok
  | Halt _ | StaticRaise _ | While _ | For _ | Raise _ | Unwind ->
      Ident.Set.empty

let strongly_connected_components nodes edges =
  let index = Hashtbl.create 16 in
  let low = Hashtbl.create 16 in
  let on_stack = Hashtbl.create 16 in
  let stack = ref [] in
  let counter = ref 0 in
  let comps = ref [] in
  let rec strongconnect v =
    Hashtbl.replace index v !counter;
    Hashtbl.replace low v !counter;
    Hashtbl.replace on_stack v true;
    incr counter;
    stack := v :: !stack;
    Ident.Set.iter
      (fun w ->
        if not (Hashtbl.mem index w) then begin
          strongconnect w;
          Hashtbl.replace low v
            (min (Hashtbl.find low v) (Hashtbl.find low w))
        end
        else if Hashtbl.find on_stack w then
          Hashtbl.replace low v
            (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (edges v);
    if Hashtbl.find low v = Hashtbl.find index v then begin
      let rec pop comp =
        match !stack with
        | w :: rest ->
            stack := rest;
            Hashtbl.replace on_stack w false;
            let comp = w :: comp in
            if Ident.same w v then comps := comp :: !comps else pop comp
        | [] -> assert false
      in
      pop []
    end
  in
  List.iter
    (fun v -> if not (Hashtbl.mem index v) then strongconnect v)
    nodes;
  List.rev !comps

(* ------------------------------------------------------------------ *)
(* Program compilation                                                 *)
(* ------------------------------------------------------------------ *)

let collect_globals self_sym (e : Anf.aexpr) : string list =
  let seen = Hashtbl.create 8 in
  let deps = ref [] in
  let add name =
    let s = sanitize name in
    if s <> self_sym && not (Hashtbl.mem seen s) then begin
      Hashtbl.add seen s ();
      deps := s :: !deps
    end
  in
  let rec scan_aexpr (e : Anf.aexpr) =
    match e with
    | Halt _ | StaticRaise _ | Raise _ | Unwind -> ()
    | Let (_, ce, body) | MutLet (_, ce, body) ->
        scan_cexpr ce;
        scan_aexpr body
    | LetJoin (_, rhs, body)
    | StaticCatch (rhs, _, _, body)
    | While (rhs, body) | CheckExn (rhs, body) | TryWith (rhs, _, body) ->
        scan_aexpr rhs;
        scan_aexpr body
    | LetRec (bindings, body) ->
        List.iter (fun (rb : Anf.rec_binding) -> scan_aexpr rb.def.body) bindings;
        scan_aexpr body
    | If (_, th, el) ->
        scan_aexpr th;
        scan_aexpr el
    | Switch (_, sw) ->
        List.iter (fun (_, arm) -> scan_aexpr arm) sw.consts;
        List.iter (fun (_, arm) -> scan_aexpr arm) sw.blocks;
        Option.iter scan_aexpr sw.fail
    | StringSwitch (_, cases, fail) ->
        List.iter (fun (_, arm) -> scan_aexpr arm) cases;
        Option.iter scan_aexpr fail
    | For (_, _, _, _, body)
    | Retain (_, body)
    | Release (_, body)
    | ReleaseMut (_, body)
    | DropReuse (_, _, body)
    | FreeReuse (_, body)
    | ShadowPush (_, _, _, body)
    | ShadowPop (_, _, body) ->
        scan_aexpr body
  and scan_cexpr (ce : Anf.cexpr) =
    match ce with
    | GetGlobal name -> add name
    | Fun lf -> scan_aexpr lf.body
    | _ -> ()
  in
  scan_aexpr e;
  List.rev !deps

let compile_program ?(emit_entry = true) (program : Anf.program) : Qbe_il.module_ =
  let mod_sym = sanitize (Ident.name program.Anf.module_ident) in
  let b = builder mod_sym in
  let defs = collect_pure_defs program.code in
  List.iter
    (fun ((id, lf) : Ident.t * Anf.lfunction) ->
      Hashtbl.replace b.funs id
        { global = alloc_global_name b id;
          arity = List.length lf.params;
          tag = None;
          group_arity = List.length lf.params;
          group_name = None;
          has_closure = false })
    defs;
  let def_idents = List.map fst defs in
  let callee_edges (id : Ident.t) : Ident.Set.t =
    match List.assoc_opt id defs with
    | None -> Ident.Set.empty
    | Some lf -> tail_callees lf.body
    |> Ident.Set.filter (fun callee ->
           not (Ident.same callee id)
           && List.exists (fun (id', _) -> Ident.same id' callee) defs)
  in
  let sccs = strongly_connected_components def_idents callee_edges in
  List.iter
    (fun comp ->
      if List.length comp >= 2 then begin
        let gname =
          Printf.sprintf "ocamlcc_%s_group%d" b.prefix b.group_counter
        in
        b.group_counter <- b.group_counter + 1;
        let members =
          List.map
            (fun id ->
              match List.assoc_opt id defs with
              | Some lf -> (id, lf)
              | None -> assert false)
            comp
        in
        Hashtbl.replace b.groups gname members;
        let group_arity =
          List.fold_left
            (fun acc ((_, lf) : Ident.t * Anf.lfunction) ->
              max acc (List.length lf.params))
            0 members
        in
        List.iteri
          (fun i (id, _) ->
            let info = Hashtbl.find b.funs id in
            Hashtbl.replace b.funs id
              { info with
                global = gname;
                tag = Some (Int64.of_int (i + 1));
                group_arity;
                group_name = Some gname })
          members
      end)
    sccs;
  let global_sym = "ocamlcc_global_" ^ mod_sym in
  let init_sym = "ocamlcc_init_" ^ mod_sym in
  let deps = collect_globals mod_sym program.code in
  b.datas <-
    { name = global_sym;
      export = true;
      align = Some 8;
      items = [ D_long 0L ] }
    :: b.datas;
  start_block b "start";
  let cur = fresh_temp b "gcur" in
  emit b (Load (Loadl, Long, cur, Global global_sym));
  let ldone = fresh_label b "already_init" in
  let linit = fresh_label b "do_init" in
  close_block b (Br (cur, ldone, linit));
  start_block b ldone;
  close_ret b None;
  start_block b linit;
  emit b (Store (Storel, Int 1L, Global global_sym));
  List.iter
    (fun dep ->
      emit b
        (Call_void { fn = Global ("ocamlcc_init_" ^ dep); args = [] }))
    deps;
  let mod_val = compile_aexpr b false program.code in
  if b.term = None then begin
    emit b (Store (Storel, mod_val, Global global_sym));
    close_ret b None
  end;
  let init_func =
    { name = init_sym;
      export = true;
      retty = None;
      params = [];
      blocks = List.rev b.blocks }
  in
  let funcs =
    if emit_entry then
      let entry_func =
        { name = "ocamlcc_module_init";
          export = true;
          retty = None;
          params = [];
          blocks =
            [ { label = "start";
                insts = [ Call_void { fn = Global init_sym; args = [] } ];
                term = Ret None } ] }
      in
      List.rev (entry_func :: init_func :: b.funcs)
    else List.rev (init_func :: b.funcs)
  in
  { funcs; datas = List.rev b.datas }

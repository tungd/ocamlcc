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
  mutable hpreds : (string * t list) list; (* reversed *)
}

(* Per-function emission state, swapped atomically by [with_fn_state] when
   lowering nested functions or trampoline groups. *)
type fn_state = {
  mutable open_label : string;
  mutable insts : inst list;   (* reversed *)
  mutable start_allocs : inst list; (* reversed, hoisted to @start *)
  mutable shadow_batch : (Qbe_il.t * int) option;
  mutable term : term option;
  mutable blocks : block list; (* reversed, closed blocks *)
  handlers : (int, handler) Hashtbl.t;
  known_heap : (string, unit) Hashtbl.t;
  mutable known_heap_slots : Ident.Set.t;
  untagged_indices : (Ident.t, Qbe_il.t) Hashtbl.t;
  entry_label : string;
  self : Ident.t option;
  cur_group : string option;
  mutable tail_sites : (string * t list) list;
  mutable poll_tick : Qbe_il.t option;
  mutable try_stack : string list;
  mutable compact_arc : bool;
  in_init : bool;
}

type t = {
  prefix : string;
  inline_single_thread_rc : bool;
  mutable temp_counter : int;
  mutable label_counter : int;
  mutable data_counter : int;
  vars : (Ident.t, Qbe_il.t) Hashtbl.t;
  mut_vars : (Ident.t, Qbe_il.t) Hashtbl.t;
  funs : (Ident.t, fn_info) Hashtbl.t;
  emitted_funs : (Ident.t, string * bool * int) Hashtbl.t;
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
    shadow_batch = None;
    term = None;
    blocks = [];
    handlers = Hashtbl.create 8;
    known_heap = Hashtbl.create 16;
    known_heap_slots = Ident.Set.empty;
    untagged_indices = Hashtbl.create 4;
    entry_label;
    self;
    cur_group;
    tail_sites = [];
    poll_tick = None;
    try_stack = [];
    compact_arc = false;
    in_init }

let create ?(inline_single_thread_rc = false) prefix =
  { prefix;
    inline_single_thread_rc;
    temp_counter = 0;
    label_counter = 0;
    data_counter = 0;
    vars = Hashtbl.create 16;
    mut_vars = Hashtbl.create 8;
    funs = Hashtbl.create 16;
    emitted_funs = Hashtbl.create 16;
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

let bind_value b id value = Hashtbl.replace b.vars id value
let bound_value b id = Hashtbl.find b.vars id
let bound_value_opt b id = Hashtbl.find_opt b.vars id
let forget_value b id = Hashtbl.remove b.vars id

let bind_slot b id slot = Hashtbl.replace b.mut_vars id slot
let mutable_slot b id = Hashtbl.find b.mut_vars id
let mutable_slot_opt b id = Hashtbl.find_opt b.mut_vars id
let forget_slot b id = Hashtbl.remove b.mut_vars id

let function_info b id = Hashtbl.find b.funs id
let function_info_opt b id = Hashtbl.find_opt b.funs id
let declare_function b id info = Hashtbl.replace b.funs id info
let forget_function b id = Hashtbl.remove b.funs id
let record_function b id info = Hashtbl.replace b.emitted_funs id info
let emitted_function b id = Hashtbl.find_opt b.emitted_funs id

let closure_wrapper b id make =
  match Hashtbl.find_opt b.clos_wrappers id with
  | Some symbol -> symbol
  | None ->
      let symbol = make () in
      Hashtbl.replace b.clos_wrappers id symbol;
      symbol

let fresh_group_name b =
  let name = Printf.sprintf "ocamlcc_%s_group%d" b.prefix b.group_counter in
  b.group_counter <- b.group_counter + 1;
  name

let declare_group b name members = Hashtbl.replace b.groups name members
let with_uncompiled_group b name compile =
  if not (Hashtbl.mem b.compiled_groups name) then begin
    Hashtbl.replace b.compiled_groups name ();
    compile (Hashtbl.find b.groups name)
  end

let next_data_name b base =
  let name = Printf.sprintf "%s.%d" base b.data_counter in
  b.data_counter <- b.data_counter + 1;
  name

let module_prefix b = b.prefix
let add_function b func = b.funcs <- func :: b.funcs
let add_data b data = b.datas <- data :: b.datas

let finish_module b ~initializers =
  { funcs = List.rev_append b.funcs initializers; datas = List.rev b.datas }

let open_label b = b.cur_fn.open_label
let block_is_open b = b.cur_fn.term = None
let inline_rc b = b.inline_single_thread_rc
let compact_arc b = b.cur_fn.compact_arc
let in_initializer b = b.cur_fn.in_init
let self b = b.cur_fn.self
let current_group b = b.cur_fn.cur_group
let poll_tick b = b.cur_fn.poll_tick
let set_poll_tick b tick = b.cur_fn.poll_tick <- tick

let try_handler b =
  match b.cur_fn.try_stack with
  | label :: _ -> Some label
  | [] -> None
let with_try_handler b label f =
  let frame = b.cur_fn in
  let saved = frame.try_stack in
  frame.try_stack <- label :: saved;
  Fun.protect ~finally:(fun () -> frame.try_stack <- saved) f

let known_heap_slot b id = Ident.Set.mem id b.cur_fn.known_heap_slots
let untagged_index b id = Hashtbl.find_opt b.cur_fn.untagged_indices id
let with_untagged_index b id index f =
  let indices = b.cur_fn.untagged_indices in
  Hashtbl.add indices id index;
  Fun.protect ~finally:(fun () -> Hashtbl.remove indices id) f

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

let is_known_heap b = function
  | Temp name -> Hashtbl.mem b.cur_fn.known_heap name
  | _ -> false

let mark_heap b value =
  (match value with
  | Temp name -> Hashtbl.replace b.cur_fn.known_heap name ()
  | _ -> ());
  value

let with_known_heap b value f =
  match value with
  | Temp name when not (is_known_heap b value) ->
      let facts = b.cur_fn.known_heap in
      Hashtbl.replace facts name ();
      Fun.protect ~finally:(fun () -> Hashtbl.remove facts name) f
  | _ -> f ()

(* A dereference proves the loaded value, and further loads from
   the same stack slot until a store or control-flow merge. *)
let forget_heap_slot b slot =
  b.cur_fn.known_heap_slots <- Ident.Set.remove slot b.cur_fn.known_heap_slots

let forget_heap_slots b =
  b.cur_fn.known_heap_slots <- Ident.Set.empty

let with_heap_slot b slot f =
  if Ident.Set.mem slot b.cur_fn.known_heap_slots then f ()
  else begin
    b.cur_fn.known_heap_slots <- Ident.Set.add slot b.cur_fn.known_heap_slots;
    Fun.protect ~finally:(fun () -> forget_heap_slot b slot) f
  end

let emit b inst =
  if b.cur_fn.term <> None then invalid_arg "codegen: instruction after terminator";
  (match inst with
  | Copy (Long, dst, source) when is_known_heap b source -> ignore (mark_heap b dst)
  | Phi (Long, dst, (_ :: _ as incoming))
    when List.for_all (fun (_, value) -> is_known_heap b value) incoming ->
      ignore (mark_heap b dst)
  | _ -> ());
  b.cur_fn.insts <- inst :: b.cur_fn.insts

(* Hoist fixed-size alloc8 slots to @start so QBE treats them as static frame
   slots rather than dynamic alloca inside loops or tail-recursive @loop. *)
let emit_start_alloc b dst bytes =
  b.cur_fn.start_allocs <-
    Alloc8 (dst, Int (Int64.of_int bytes)) :: b.cur_fn.start_allocs

let shadow_batch_slot b words =
  let slot, capacity = match b.cur_fn.shadow_batch with
    | Some batch -> batch
    | None -> fresh_temp b "shadow_args", 0
  in
  b.cur_fn.shadow_batch <- Some (slot, max words capacity);
  slot

let finish_blocks b =
  let allocs = List.rev b.cur_fn.start_allocs in
  let allocs = match b.cur_fn.shadow_batch with
    | None -> allocs
    | Some (slot, words) -> Alloc8 (slot, Int (Int64.of_int (8 * words))) :: allocs
  in
  let blocks = List.rev b.cur_fn.blocks in
  let blocks =
    if allocs = [] then blocks
    else
      List.map
        (fun blk ->
          if String.equal blk.label "start" then
            { blk with insts = allocs @ blk.insts }
          else blk)
        blocks
  in
  let names : Qbe_il.Names.t =
    { temp_counter = b.temp_counter; label_counter = b.label_counter }
  in
  let blocks, names = Qbe_il.optimize_blocks names blocks in
  b.temp_counter <- names.temp_counter;
  b.label_counter <- names.label_counter;
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

let jump_to_entry b values =
  b.cur_fn.tail_sites <- (b.cur_fn.open_label, values) :: b.cur_fn.tail_sites;
  close_block b (Jmp b.cur_fn.entry_label)

let insert_header_phis b header_label binder_names start_values =
  if binder_names <> [] then begin
    let sites = List.rev b.cur_fn.tail_sites in
    let phis =
      List.mapi
        (fun i (ty, name) ->
          let args =
            ("start", List.nth start_values i)
            :: List.filter_map
                 (fun (lbl, vs) ->
                   match List.nth_opt vs i with
                   | Some v -> Some (lbl, v)
                   | None -> None)
                 sites
          in
          Phi (ty, Temp name, args))
        binder_names
    in
    b.cur_fn.blocks <-
      List.map
        (fun blk ->
          if blk.label = header_label then { blk with insts = phis @ blk.insts }
          else blk)
        b.cur_fn.blocks
  end

let with_static_handler b id label f =
  let handlers = b.cur_fn.handlers in
  let previous = Hashtbl.find_opt handlers id in
  let handler = { hlabel = label; hpreds = [] } in
  Hashtbl.replace handlers id handler;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some outer -> Hashtbl.replace handlers id outer
      | None -> Hashtbl.remove handlers id)
    (fun () ->
      let value = f () in
      value, List.rev handler.hpreds)

let jump_static_handler b id values =
  match Hashtbl.find_opt b.cur_fn.handlers id with
  | Some handler ->
      let vs = values () in
      handler.hpreds <- (b.cur_fn.open_label, vs) :: handler.hpreds;
      close_block b (Jmp handler.hlabel)
  | None -> failwith "codegen: uncaught static raise"

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

let untag b = function
  | Int value -> Int (Int64.shift_right value 1)
  | value ->
      let raw = fresh_temp b "untag" in
      emit b (Binop (Sar, Long, raw, value, Int 1L));
      raw

let retag b v =
  let t = fresh_temp b "retag" in
  emit b (Binop (Shl, Long, t, v, Int 1L));
  let t' = fresh_temp b "tag" in
  emit b (Binop (Add, Long, t', t, Int 1L));
  t'

let find_ocaml_value b id =
  match Hashtbl.find_opt b.vars id with
  | Some _ as value -> value
  | None -> Option.map (retag b) (Hashtbl.find_opt b.cur_fn.untagged_indices id)

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

(* Header offsets are relative to the [ArcHeader] base: its 32-bit count,
   16-bit tag, and collector flags at byte 12. Keep the collector's first
   candidate registration and all destruction in the runtime. *)
let emit_single_thread_rc b operation value done_ =
  let header = ptr_offset b value (-16) "rc_header" in
  let count = fresh_temp b "rc_count" in
  let immortal = fresh_temp b "rc_immortal" in
  let mortal = fresh_label b "rc_mortal" in
  emit b (Load (Loadw, Word, count, header));
  emit b (Cmp (Eq, Word, immortal, count, Int (-1L)));
  close_block b (Br (immortal, done_, mortal));
  start_block b mortal;
  let update op =
    let next = fresh_temp b "rc_next" in
    emit b (Binop (op, Word, next, count, Int 1L));
    emit b (Store (Storew, next, header));
    close_block b (Jmp done_)
  in
  match operation with
  | `Retain -> update Add
  | `Release ->
      let shared = fresh_label b "rc_shared" in
      let decrement = fresh_label b "rc_decrement" in
      let slow = fresh_label b "rc_release_slow" in
      let has_other_owner = fresh_temp b "rc_shared" in
      emit b (Cmp (Ult, Word, has_other_owner, Int 1L, count));
      close_block b (Br (has_other_owner, shared, slow));
      start_block b shared;
      let flags_addr = ptr_offset b header 12 "rc_flags_ptr" in
      let flags = fresh_temp b "rc_flags" in
      let buffered = fresh_temp b "rc_buffered" in
      emit b (Load (Loadw, Word, flags, flags_addr));
      emit b (Binop (And, Word, buffered, flags, Int 4L));
      let tag = fresh_temp b "rc_object_tag" in
      let tag_addr = ptr_offset b header 4 "rc_tag_ptr" in
      emit b (Load (Loaduh, Word, tag, tag_addr));
      let leaf_index = fresh_temp b "rc_leaf_index" in
      let leaf = fresh_temp b "rc_leaf" in
      emit b (Binop (Sub, Word, leaf_index, tag, Int (Int64.of_int arc_tag_string)));
      emit b (Cmp (Ult, Word, leaf, leaf_index,
                  Int (Int64.of_int (arc_tag_custom - arc_tag_string + 1))));
      let can_decrement = fresh_temp b "rc_can_decrement" in
      emit b (Binop (Or, Word, can_decrement, buffered, leaf));
      close_block b (Br (can_decrement, decrement, slow));
      start_block b decrement;
      update Sub;
      start_block b slow;
      emit b (Call_void { fn = Global "arc_release"; args = [ (Long, value) ] });
      close_block b (Jmp done_)

let with_compact_arc b f =
  let state = b.cur_fn in
  let saved = state.compact_arc in
  state.compact_arc <- true;
  Fun.protect ~finally:(fun () -> state.compact_arc <- saved) f

let emit_arc_if_heap b operation value =
  let call ~tagged =
    let fn =
      match operation with `Retain -> "arc_retain" | `Release -> "arc_release"
    in
    let fn = if tagged then fn ^ "_val" else fn in
    emit b (Call_void { fn = Global fn; args = [ (Long, value) ] })
  in
  match value with
  | Int n when n = 0L || Int64.logand n 1L = 1L -> ()
  | _ ->
      let guarded = not (is_known_heap b value) in
      if b.inline_single_thread_rc && b.cur_fn.compact_arc then
        call ~tagged:guarded
      else if not guarded && not b.inline_single_thread_rc then call ~tagged:false
      else begin
        let done_ = fresh_label b "rc_done" in
        if guarded then begin
          (* Isolate the low bit. Zero and tagged immediates give 0 and 1;
             an aligned non-null pointer gives an unsigned value above 1. *)
          let neg = fresh_temp b "rc_neg" in
          let lowbit = fresh_temp b "rc_lowbit" in
          let is_heap = fresh_temp b "rc_is_heap" in
          let heap = fresh_label b "rc_heap" in
          emit b (Neg (Long, neg, value));
          emit b (Binop (And, Long, lowbit, value, neg));
          emit b (Cmp (Ult, Long, is_heap, Int 1L, lowbit));
          close_block b (Br (is_heap, heap, done_));
          start_block b heap
        end;
        if b.inline_single_thread_rc then
          emit_single_thread_rc b operation value done_
        else begin
          call ~tagged:false;
          close_block b (Jmp done_)
        end;
        start_block b done_
      end

let finish_bounds_guard b ?drop_on_oob ?on_oob ~result_type prefix lok loob on_ok =
  let raise_oob () =
    start_block b loob;
    with_compact_arc b (fun () -> Option.iter (emit_arc_if_heap b `Release) drop_on_oob);
    emit b (Call_void { fn = Global "ocamlcc_raise_invalid_arg_oob"; args = [] })
  in
  match on_oob with
  | Some unwind ->
      raise_oob ();
      unwind ();
      start_block b lok;
      on_ok ()
  | None ->
      let ldone = fresh_label b (prefix ^ "_done") in
      start_block b lok;
      let ok_res = on_ok () in
      let lok_end = b.cur_fn.open_label in
      close_block b (Jmp ldone);
      raise_oob ();
      let failure =
        if result_type = Double then begin
          let zero = fresh_temp b "bnd_zero" in
          emit b (Cast (Double, zero, Int 0L));
          zero
        end else unit_const
      in
      let loob_end = b.cur_fn.open_label in
      close_block b (Jmp ldone);
      start_block b ldone;
      let dst = fresh_temp b (prefix ^ "v") in
      emit b (Phi (result_type, dst, [ (lok_end, ok_res); (loob_end, failure) ]));
      dst

let compile_bounds_guarded b ?drop_on_oob ?on_oob ?(result_type = Long)
    idx_untagged len_val on_ok =
  let ok = fresh_temp b "bnd" in
  emit b (Cmp (Ult, Long, ok, idx_untagged, len_val));
  let lok = fresh_label b "bnd_ok" in
  let loob = fresh_label b "bnd_oob" in
  close_block b (Br (ok, lok, loob));
  finish_bounds_guard b ?drop_on_oob ?on_oob ~result_type "bnd" lok loob on_ok

let compile_bytes_slice_bounds_guarded b ?on_oob ?(result_type = Long)
    idx_untagged len_val width on_ok =
  if width <= 1 then
    compile_bounds_guarded b ?on_oob ~result_type idx_untagged len_val on_ok
  else
    let has_room = fresh_temp b "sroom" in
    emit b (Cmp (Sge, Long, has_room, len_val, Int (Int64.of_int width)));
    let lroom = fresh_label b "sroom_ok" in
    let lok = fresh_label b "sbnd_ok" in
    let loob = fresh_label b "sbnd_oob" in
    close_block b (Br (has_room, lroom, loob));
    start_block b lroom;
    let limit = fresh_temp b "slim" in
    emit b
      (Binop (Sub, Long, limit, len_val, Int (Int64.of_int (width - 1))));
    let ok = fresh_temp b "sbnd" in
    emit b (Cmp (Ult, Long, ok, idx_untagged, limit));
    close_block b (Br (ok, lok, loob));
    finish_bounds_guard b ?on_oob ~result_type "sbnd" lok loob on_ok

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

let emit_block_alloc b ?reuse (scan : Anf.block_scan) (tag : int) (vs : Qbe_il.t list) : Qbe_il.t =
  match vs with
  | [] -> unit_const
  | _ ->
      let n = List.length vs in
      let scan_count = if scan = Anf.Scan_none then 0 else n in
      let obj = fresh_temp b "blk" in
      let layout =
        [ (Long, Int (Int64.of_int tag));
          (Long, Int (Int64.of_int scan_count));
          (Long, Int (Int64.of_int (8 * n))) ]
      in
      let call =
        match reuse with
        | Some (primary, Some fallback) ->
            { fn = Global "arc_alloc_reuse_or";
              args = (Long, primary) :: (Long, fallback) :: layout }
        | Some (primary, None) ->
            { fn = Global "arc_alloc_reuse"; args = (Long, primary) :: layout }
        | None -> { fn = Global "arc_alloc"; args = layout }
      in
      emit b (Call (Long, obj, call));
      List.iteri
        (fun i v ->
          let addr = ptr_offset b obj (8 * i) "fldp" in
          emit b (Store (Storel, v, addr)))
        vs;
      mark_heap b obj

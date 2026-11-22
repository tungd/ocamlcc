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
    term = None;
    blocks = [];
    fn_params = [];
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

(* QBE's parser caps phi incoming edges at NPred = 63 (vendor/qbe/parse.c).
   Split any block with wide phis into a balanced tree of trampoline blocks
   of at most [max_phi_preds] predecessors each so arbitrary-width OCaml
   switches compile cleanly under unmodified upstream QBE. *)
let max_phi_preds = 50

let block_has_wide_phi (blk : Qbe_il.block) =
  List.exists
    (function
      | Phi (_, _, args) -> List.length args > max_phi_preds
      | _ -> false)
    blk.insts

let chunk_list k xs =
  let rec go cur cur_n acc = function
    | [] ->
        let acc = if cur = [] then acc else List.rev cur :: acc in
        List.rev acc
    | x :: rest ->
        if cur_n = k then go [ x ] 1 (List.rev cur :: acc) rest
        else go (x :: cur) (cur_n + 1) acc rest
  in
  go [] 0 [] xs

let rec split_wide_phis b (blocks : Qbe_il.block list) : Qbe_il.block list =
  match List.find_opt block_has_wide_phi blocks with
  | None -> blocks
  | Some (target : Qbe_il.block) ->
      let target_lbl = target.label in
      let phis, non_phis =
        List.partition (function Phi _ -> true | _ -> false) target.insts
      in
      let seen = Hashtbl.create 64 in
      let pred_order = ref [] in
      List.iter
        (function
          | Phi (_, _, args) ->
              List.iter
                (fun (lbl, _) ->
                  if not (Hashtbl.mem seen lbl) then begin
                    Hashtbl.replace seen lbl ();
                    pred_order := lbl :: !pred_order
                  end)
                args
          | _ -> ())
        phis;
      let chunks = chunk_list max_phi_preds (List.rev !pred_order) in
      let pred_to_split = Hashtbl.create 64 in
      let split_specs =
        List.map
          (fun chunk ->
            let slbl = fresh_label b "phisplit" in
            let member = Hashtbl.create (List.length chunk) in
            List.iter
              (fun plbl ->
                Hashtbl.replace pred_to_split plbl slbl;
                Hashtbl.replace member plbl ())
              chunk;
            (slbl, member))
          chunks
      in
      let new_phi_args = Array.make (List.length phis) [] in
      let split_blocks =
        List.map
          (fun (slbl, member) ->
            let insts = ref [] in
            List.iteri
              (fun idx inst ->
                match inst with
                | Phi (ty, _, args) -> (
                    let sub_args =
                      List.filter (fun (lbl, _) -> Hashtbl.mem member lbl) args
                    in
                    match sub_args with
                    | [] -> ()
                    | [ (_, v) ] ->
                        let tmp = fresh_temp b "phisp" in
                        insts := Copy (ty, tmp, v) :: !insts;
                        new_phi_args.(idx) <- (slbl, tmp) :: new_phi_args.(idx)
                    | _ ->
                        let tmp = fresh_temp b "phisp" in
                        insts := Phi (ty, tmp, sub_args) :: !insts;
                        new_phi_args.(idx) <- (slbl, tmp) :: new_phi_args.(idx))
                | _ -> ())
              phis;
            { label = slbl; insts = List.rev !insts; term = Jmp target_lbl })
          split_specs
      in
      let reduced_phis =
        List.mapi
          (fun idx inst ->
            match inst with
            | Phi (ty, dst, _) -> Phi (ty, dst, List.rev new_phi_args.(idx))
            | other -> other)
          phis
      in
      let rewrite_edge from_lbl dst_lbl =
        if String.equal dst_lbl target_lbl then
          match Hashtbl.find_opt pred_to_split from_lbl with
          | Some slbl -> slbl
          | None -> dst_lbl
        else dst_lbl
      in
      let rewrite_term from_lbl = function
        | Jmp l -> Jmp (rewrite_edge from_lbl l)
        | Br (c, t, f) ->
            Br (c, rewrite_edge from_lbl t, rewrite_edge from_lbl f)
        | (Ret _ | Hlt) as term -> term
      in
      let blocks' =
        List.concat_map
          (fun blk ->
            let term = rewrite_term blk.label blk.term in
            if String.equal blk.label target_lbl then
              split_blocks
              @ [ { blk with insts = reduced_phis @ non_phis; term } ]
            else [ { blk with term } ])
          blocks
      in
      split_wide_phis b blocks'

let temp_used_once blocks =
  let counts = Hashtbl.create 32 in
  let use = function
    | Temp id ->
        let n = Option.value ~default:0 (Hashtbl.find_opt counts id) in
        Hashtbl.replace counts id (n + 1)
    | Int _ | Global _ | Extern _ -> ()
  in
  let use_inst = function
    | Binop (_, _, _, a, b) | Cmp (_, _, _, a, b)
    | Fcmp (_, _, _, a, b) | Store (_, a, b) -> use a; use b
    | Neg (_, _, a) | Cast (_, _, a) | Extsw (_, a) | Sltof (_, _, a)
    | Dtosi (_, _, a) | Copy (_, _, a) | Load (_, _, _, a)
    | Alloc8 (_, a) -> use a
    | Phi (_, _, edges) -> List.iter (fun (_, arg) -> use arg) edges
    | Call (_, _, call) | Call_void call ->
        use call.fn;
        List.iter (fun (_, arg) -> use arg) call.args
  in
  List.iter (fun (block : Qbe_il.block) ->
    List.iter use_inst block.insts;
    match block.term with
    | Br (cond, _, _) -> use cond
    | Ret value -> Option.iter use value
    | Hlt | Jmp _ -> ()) blocks;
  fun id -> Hashtbl.find_opt counts id = Some 1

(* Branch directly from the arms of a short circuit when the joined value
   is used only as a test. Visit the outer joins first so the new tests
   can also be pushed into inner joins. *)
let shortcut_boolean_joins b blocks =
  let by_label = Hashtbl.create 32 in
  let incoming = Hashtbl.create 32 in
  let phi_sources = Hashtbl.create 32 in
  let count map label = Option.value ~default:0 (Hashtbl.find_opt map label) in
  let change map label n = Hashtbl.replace map label (count map label + n) in
  let edges n = function
    | Jmp label -> change incoming label n
    | Br (_, yes, no) -> change incoming yes n; change incoming no n
    | Ret _ | Hlt -> ()
  in
  List.iter (fun (block : Qbe_il.block) ->
    Hashtbl.add by_label block.label block;
    edges 1 block.term;
    List.iter (function
      | Phi (_, _, args) -> List.iter (fun (label, _) -> change phi_sources label 1) args
      | _ -> ()) block.insts) blocks;
  let used_once = lazy (temp_used_once blocks) in
  List.iter (fun (original : Qbe_il.block) ->
    let block = Hashtbl.find by_label original.label in
    match block.insts, block.term with
    | [Phi (Long, Temp value, (_ :: _ as args));
       Cmp (Ne, Long, Temp test, Temp tested, Int 1L)],
      Br (Temp condition, yes, no)
      when tested = value && test = condition
        && count phi_sources block.label = 0
        && List.length args = count incoming block.label
        && Lazy.force used_once value
        (* Newly introduced tests are local to their terminator. *)
        && (block != original || Lazy.force used_once test)
        && List.for_all (fun (label, _) ->
          (Hashtbl.find by_label label).term = Jmp block.label) args ->
        edges (-1) block.term;
        List.iter (fun (label, arg) ->
          let pred = Hashtbl.find by_label label in
          let pred = match arg with
            | Int n -> { pred with term = Jmp (if n = 1L then no else yes) }
            | _ ->
                let test = fresh_temp b "cond" in
                { pred with insts = pred.insts @ [Cmp (Ne, Long, test, arg, Int 1L)];
                            term = Br (test, yes, no) }
          in
          change phi_sources label (-1);
          edges 1 pred.term;
          Hashtbl.replace by_label label pred) args;
        Hashtbl.remove by_label block.label
    | _ -> ()) (List.rev blocks);
  List.filter_map (fun (block : Qbe_il.block) -> Hashtbl.find_opt by_label block.label) blocks

(* Lower a comparison followed by retagging and an immediate branch directly
   to a branch on its 0/1 result. A phi, return, or any other use in a
   successor can still require the tagged value. *)
let fuse_tagged_branches blocks =
  let booleans = Hashtbl.create 32 in
  let rec record = function
    | Cmp (_, _, result, _, _)
      :: Binop (Shl, Long, shifted, raw, Int 1L)
      :: Binop (Add, Long, Temp tag, shift, Int 1L) :: rest
      when raw = result && shift = shifted ->
        Hashtbl.replace booleans tag (raw, shifted);
        record rest
    | _ :: rest -> record rest
    | [] -> ()
  in
  List.iter (fun (block : Qbe_il.block) -> record block.insts) blocks;
  let uses = lazy (temp_used_once blocks) in
  let used_once = function
    | Temp id -> Lazy.force uses id
    | _ -> false
  in
  let dead = Hashtbl.create 16 in
  let rewrite (block : Qbe_il.block) =
    match block.term with
    | Br (cond, yes, no) ->
        (match List.rev block.insts with
        | Cmp (Ne, Long, test, (Temp tag as tagged), Int 1L) :: earlier
          when test = cond ->
            (match Hashtbl.find_opt booleans tag with
            | Some (raw, (Temp shift as shifted)) when used_once test ->
                if used_once tagged && used_once shifted then begin
                  Hashtbl.replace dead tag ();
                  Hashtbl.replace dead shift ()
                end;
                { block with insts = List.rev earlier; term = Br (raw, yes, no) }
            | _ -> block)
        | _ -> block)
    | _ -> block
  in
  if Hashtbl.length booleans = 0 then blocks
  else
    let blocks = List.map rewrite blocks in
    let live_inst = function
      | Binop (_, _, Temp dst, _, _) -> not (Hashtbl.mem dead dst)
      | _ -> true
    in
    List.map (fun (block : Qbe_il.block) ->
      { block with insts = List.filter live_inst block.insts }) blocks

let finish_blocks b =
  let allocs = List.rev b.cur_fn.start_allocs in
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
  split_wide_phis b (fuse_tagged_branches (shortcut_boolean_joins b blocks))

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

let compile_bytes_slice_bounds_guarded b ?on_oob idx_untagged len_val (width : int)
    (on_ok : unit -> Qbe_il.t) : Qbe_il.t =
  if width <= 1 then compile_bounds_guarded b ?on_oob idx_untagged len_val on_ok
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
    finish_bounds_guard b ?on_oob ~result_type:Long "sbnd" lok loob on_ok

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

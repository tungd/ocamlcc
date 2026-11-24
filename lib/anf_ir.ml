(* Administrative normal form and queries shared by its passes. *)

type const_item =
  | C_int of int
  | C_char of char
  | C_string of string
  | C_float of float
  | C_int32 of int32
  | C_int64 of int64
  | C_nativeint of nativeint
  | C_float_array of float list
  | C_block of int * const_item list

type exception_effect = No_raise | Finalizer_raise | May_raise

type atom =
  | Var of Ident.t
  | MutVar of Ident.t
  | ModuleSlot of Ident.t * Lambda.value_kind
  | BorrowedField of int * atom
  | Int of int
  | Char of char
  | String of string
  | Float of float
  | Int32 of int32
  | Int64 of int64
  | Nativeint of nativeint
  | ConstFloatArray of float list
  | ConstBlock of int * const_item list
  | Unit

type float_arithmetic = Addf | Subf | Mulf | Divf

type integer_arithmetic = Add_int | Sub_int | Mul_int | Div_int | Rem_int | And_int | Or_int | Xor_int

type integer_shift = Left_shift | Logical_right | Arithmetic_right

type binop =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | And
  | Or
  | Xor
  | Lsl
  | Lsr
  | Asr
  | Cmp of Lambda.integer_comparison
  | Compare_ints
  | Isout
  | Float_arithmetic of float_arithmetic
  | Fcmp of Lambda.float_comparison
  | Compare_floats
  | Bint_arith of Lambda.boxed_integer * integer_arithmetic
  | Bint_shift of Lambda.boxed_integer * integer_shift
  | Bint_cmp of Lambda.boxed_integer * Lambda.integer_comparison
  | Compare_bints of Lambda.boxed_integer

type unop =
  | Neg
  | Not
  | Offset of int
  | Isint
  | String_length
  | Array_length
  | Float_of_int
  | Int_of_float
  | Fneg
  | Fabs
  | Bint_of_int of Lambda.boxed_integer
  | Int_of_bint of Lambda.boxed_integer
  | Bint_cvt of Lambda.boxed_integer * Lambda.boxed_integer
  | Bint_neg of Lambda.boxed_integer

type bigarray_access = {
  operation : [ `Get | `Set ];
  rank : int;
  kind : Lambda.bigarray_kind;
  layout : Lambda.bigarray_layout;
  checked : bool;
}

(* Unboxed scalars are compiler temporaries. Only scalar operations can consume them. *)
type scalar_rep = Double_scalar | Integer_scalar of Lambda.boxed_integer

type integer_relation = Predicate of Lambda.integer_comparison | Three_way

type scalar_operand = Boxed_scalar of atom | Raw_scalar of Ident.t

module Byte_store = struct
  type t = Uint16 of atom | Int32 of scalar_operand | Int64 of scalar_operand

  let width = function Uint16 _ -> 2 | Int32 _ -> 4 | Int64 _ -> 8
end

module Byte_load = struct
  type t =
    | Uint16
    | Boxed_word of Builtins.Byte_access.word
    | Raw_word of Builtins.Byte_access.word
end

module Native_call = struct
  type t = {
    primitive : Primitive.description;
    may_suspend : bool;
  }
end

type field_kind = Immediate_field | Immutable_field | Mutable_field
type block_scan = Scan_all | Scan_if_managed | Scan_none

type reuse = { primary : Ident.t; fallback : Ident.t option }

type cexpr =
  | Atom of atom
  | Binop of binop * atom * atom
  | IntSelect of Builtins.int_selection * atom * atom
  | Unop of unop * atom
  | MakeBlock of int * block_scan * atom list
  | AllocReuse of reuse * int * block_scan * atom list
  | MakeArray of Lambda.array_kind * atom list
  | Field of int * field_kind * atom
  | SetField of int * Lambda.immediate_or_pointer * atom * atom
  | FloatField of int * atom
  | SetFloatField of int * atom * scalar_operand
  | SetBoxedFloatField of int * atom * scalar_operand
  | OffsetRef of int * atom
  | StringGet of bool * atom * atom
  | BytesSet of bool * atom * atom * atom
  | BytesGetN of bool * Byte_load.t * atom * atom
  | BytesSetN of bool * atom * atom * Byte_store.t
  | Bswap16 of atom
  | BswapBint of Lambda.boxed_integer * atom
  | ArrayGet of bool * Lambda.array_kind * atom * atom
  | ArraySet of bool * Lambda.array_kind * atom * atom * atom
  | BigarrayAccess of bigarray_access * atom list
  | ScalarLoad of bigarray_access * atom * atom
  | ScalarStore of bigarray_access * atom * atom * scalar_operand
  | ScalarValue of scalar_rep * scalar_operand
  | BoxScalar of scalar_rep * scalar_operand
  | FloatArrayGet of bool * atom * atom
  | FloatArraySet of bool * atom * atom * scalar_operand
  | FloatOfInt of atom
  | IntOfFloat of scalar_operand
  | FloatSign of [ `Neg | `Abs ] * scalar_operand
  | FloatCompare of Lambda.float_comparison * scalar_operand * scalar_operand
  | FloatBinop of float_arithmetic * scalar_operand * scalar_operand
  | IntegerBinop of Lambda.boxed_integer * integer_arithmetic * scalar_operand * scalar_operand
  | IntegerCompare of Lambda.boxed_integer * integer_relation * scalar_operand * scalar_operand
  | IntegerOfInt of Lambda.boxed_integer * atom
  | IntOfInteger of Lambda.boxed_integer * scalar_operand
  | IntegerConvert of Lambda.boxed_integer * Lambda.boxed_integer * scalar_operand
  | IntegerNeg of Lambda.boxed_integer * scalar_operand
  | IntegerShift of Lambda.boxed_integer * integer_shift * scalar_operand * atom
  | CreateBytes of atom
  | MakeArrayInit of atom * atom
  | App of atom * atom list
  | Recur of atom list
  | KeepAlive of atom list
  | DirectApp of imported_function * atom list
  | Builtin of string * Builtins.arg_kind * atom
  | Ccall of string * atom list
  | PollFinalizers
  | LoopPollDue of atom * atom
  | NativeCcall of Native_call.t * atom list
  | GetGlobal of string
  | ImportDependency of string
  | StoreModuleSlot of Ident.t * atom
  | Fun of lfunction
  | Assign of Ident.t * atom
  | AssignImm of Ident.t * atom
  | ReadScalarSlot of scalar_rep * Ident.t
  | AssignScalar of Ident.t * scalar_rep * scalar_operand

and unicode_validation = Unicode_test | Unicode_check

and imported_function = {
  unit_name : string;
  symbol : string;
  arity : int;
  yields : bool;
  raises : exception_effect;
  returns_immediate : bool;
  borrowed_entry : (string * bool list) option;
  inline_leaf : lfunction option;
  inline_lambda : Lambda.lfunction option;
  inline_init : string option;
  unicode_validation : unicode_validation option;
}

and lfunction = {
  params : (Ident.t * Lambda.value_kind) list;
  return : Lambda.value_kind;
  private_entry : bool;
  periodic_poll : bool;
  loop_scalars : (Ident.t * (scalar_rep * Ident.t)) list;
  body : aexpr;
}

and rec_binding = {
  id : Ident.t;
  def : lfunction;
}

and aexpr =
  | Halt of atom
  | HaltScalar of Ident.t
  | Let of Ident.t * cexpr * aexpr
  | MutLet of Ident.t * cexpr * aexpr
  | LetJoin of Ident.t * aexpr * aexpr
  | LetRec of rec_binding list * aexpr
  | If of atom * aexpr * aexpr
  | ScalarIf of scalar_rep * atom * aexpr * aexpr
  | Switch of atom * switch_cases
  | StringSwitch of atom * (string * aexpr) list * aexpr option
  | StaticCatch of aexpr * int * Ident.t list * aexpr * scalar_rep option
  | StaticRaise of int * atom list
  | While of aexpr * aexpr
  | For of Ident.t * atom * atom * Asttypes.direction_flag * aexpr
  | TryWith of aexpr * Ident.t * aexpr
  | Raise of atom
  | CheckExn of exception_effect * aexpr * aexpr
  | Unwind
  | Retain of Ident.t * aexpr
  | Release of Ident.t * aexpr
  | ReleaseMut of Ident.t * aexpr
  | DropReuse of Ident.t * Ident.t * aexpr
  | FreeReuse of Ident.t * aexpr
  | ShadowPush of Ident.t list * Ident.t list * Ident.t list * aexpr
  | ShadowPop of int * int * aexpr

and switch_cases = {
  result_rep : scalar_rep option;
  consts : (int * aexpr) list;
  blocks : (int * aexpr) list;
  fail : aexpr option;
}

type exports = (int list * imported_function) list

type program = {
  module_ident : Ident.t;
  code : aexpr;
  value_kinds : Lambda.value_kind Ident.Map.t;
  inline_bodies : Lambda.lfunction Ident.Map.t;
  inline_initializers : (string * string) list;
}

(* Calls and allocations on the success path need the usual poll.
   Checked scalar byte accesses only allocate when they leave via a bounds
   exception. Their error continuations are still marked as raising. *)
let is_local_operation = function
  | Binop ((Div | Mod), _, Int n) -> n <> 0
  | Atom _ | Field _ | SetField _ | StoreModuleSlot _ | IntSelect _ | Assign _ | AssignImm _
  | ImportDependency _
  | ReadScalarSlot _ | AssignScalar _
  | IntegerOfInt _ | IntOfInteger (_, Raw_scalar _)
  | ScalarValue (Integer_scalar _, Raw_scalar _)
  | BytesGetN (_, Raw_word _, _, _)
  | BytesSetN (_, _, _, (Int32 (Raw_scalar _) | Int64 (Raw_scalar _)))
  | Binop ((Add | Sub | Mul | And | Or | Xor | Lsl | Lsr | Asr
           | Cmp _ | Compare_ints | Isout), _, _)
  | Unop ((Neg | Not | Offset _ | Isint | String_length | Array_length), _)
  | StringGet (false, _, _)
  | BytesSet (false, _, _, _) | ArraySet (false, _, _, _, _)
  | ArrayGet (false, (Lambda.Pintarray | Lambda.Paddrarray), _, _) -> true
  | DirectApp (target, _) -> Option.is_some target.inline_leaf
  (* Generic reads can box a flat-float element. *)
  | _ -> false

let rec is_bounded_local ?backedge = function
  | Halt _ | HaltScalar _ | StaticRaise _ -> true
  | Let (id, App (Var fn, args), Halt (Var result))
    when Ident.same id result ->
      Option.fold ~none:false ~some:(fun (self, arity) ->
        Ident.same self fn && List.length args = arity) backedge
  | Let (_, ce, body) | MutLet (_, ce, body) ->
      is_local_operation ce && is_bounded_local ?backedge body
  | LetJoin (_, lhs, rhs) ->
      is_bounded_local lhs && is_bounded_local ?backedge rhs
  | If (_, lhs, rhs) | StaticCatch (lhs, _, _, rhs, None) ->
      is_bounded_local ?backedge lhs && is_bounded_local ?backedge rhs
  | ScalarIf (_, _, lhs, rhs) | StaticCatch (lhs, _, _, rhs, Some _) ->
      is_bounded_local lhs && is_bounded_local rhs
  | Switch (_, { consts; blocks; fail; _ }) ->
      List.for_all (fun (_, arm) -> is_bounded_local ?backedge arm) consts
      && List.for_all (fun (_, arm) -> is_bounded_local ?backedge arm) blocks
      && Option.fold ~none:true ~some:(is_bounded_local ?backedge) fail
  | StringSwitch (_, cases, fail) ->
      List.for_all (fun (_, arm) -> is_bounded_local ?backedge arm) cases
      && Option.fold ~none:true ~some:(is_bounded_local ?backedge) fail
  | _ -> false

let native_scalar : Primitive.native_repr -> scalar_rep option = function
  | Unboxed_float -> Some Double_scalar
  | Unboxed_integer Pint32 -> Some (Integer_scalar Pint32)
  | Unboxed_integer Pint64 -> Some (Integer_scalar Pint64)
  | Unboxed_integer Pnativeint -> Some (Integer_scalar Pnativeint)
  | Same_as_ocaml_repr | Untagged_immediate -> None

let scalar_layout = function
  | Lambda.Pbigarray_c_layout | Pbigarray_fortran_layout -> true
  | Pbigarray_unknown_layout -> false

let scalar_rep = function
  | Lambda.Pbigarray_float32 | Pbigarray_float64 -> Some Double_scalar
  | Pbigarray_int32 -> Some (Integer_scalar Pint32)
  | Pbigarray_int64 -> Some (Integer_scalar Pint64)
  | Pbigarray_native_int -> Some (Integer_scalar Pnativeint)
  | _ -> None

let rec atom_vars acc = function
  | Var id | MutVar id -> Ident.Set.add id acc
  | BorrowedField (_, owner) -> atom_vars acc owner
  | Int _ | Char _ | String _ | Float _ | Int32 _ | Int64 _ | Nativeint _
  | ConstFloatArray _ | ConstBlock _ | Unit | ModuleSlot _ ->
      acc

let scalar_operand_vars acc = function
  | Boxed_scalar a -> atom_vars acc a
  | Raw_scalar id -> Ident.Set.add id acc

let byte_store_vars ?(include_raw = true) acc = function
  | Byte_store.Uint16 a -> atom_vars acc a
  | Int32 (Raw_scalar _) | Int64 (Raw_scalar _) when not include_raw -> acc
  | Int32 v | Int64 v -> scalar_operand_vars acc v

let bound_parameters (lf : lfunction) =
  List.map fst lf.params @ List.map (fun (_, (_, owner)) -> owner) lf.loop_scalars

let cexpr_vars ?(include_raw = true) free_aexpr acc ce =
  let scalar_operand_vars acc = function
    | Raw_scalar _ when not include_raw -> acc
    | operand -> scalar_operand_vars acc operand
  in
  match ce with
  | IntegerOfInt (_, value) -> atom_vars acc value
  | IntOfInteger (_, value) | IntegerConvert (_, _, value)
  | IntegerNeg (_, value) -> scalar_operand_vars acc value
  | IntegerShift (_, _, value, count) -> scalar_operand_vars (atom_vars acc count) value
  | ScalarValue (_, a) | BoxScalar (_, a) | IntOfFloat a | FloatSign (_, a) ->
      scalar_operand_vars acc a
  | FloatOfInt a -> atom_vars acc a
  | FloatArrayGet (_, a, i) | ScalarLoad (_, a, i) -> atom_vars (atom_vars acc a) i
  | FloatArraySet (_, a, i, v) | ScalarStore (_, a, i, v) ->
      scalar_operand_vars (atom_vars (atom_vars acc a) i) v
  | FloatBinop (_, a, b) | FloatCompare (_, a, b) | IntegerBinop (_, _, a, b) | IntegerCompare (_, _, a, b) -> scalar_operand_vars (scalar_operand_vars acc a) b
  | Atom a -> atom_vars acc a
  | Binop (_, a, b) | IntSelect (_, a, b) | LoopPollDue (a, b) -> atom_vars (atom_vars acc a) b
  | Unop (_, a) -> atom_vars acc a
  | MakeBlock (_, _, args) | MakeArray (_, args) ->
      List.fold_left atom_vars acc args
  | AllocReuse (reuse, _, _, args) ->
      let acc = Ident.Set.add reuse.primary (List.fold_left atom_vars acc args) in
      Option.fold ~none:acc ~some:(fun id -> Ident.Set.add id acc) reuse.fallback
  | Field (_, _, a) | FloatField (_, a) | OffsetRef (_, a) | CreateBytes a
  | Bswap16 a | BswapBint (_, a) ->
      atom_vars acc a
  | SetFloatField (_, a, v) | SetBoxedFloatField (_, a, v) ->
      scalar_operand_vars (atom_vars acc a) v
  | SetField (_, _, a, b)
  | StringGet (_, a, b)
  | BytesGetN (_, _, a, b)
  | ArrayGet (_, _, a, b)
  | MakeArrayInit (a, b) ->
      atom_vars (atom_vars acc a) b
  | BytesSetN (_, a, b, word) ->
      byte_store_vars ~include_raw (atom_vars (atom_vars acc a) b) word
  | BytesSet (_, a, b, c) | ArraySet (_, _, a, b, c) ->
      atom_vars (atom_vars (atom_vars acc a) b) c
  | App (fn, args) ->
      List.fold_left atom_vars (atom_vars acc fn) args
  | Builtin (_, _, a) -> atom_vars acc a
  | StoreModuleSlot (_, a) -> atom_vars acc a
  | BigarrayAccess (_, args) | Ccall (_, args) | NativeCcall (_, args)
  | DirectApp (_, args) | Recur args | KeepAlive args ->
      List.fold_left atom_vars acc args
  | GetGlobal _ | ImportDependency _ | PollFinalizers -> acc
  | Assign (id, a) | AssignImm (id, a) -> Ident.Set.add id (atom_vars acc a)
  | ReadScalarSlot (_, slot) -> Ident.Set.add slot acc
  | AssignScalar (slot, _, value) -> scalar_operand_vars (Ident.Set.add slot acc) value
  | Fun lf ->
      let body_free = free_aexpr lf.body in
      let body_free =
        List.fold_left
          (fun s p -> Ident.Set.remove p s)
          body_free (bound_parameters lf)
      in
      Ident.Set.union acc body_free

let rec free_vars (e : aexpr) : Ident.Set.t =
  match e with
  | Halt a -> atom_vars Ident.Set.empty a
  | HaltScalar id -> Ident.Set.singleton id
  | Let (id, ce, body) | MutLet (id, ce, body) ->
      let f_ce = cexpr_vars free_vars Ident.Set.empty ce in
      let f_body = Ident.Set.remove id (free_vars body) in
      Ident.Set.union f_ce f_body
  | LetJoin (id, rhs, body) ->
      let f_rhs = free_vars rhs in
      let f_body = Ident.Set.remove id (free_vars body) in
      Ident.Set.union f_rhs f_body
  | LetRec (bindings, body) ->
      let rec_ids =
        List.fold_left
          (fun s rb -> Ident.Set.add rb.id s)
          Ident.Set.empty bindings
      in
      let f_defs =
        List.fold_left
          (fun acc rb ->
            let f_b = free_vars rb.def.body in
            let f_b =
              List.fold_left
                (fun s p -> Ident.Set.remove p s)
                f_b (bound_parameters rb.def)
            in
            Ident.Set.union acc (Ident.Set.diff f_b rec_ids))
          Ident.Set.empty bindings
      in
      let f_body = Ident.Set.diff (free_vars body) rec_ids in
      Ident.Set.union f_defs f_body
  | If (c, th, el) | ScalarIf (_, c, th, el) ->
      atom_vars (Ident.Set.union (free_vars th) (free_vars el)) c
  | Switch (s, sw) ->
      let acc = atom_vars Ident.Set.empty s in
      let acc =
        List.fold_left
          (fun acc (_, arm) -> Ident.Set.union acc (free_vars arm))
          acc sw.consts
      in
      let acc =
        List.fold_left
          (fun acc (_, arm) -> Ident.Set.union acc (free_vars arm))
          acc sw.blocks
      in
      (match sw.fail with
      | Some f -> Ident.Set.union acc (free_vars f)
      | None -> acc)
  | StringSwitch (s, cases, fail) ->
      let acc = atom_vars Ident.Set.empty s in
      let acc =
        List.fold_left
          (fun acc (_, arm) -> Ident.Set.union acc (free_vars arm))
          acc cases
      in
      (match fail with
      | Some f -> Ident.Set.union acc (free_vars f)
      | None -> acc)
  | StaticCatch (body, _, binders, handler, _) ->
      let f_h =
        List.fold_left
          (fun s id -> Ident.Set.remove id s)
          (free_vars handler) binders
      in
      Ident.Set.union (free_vars body) f_h
  | StaticRaise (_, args) ->
      List.fold_left atom_vars Ident.Set.empty args
  | While (cond, body) ->
      Ident.Set.union (free_vars cond) (free_vars body)
  | For (id, s, e, _, body) ->
      let f_b = Ident.Set.remove id (free_vars body) in
      atom_vars (atom_vars f_b s) e
  | TryWith (body, exn_id, handler) ->
      let f_h = Ident.Set.remove exn_id (free_vars handler) in
      Ident.Set.union (free_vars body) f_h
  | Raise a -> atom_vars Ident.Set.empty a
  | CheckExn (_, on_err, on_ok) ->
      Ident.Set.union (free_vars on_err) (free_vars on_ok)
  | Unwind -> Ident.Set.empty
  | Retain (id, body) | Release (id, body) | ReleaseMut (id, body)
  | FreeReuse (id, body) ->
      Ident.Set.add id (free_vars body)
  | DropReuse (v, tok, body) ->
      Ident.Set.add v (Ident.Set.remove tok (free_vars body))
  | ShadowPush (vars, muts, rtoks, body) ->
      let s = Ident.Set.union (free_vars body) (Ident.Set.of_list vars) in
      let s = Ident.Set.union s (Ident.Set.of_list muts) in
      Ident.Set.union s (Ident.Set.of_list rtoks)
  | ShadowPop (_, _, body) -> free_vars body

(* Conditional tests may bind temporaries before the branch itself. *)
let rec returns_scalar = function
  | Let (_, _, body) -> returns_scalar body
  | ScalarIf _ | Switch (_, { result_rep = Some _; _ })
  | StaticCatch (_, _, _, _, Some _) -> true
  | _ -> false

(* Non-capturing function definitions, in pre-order.

   A function (or a whole mutual [let rec] group) whose free variables are
   only its own parameters plus already-collected pure functions needs no
   heap closure: it is compiled as an immortal static function. Both the ARC
   pass (refcount traffic on the binding) and codegen (static definition +
   direct-call grouping) must agree on this set, so it lives here once.

   Unlike a top-level-spine-only walk, this recurses into function bodies
   and every branch/join region ([LetJoin] rhs, [If], [Switch],
   [StaticCatch], [TryWith], [While], [For], [CheckExn]) so helpers defined
   inside other functions are found too, and works on both pre-ARC and
   post-ARC ANF (instruction continuations included). *)
let pure_defs (e : aexpr) : (Ident.t * lfunction) list =
  let is_pure known (lf : lfunction) =
    let params =
      Ident.Set.of_list (bound_parameters lf)
    in
    let free = free_vars lf.body in
    Ident.Set.for_all
      (fun v -> Ident.Set.mem v params || Ident.Set.mem v known)
      free
  in
  let rec go known acc (e : aexpr) =
    match e with
    | Let (id, Fun lf, body) ->
        if is_pure known lf then begin
          (* [id] is an immortal static function: both nested helpers inside
             [lf.body] and subsequent bindings in [body] may call it without
             becoming heap closures. *)
          let known' = Ident.Set.add id known in
          let acc = go known' ((id, lf) :: acc) lf.body in
          go known' acc body
        end
        else
          let acc = go known acc lf.body in
          go known acc body
    | Let (_, _, body) | MutLet (_, _, body) -> go known acc body
    | LetJoin (_, rhs, body) -> go known (go known acc rhs) body
    | LetRec (bindings, body) ->
        let rec_ids =
          List.fold_left
            (fun s (rb : rec_binding) -> Ident.Set.add rb.id s)
            Ident.Set.empty bindings
        in
        let known_grp = Ident.Set.union rec_ids known in
        if List.for_all (fun (rb : rec_binding) -> is_pure known_grp rb.def) bindings
        then begin
          let acc' =
            List.fold_left
              (fun acc (rb : rec_binding) -> (rb.id, rb.def) :: acc)
              acc bindings
          in
          let acc'' =
            List.fold_left
              (fun acc (rb : rec_binding) -> go known_grp acc rb.def.body)
              acc' bindings
          in
          go known_grp acc'' body
        end
        else begin
          let acc' =
            List.fold_left
              (fun acc (rb : rec_binding) -> go known acc rb.def.body)
              acc bindings
          in
          go known acc' body
        end
    | If (_, th, el) | ScalarIf (_, _, th, el) -> go known (go known acc th) el
    | Switch (_, sw) ->
        let acc =
          List.fold_left
            (fun acc arm -> go known acc arm) acc
            (List.map snd sw.consts @ List.map snd sw.blocks)
        in
        (match sw.fail with Some f -> go known acc f | None -> acc)
    | StringSwitch (_, cases, fail) ->
        let acc =
          List.fold_left (fun acc (_, arm) -> go known acc arm) acc cases
        in
        (match fail with Some f -> go known acc f | None -> acc)
    | StaticCatch (body, _, _, handler, _) ->
        go known (go known acc body) handler
    | TryWith (body, _, handler) -> go known (go known acc body) handler
    | While (cond, body) | CheckExn (_, cond, body) ->
        go known (go known acc cond) body
    | For (_, _, _, _, body) -> go known acc body
    | Halt _ | HaltScalar _ | Raise _ | Unwind | StaticRaise _ -> acc
    | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
    | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        go known acc body
  in
  List.rev (go Ident.Set.empty [] e)

module Variables = struct
  let atom = atom_vars
  let computation = cexpr_vars
end

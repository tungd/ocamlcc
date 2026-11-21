(* Lambda -> ANF conversion and free-variable analysis. *)

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
  | Bint_add of Lambda.boxed_integer
  | Bint_sub of Lambda.boxed_integer
  | Bint_mul of Lambda.boxed_integer
  | Bint_div of Lambda.boxed_integer
  | Bint_mod of Lambda.boxed_integer
  | Bint_and of Lambda.boxed_integer
  | Bint_or of Lambda.boxed_integer
  | Bint_xor of Lambda.boxed_integer
  | Bint_lsl of Lambda.boxed_integer
  | Bint_lsr of Lambda.boxed_integer
  | Bint_asr of Lambda.boxed_integer
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

type integer_arithmetic = Add_int | Sub_int | Mul_int | Div_int | Rem_int | And_int | Or_int | Xor_int
type integer_relation = Predicate of Lambda.integer_comparison | Three_way

type integer_shift = Left_shift | Logical_right | Arithmetic_right

type scalar_operand = Boxed_scalar of atom | Raw_scalar of Ident.t

type field_kind = Immediate_field | Immutable_field | Mutable_field

type reuse = { primary : Ident.t; fallback : Ident.t option }

type cexpr =
  | Atom of atom
  | Binop of binop * atom * atom
  | IntSelect of Builtins.int_selection * atom * atom
  | Unop of unop * atom
  | MakeBlock of int * atom list
  | AllocReuse of reuse * int * atom list
  | MakeArray of Lambda.array_kind * atom list
  | Field of int * field_kind * atom
  | SetField of int * Lambda.immediate_or_pointer * atom * atom
  | FloatField of int * atom
  | SetFloatField of int * atom * atom
  | OffsetRef of int * atom
  | StringGet of bool * atom * atom
  | BytesSet of bool * atom * atom * atom
  | BytesGetN of bool * int * atom * atom
  | BytesSetN of bool * int * atom * atom * atom
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
  | NativeCcall of Primitive.description * atom list
  | GetGlobal of string
  | ImportDependency of string
  | StoreModuleSlot of Ident.t * atom
  | Fun of lfunction
  | Assign of Ident.t * atom
  | AssignImm of Ident.t * atom
  | ReadScalarSlot of scalar_rep * Ident.t
  | AssignScalar of Ident.t * scalar_rep * scalar_operand

and imported_function = {
  unit_name : string;
  symbol : string;
  arity : int;
  yields : bool;
  raises : exception_effect;
  returns_immediate : bool;
  inline_leaf : lfunction option;
  inline_lambda : Lambda.lfunction option;
}

and lfunction = {
  params : (Ident.t * Lambda.value_kind) list;
  return : Lambda.value_kind;
  private_entry : bool;
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
}

exception Unsupported of string

let native_scalar : Primitive.native_repr -> scalar_rep option = function
  | Unboxed_float -> Some Double_scalar
  | Unboxed_integer Pint32 -> Some (Integer_scalar Pint32)
  | Unboxed_integer Pint64 -> Some (Integer_scalar Pint64)
  | Unboxed_integer Pnativeint -> Some (Integer_scalar Pnativeint)
  | Same_as_ocaml_repr | Untagged_immediate -> None

let primitive_name p =
  let buf = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer buf in
  Format.fprintf ppf "%a" Printlambda.primitive p;
  Format.pp_print_flush ppf ();
  String.trim (Buffer.contents buf)

let rec describe (lam : Lambda.lambda) : string =
  match lam with
  | Lconst _ -> "non-integer, non-string constant"
  | Lvar _ | Lmutvar _ -> "variable"
  | Lapply _ -> "function application"
  | Lfunction _ -> "function value"
  | Llet (_, _, _, arg, _) | Lmutlet (_, _, arg, _) ->
      Printf.sprintf "let binding of %s" (describe arg)
  | Lletrec _ -> "recursive value binding"
  | Lprim (p, _, _) -> "primitive " ^ primitive_name p
  | Lswitch _ -> "switch"
  | Lstringswitch _ -> "string switch"
  | Lstaticraise _ -> "static raise"
  | Lstaticcatch _ -> "static catch"
  | Ltrywith _ -> "try ... with"
  | Lifthenelse _ -> "if/then/else"
  | Lsequence _ -> "sequence"
  | Lwhile _ -> "while loop"
  | Lfor _ -> "for loop"
  | Lassign _ -> "mutable assignment"
  | Lsend _ -> "method call"
  | Levent _ -> "event (internal)"
  | Lifused _ -> "ifused (internal)"

let parse_const_float (s : string) : float =
  match Float.of_string_opt s with
  | Some f -> f
  | None -> raise (Unsupported ("invalid float constant: " ^ s))

let rec conv_const_item (c : Lambda.structured_constant) : const_item =
  match c with
  | Const_int n -> C_int n
  | Const_char ch -> C_char ch
  | Const_immstring s -> C_string s
  | Const_float s -> C_float (parse_const_float s)
  | Const_int32 n -> C_int32 n
  | Const_int64 n -> C_int64 n
  | Const_nativeint n -> C_nativeint n
  | Const_float_array sl -> C_float_array (List.map parse_const_float sl)
  | Const_block (tag, items) -> C_block (tag, List.map conv_const_item items)

let conv_const (c : Lambda.structured_constant) : atom =
  match c with
  | Const_int n -> Int n
  | Const_char ch -> Char ch
  | Const_immstring s -> String s
  | Const_float s -> Float (parse_const_float s)
  | Const_int32 n -> Int32 n
  | Const_int64 n -> Int64 n
  | Const_nativeint n -> Nativeint n
  | Const_float_array sl -> ConstFloatArray (List.map parse_const_float sl)
  | Const_block (tag, items) -> ConstBlock (tag, List.map conv_const_item items)

let mutable_scalars : scalar_rep Ident.Map.t ref = ref Ident.Map.empty

let unit_imports : (string -> exports option) ref = ref (fun _ -> None)
let module_slots = ref Ident.Map.empty

let variable id =
  match Ident.Map.find_opt id !module_slots with
  | Some kind -> ModuleSlot (id, kind)
  | None -> Var id

let imported_callee_and_unit callee =
  let open Lambda in
  let rec resolve path = function
    | Lprim (Pfield (slot, Pointer, Immutable), [owner], _) ->
        resolve (slot :: path) owner
    | Lprim (Pgetglobal id, [], _) ->
        Option.bind (!unit_imports (Ident.name id))
          (fun exports -> Option.map (fun fn -> fn, id) (List.assoc_opt path exports))
    | _ -> None
  in
  resolve [] callee

let imported_callee callee = Option.map fst (imported_callee_and_unit callee)

let check_array_kind (_k : Lambda.array_kind) = ()

let builtin_tables :
    (Builtins.table option * Builtins.int_selection_table Lazy.t option) ref =
  ref (None, None)

(* Guard the yielding, raising callback path before ARC liveness analysis.
   Idle polls need neither a shadow-stack frame nor an exception check. *)
let with_finalizer_poll body =
  let due = Ident.create_local "finalizers_due" in
  let ignored = Ident.create_local "poll" in
  let result = Ident.create_local "poll_result" in
  Let (due, Ccall ("ocamlcc_finalizers_due", []),
    LetJoin (ignored,
      If (Var due, Let (result, Ccall ("ocamlcc_poll_finalizers", []), Halt Unit),
          Halt Unit),
      body))

(* Only local, bounded operations can defer polling. A call, an allocation,
   or a checked operation that constructs an exception needs the usual poll. *)
let is_local_operation = function
  | Binop ((Div | Mod), _, Int n) -> n <> 0
  | Atom _ | Field _ | SetField _ | StoreModuleSlot _ | IntSelect _ | Assign _ | AssignImm _
  | ImportDependency _
  | ReadScalarSlot _ | AssignScalar _
  | Binop ((Add | Sub | Mul | And | Or | Xor | Lsl | Lsr | Asr
           | Cmp _ | Compare_ints | Isout), _, _)
  | Unop ((Neg | Not | Offset _ | Isint | String_length | Array_length), _)
  | StringGet (false, _, _)
  | BytesSet (false, _, _, _) | ArraySet (false, _, _, _, _)
  | ArrayGet (false, (Lambda.Pintarray | Lambda.Paddrarray), _, _) -> true
  | DirectApp (target, _) -> Option.is_some target.inline_leaf
  (* Generic reads can box a flat-float element. *)
  | _ -> false

let rec is_bounded_local = function
  | Halt _ | HaltScalar _ | StaticRaise _ -> true
  | Let (_, ce, body) | MutLet (_, ce, body) ->
      is_local_operation ce && is_bounded_local body
  | LetJoin (_, lhs, rhs) | If (_, lhs, rhs) | ScalarIf (_, _, lhs, rhs)
  | StaticCatch (lhs, _, _, rhs, _) ->
      is_bounded_local lhs && is_bounded_local rhs
  | Switch (_, { consts; blocks; fail; _ }) ->
      List.for_all (fun (_, arm) -> is_bounded_local arm) consts
      && List.for_all (fun (_, arm) -> is_bounded_local arm) blocks
      && Option.fold ~none:true ~some:is_bounded_local fail
  | StringSwitch (_, cases, fail) ->
      List.for_all (fun (_, arm) -> is_bounded_local arm) cases
      && Option.fold ~none:true ~some:is_bounded_local fail
  | _ -> false

let with_entry_poll body =
  if is_bounded_local body then body else with_finalizer_poll body

(* Masking a distance from the first check works through tagged-int wraparound. *)
let with_periodic_finalizer_poll distance body =
  let phase = Ident.create_local "poll_phase" in
  let due = Ident.create_local "loop_poll_due" in
  let ignored = Ident.create_local "loop_poll" in
  Let (phase, Binop (And, distance, Int 63),
    Let (due, Binop (Cmp Ceq, Var phase, Int 0),
      LetJoin (ignored, If (Var due, with_finalizer_poll (Halt Unit), Halt Unit), body)))

let with_counted_loop_poll index start body =
  let distance = Ident.create_local "poll_distance" in
  Let (distance, Binop (Sub, Var index, start),
    with_periodic_finalizer_poll (Var distance) body)

let while_with_poll cond body =
  if is_bounded_local cond && is_bounded_local body then
    let counter = Ident.create_local "poll_counter" in
    let count = Ident.create_local "poll_count" in
    let next = Ident.create_local "poll_next" in
    let ignored = Ident.create_local "poll_tick" in
    let cond =
      Let (count, Atom (MutVar counter),
        Let (next, Binop (Add, Var count, Int 1),
          Let (ignored, Assign (counter, Var next),
            with_periodic_finalizer_poll (Var count) cond)))
    in
    MutLet (counter, Atom (Int 0), While (cond, body))
  else While (with_finalizer_poll cond, body)

let float_arithmetic = function
  | Lambda.Paddfloat -> Addf
  | Psubfloat -> Subf
  | Pmulfloat -> Mulf
  | Pdivfloat -> Divf
  | _ -> assert false

let scalar_layout = function
  | Lambda.Pbigarray_c_layout | Pbigarray_fortran_layout -> true
  | Pbigarray_unknown_layout -> false

let scalar_rep = function
  | Lambda.Pbigarray_float32 | Pbigarray_float64 -> Some Double_scalar
  | Pbigarray_int32 -> Some (Integer_scalar Pint32)
  | Pbigarray_int64 -> Some (Integer_scalar Pint64)
  | Pbigarray_native_int -> Some (Integer_scalar Pnativeint)
  | _ -> None

let rec conv_tail (lam : Lambda.lambda) : aexpr =
  conv_expr lam (fun a -> Halt a)

and conv_atoms (lams : Lambda.lambda list) (k : atom list -> aexpr) : aexpr =
  match lams with
  | [] -> k []
  | x :: xs -> conv_expr x (fun a -> conv_atoms xs (fun rest -> k (a :: rest)))

and conv_fun (lf : Lambda.lfunction) : lfunction =
  match lf.kind with
  | Curried ->
      { params = lf.params; return = lf.return; private_entry = false;
        loop_scalars = []; body = with_entry_poll (conv_tail lf.body) }
  | Tupled ->
      let tup = Ident.create_local "tup" in
      let rec bind_fields i = function
        | [] -> conv_tail lf.body
        | (p, vk) :: rest ->
            let kind = if vk = Lambda.Pintval then Immediate_field else Immutable_field in
            Let (p, Field (i, kind, Var tup), bind_fields (i + 1) rest)
      in
      { params = [ (tup, Lambda.Pgenval) ]; return = lf.return; private_entry = false;
        loop_scalars = []; body = with_entry_poll (bind_fields 0 lf.params) }

and conv_bind vk (id : Ident.t) (rhs : Lambda.lambda) (k : unit -> aexpr) : aexpr =
  match rhs with
  | Levent (l, _) | Lifused (_, l) ->
      conv_bind vk id l k
  | Lprim (Psetglobal _, [ l ], _) -> conv_bind vk id l k
  | Llet (_, vk1, id1, arg1, body1) ->
      conv_let vk1 id1 arg1 (fun () -> conv_bind vk id body1 k)
  | Lmutlet (vk1, id1, arg1, body1) ->
      conv_mut_bind vk1 id1 arg1 (fun () -> conv_bind vk id body1 k)
  | Lletrec (bindings, body1) ->
      let rbs =
        List.map
          (fun (rb : Lambda.rec_binding) ->
            { id = rb.id; def = conv_fun rb.def })
          bindings
      in
      LetRec (rbs, conv_bind vk id body1 k)
  | Lsequence (a, b) ->
      conv_sequence a (fun () -> conv_bind vk id b k)
  | Lconst c -> Let (id, Atom (conv_const c), k ())
  | Lvar v -> Let (id, Atom (variable v), k ())
  | Lmutvar v -> conv_mut_read v id k
  | Lfunction lf -> Let (id, Fun (conv_fun lf), k ())
  | Lassign (v, arg) ->
      conv_expr arg (fun a -> Let (id, mut_assignment v a, k ()))
  | Lapply _ | Lprim _ -> (
      match rhs with
      | Lprim (Psequand, _, _)
      | Lprim (Psequor, _, _) ->
          LetJoin (id, conv_tail rhs, k ())
      | _ -> conv_simple ~result_kind:vk id rhs k)
  | Lifthenelse _ | Lswitch _ | Lstringswitch _ | Lstaticcatch _
  | Ltrywith _ ->
      LetJoin (id, conv_tail rhs, k ())
  | Lwhile _ | Lfor _ ->
      conv_expr rhs (fun a -> Let (id, Atom a, k ()))
  | Lstaticraise (i, args) ->
      (* A static raise is a terminator: the binding's continuation is
         unreachable and is dropped, exactly as [conv_expr] does. The
         matcher's tuple-let optimization ([assign_pat]) can leave an
         [Lstaticraise] at the tail of a let chain used as a binding RHS. *)
      conv_atoms args (fun vs -> StaticRaise (i, vs))
  | Lsend _ -> raise (Unsupported (describe rhs))

and conv_let vk id rhs k =
  conv_bind vk id rhs (fun () ->
    if Ident.Map.mem id !module_slots then
      Let (Ident.create_local "publish", StoreModuleSlot (id, Var id), k ())
    else k ())

and conv_sequence action k =
  match action with
  | Lambda.Lprim (Pgetglobal id, [], _) ->
      Let (Ident.create_local "import", ImportDependency (Ident.name id), k ())
  | _ -> conv_expr action (fun _ -> k ())

and conv_mut_bind vk (id : Ident.t) (rhs : Lambda.lambda) (k : unit -> aexpr) :
    aexpr =
  let t = Ident.create_local (Ident.name id ^ "_init") in
  conv_bind vk t rhs (fun () ->
    let init = match Ident.Map.find_opt id !mutable_scalars with
      | None -> Atom (Var t)
      | Some rep -> ScalarValue (rep, Boxed_scalar (Var t))
    in
    MutLet (id, init, k ()))

and conv_mut_read slot id k =
  match Ident.Map.find_opt slot !mutable_scalars with
  | None -> Let (id, Atom (MutVar slot), k ())
  | Some rep ->
      let raw = Ident.create_local "slot_value" in
      Let (raw, ReadScalarSlot (rep, slot),
        Let (id, BoxScalar (rep, Raw_scalar raw), k ()))

and mut_assignment slot value =
  match Ident.Map.find_opt slot !mutable_scalars with
  | None -> Assign (slot, value)
  | Some rep -> AssignScalar (slot, rep, Boxed_scalar value)

and conv_simple ?(result_kind = Lambda.Pgenval) (id : Ident.t)
    (lam : Lambda.lambda) (k : unit -> aexpr) : aexpr =
  let emit_cexpr ce = Let (id, ce, k ()) in
  match lam with
  | Lapply { ap_func; ap_args; ap_inlined; _ } -> (
      let printing, selectors = !builtin_tables in
      let select = Option.bind selectors (fun table -> Builtins.resolve_int_selection table ap_func) in
      match select, ap_args with
      | Some op, [ lhs; rhs ] ->
          conv_expr lhs (fun a ->
              conv_expr rhs (fun b -> emit_cexpr (IntSelect (op, a, b))))
      | _ -> (
          match Option.bind printing (fun table -> Builtins.resolve ~table ap_func) with
          | Some { symbol; arg_kind } -> (
              match ap_args with
              | [ arg ] ->
                  conv_expr arg (fun a -> emit_cexpr (Builtin (symbol, arg_kind, a)))
              | _ -> raise (Unsupported (describe lam)))
          | None -> (
              match imported_callee ap_func with
              | Some target when target.arity = List.length ap_args ->
                  let target =
                    if ap_inlined = Never_inline then { target with inline_leaf = None }
                    else target
                  in
                  conv_atoms ap_args (fun args -> emit_cexpr (DirectApp (target, args)))
              | _ ->
              conv_expr ap_func (fun fn ->
                  conv_atoms ap_args (fun args -> emit_cexpr (App (fn, args)))))))
  | Lprim (Pignore, [ arg ], _) ->
      conv_expr arg (fun _ -> emit_cexpr (Atom Unit))
  | Lprim (Pbytes_to_string, [ arg ], _)
  | Lprim (Pbytes_of_string, [ arg ], _) ->
      conv_expr arg (fun a -> emit_cexpr (Atom a))
  | Lprim (Pmakeblock (tag, _, _), args, _) -> (
      match args with
      | [] -> emit_cexpr (Atom Unit)
      | _ -> conv_atoms args (fun vs -> emit_cexpr (MakeBlock (tag, vs))))
  | Lprim (Pmakelazyblock ltag, [ arg ], _) ->
      let sym =
        match ltag with
        | Lambda.Lazy_tag -> "caml_lazy_make_block"
        | Lambda.Forward_tag -> "caml_lazy_make_forward"
      in
      conv_expr arg (fun av -> emit_cexpr (Ccall (sym, [ av ])))
  | Lprim (Pmakearray (kind, _), args, _) ->
      check_array_kind kind;
      conv_atoms args (fun vs -> emit_cexpr (MakeArray (kind, vs)))
  | Lprim (Pduparray (kind, _), [ Lambda.Lconst (Const_block (_, items)) ], _) ->
      check_array_kind kind;
      emit_cexpr (MakeArray (kind, List.map conv_const items))
  | Lprim (Pduparray (kind, _), [ Lambda.Lconst (Const_float_array sl) ], _) ->
      check_array_kind kind;
      emit_cexpr (MakeArray (kind, List.map (fun s -> Float (parse_const_float s)) sl))
  | Lprim (Pfield (i, repr, mutability), [ arg ], _) ->
      let kind =
        match result_kind, repr, mutability with
        | Lambda.Pintval, _, _ | _, Lambda.Immediate, _ -> Immediate_field
        | _, Pointer, Immutable -> Immutable_field
        | _, Pointer, Mutable -> Mutable_field
      in
      conv_expr arg (fun a -> emit_cexpr (Field (i, kind, a)))
  | Lprim (Pfield_computed, [ arg; idx ], _) ->
      conv_atoms [ arg; idx ] (fun vs ->
          emit_cexpr (Ccall ("caml_obj_field", vs)))
  | Lprim (Psetfield (i, repr, _), [ arg; rhs ], _) ->
      conv_expr arg (fun a ->
          conv_expr rhs (fun v -> emit_cexpr (SetField (i, repr, a, v))))
  | Lprim (Psetfield_computed _, [ arg; idx; rhs ], _) ->
      conv_atoms [ arg; idx; rhs ] (fun vs ->
          emit_cexpr (Ccall ("caml_obj_set_field", vs)))
  | Lprim (Pbigarrayref (unsafe, rank, kind, layout), args, _) ->
      let access = { operation = `Get; rank; kind; layout; checked = not unsafe } in
      conv_atoms args (fun vs -> emit_cexpr (BigarrayAccess (access, vs)))
  | Lprim (Pbigarrayset (unsafe, 1, ((Pbigarray_float32 | Pbigarray_float64) as kind), layout), [arr; index; value], _)
    when scalar_layout layout ->
      let access = { operation = `Set; rank = 1; kind;
                     layout; checked = not unsafe } in
      conv_expr arr (fun a -> conv_expr index (fun i ->
        conv_float_operand value (fun v -> emit_cexpr (ScalarStore (access, a, i, v)))))
  | Lprim (Pbigarrayset (unsafe, 1,
             ((Pbigarray_int32 | Pbigarray_int64 | Pbigarray_native_int) as kind),
             layout), [arr; index; value], _)
    when scalar_layout layout ->
      let access = { operation = `Set; rank = 1; kind;
                     layout; checked = not unsafe } in
      conv_atoms [arr; index; value] (function
        | [a; i; v] -> emit_cexpr (ScalarStore (access, a, i, Boxed_scalar v))
        | _ -> assert false)
  | Lprim (Pbigarrayset (unsafe, rank, kind, layout), args, _) ->
      let access = { operation = `Set; rank; kind; layout; checked = not unsafe } in
      conv_atoms args (fun vs -> emit_cexpr (BigarrayAccess (access, vs)))
  | Lprim (Pbigarraydim d, [ arg ], _) ->
      conv_expr arg (fun a ->
          emit_cexpr (Ccall ("caml_ba_dim", [ a; Int (d - 1) ])))
  | Lprim (Pfloatfield i, [ arg ], _) ->
      conv_expr arg (fun a -> emit_cexpr (FloatField (i, a)))
  | Lprim (Psetfloatfield (i, _), [ arg; rhs ], _) ->
      conv_expr arg (fun a ->
          conv_expr rhs (fun v -> emit_cexpr (SetFloatField (i, a, v))))
  | Lprim (Poffsetref n, [ arg ], _) ->
      conv_expr arg (fun a -> emit_cexpr (OffsetRef (n, a)))
  | Lprim ((Pstringlength | Pbyteslength), [ arg ], _) ->
      conv_expr arg (fun a -> emit_cexpr (Unop (String_length, a)))
  | Lprim ((Pstringrefu | Pbytesrefu), [ s; i ], _) ->
      conv_expr s (fun sa ->
          conv_expr i (fun ia -> emit_cexpr (StringGet (false, sa, ia))))
  | Lprim ((Pstringrefs | Pbytesrefs), [ s; i ], _) ->
      conv_expr s (fun sa ->
          conv_expr i (fun ia -> emit_cexpr (StringGet (true, sa, ia))))
  | Lprim (Pbytessetu, [ s; i; c ], _) ->
      conv_expr s (fun sa ->
          conv_expr i (fun ia ->
              conv_expr c (fun ca -> emit_cexpr (BytesSet (false, sa, ia, ca)))))
  | Lprim (Pbytessets, [ s; i; c ], _) ->
      conv_expr s (fun sa ->
          conv_expr i (fun ia ->
              conv_expr c (fun ca -> emit_cexpr (BytesSet (true, sa, ia, ca)))))
  | Lprim (Parraylength kind, [ arg ], _) ->
      check_array_kind kind;
      conv_expr arg (fun a -> emit_cexpr (Unop (Array_length, a)))
  | Lprim (Parrayrefu kind, [ arr; i ], _) ->
      check_array_kind kind;
      conv_expr arr (fun aa ->
          conv_expr i (fun ia -> emit_cexpr (ArrayGet (false, kind, aa, ia))))
  | Lprim (Parrayrefs kind, [ arr; i ], _) ->
      check_array_kind kind;
      conv_expr arr (fun aa ->
          conv_expr i (fun ia -> emit_cexpr (ArrayGet (true, kind, aa, ia))))
  | Lprim (Parraysetu kind, [ arr; i; v ], _) ->
      check_array_kind kind;
      conv_expr arr (fun aa ->
          conv_expr i (fun ia ->
              conv_expr v (fun va ->
                  emit_cexpr (ArraySet (false, kind, aa, ia, va)))))
  | Lprim (Parraysets kind, [ arr; i; v ], _) ->
      check_array_kind kind;
      conv_expr arr (fun aa ->
          conv_expr i (fun ia ->
              conv_expr v (fun va ->
                  emit_cexpr (ArraySet (true, kind, aa, ia, va)))))
  | Lprim (((Pperform | Prunstack | Presume | Preperform) as prim), args, _) ->
      let symbol =
        match prim with
        | Pperform -> "ocamlcc_effect_perform"
        | Prunstack -> "ocamlcc_effect_runstack"
        | Presume -> "ocamlcc_effect_resume"
        | Preperform -> "ocamlcc_effect_reperform"
        | _ -> assert false
      in
      let abi = Ccalls.find symbol in
      if List.length args <> abi.argc then raise (Unsupported (describe lam));
      conv_atoms args (fun vs -> emit_cexpr (Ccall (symbol, vs)))
  | Lprim (Pccall pd, args, _) -> (
      match (pd.Primitive.prim_name, args) with
      | "caml_create_bytes", [ len ] ->
          conv_expr len (fun la -> emit_cexpr (CreateBytes la))
      | "caml_array_make", [ len; init ] ->
          conv_expr len (fun la ->
              conv_expr init (fun ia -> emit_cexpr (MakeArrayInit (la, ia))))
      | "caml_fresh_oo_id", [ arg ] ->
          conv_expr arg (fun a -> emit_cexpr (Ccall ("caml_fresh_oo_id", [ a ])))
      | ( "caml_string_equal" | "caml_bytes_equal" ), args ->
          conv_atoms args (fun vs -> emit_cexpr (Ccall ("caml_equal", vs)))
      | ( "caml_string_notequal" | "caml_bytes_notequal" ), args ->
          conv_atoms args (fun vs -> emit_cexpr (Ccall ("caml_notequal", vs)))
      | ( "caml_string_compare" | "caml_bytes_compare" ), args ->
          conv_atoms args (fun vs -> emit_cexpr (Ccall ("caml_compare", vs)))
      | ( "caml_string_lessthan" | "caml_bytes_lessthan" ), args ->
          conv_atoms args (fun vs -> emit_cexpr (Ccall ("caml_lessthan", vs)))
      | ( "caml_string_lessequal" | "caml_bytes_lessequal" ), args ->
          conv_atoms args (fun vs -> emit_cexpr (Ccall ("caml_lessequal", vs)))
      | ( "caml_string_greaterthan" | "caml_bytes_greaterthan" ), args ->
          conv_atoms args (fun vs -> emit_cexpr (Ccall ("caml_greaterthan", vs)))
      | ( "caml_string_greaterequal" | "caml_bytes_greaterequal" ), args ->
          conv_atoms args (fun vs -> emit_cexpr (Ccall ("caml_greaterequal", vs)))
      | "caml_restore_raw_backtrace", [ ex; bt ] ->
          conv_expr ex (fun _ -> conv_expr bt (fun _ -> emit_cexpr (Atom (Int 0))))
      | sym, args
        when pd.Primitive.prim_arity = List.length args
             && List.length args <= 6 -> (
          (* C externals: [caml_*] primitives must be registered with their
             C ABI in [Ccalls] (unknown ones are rejected — they are
             compiler/runtime implementation details, not a user ABI);
             registered runtime entries use ocamlcc's boxed ABI.
             User externals use the native entry and its declared ABI. *)
          if String.starts_with ~prefix:"caml_" sym then
            match Ccalls.find_opt sym with
            | Some abi when abi.Ccalls.argc = List.length args ->
                conv_atoms args (fun vs -> emit_cexpr (Ccall (sym, vs)))
            | Some _ ->
                raise
                  (Unsupported
                    (Printf.sprintf "C primitive %s with %d arguments" sym
                       (List.length args)))
            | None -> raise (Unsupported (describe lam))
          else if Ccalls.is_known sym then
            conv_atoms args (fun vs -> emit_cexpr (Ccall (sym, vs)))
          else conv_atoms args (fun vs ->
            let call = NativeCcall (pd, vs) in
            match native_scalar pd.prim_native_repr_res with
            | None -> emit_cexpr call
            | Some rep ->
                let raw = Ident.create_local "native_result" in
                Let (raw, call, emit_cexpr (BoxScalar (rep, Raw_scalar raw)))))
      | _ -> raise (Unsupported (describe lam)))
  | Lprim (Pgetglobal id, [], _) -> emit_cexpr (GetGlobal (Ident.name id))
  | Lprim (Praise _, [ arg ], _) ->
      conv_expr arg (fun a -> Raise a)
  | Lprim (Pisint, [ arg ], _) ->
      conv_expr arg (fun a -> emit_cexpr (Unop (Isint, a)))
  | Lprim (Pnegint, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Neg, av)))
  | Lprim (Pnot, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Not, av)))
  | Lprim (Poffsetint n, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Offset n, av)))
  | Lprim (Paddint, [ a; c ], _) -> binop Add a c emit_cexpr
  | Lprim (Psubint, [ a; c ], _) -> binop Sub a c emit_cexpr
  | Lprim (Pmulint, [ a; c ], _) -> binop Mul a c emit_cexpr
  | Lprim (Pdivint _, [ a; c ], _) -> binop Div a c emit_cexpr
  | Lprim (Pmodint _, [ a; c ], _) -> binop Mod a c emit_cexpr
  | Lprim (Pandint, [ a; c ], _) -> binop And a c emit_cexpr
  | Lprim (Porint, [ a; c ], _) -> binop Or a c emit_cexpr
  | Lprim (Pxorint, [ a; c ], _) -> binop Xor a c emit_cexpr
  | Lprim (Plslint, [ a; c ], _) -> binop Lsl a c emit_cexpr
  | Lprim (Plsrint, [ a; c ], _) -> binop Lsr a c emit_cexpr
  | Lprim (Pasrint, [ a; c ], _) -> binop Asr a c emit_cexpr
  | Lprim (Pintcomp cmp, [ a; c ], _) -> binop (Cmp cmp) a c emit_cexpr
  | Lprim (Pcompare_ints, [ a; c ], _) -> binop Compare_ints a c emit_cexpr
  | Lprim (Pisout, [ a; c ], _) -> binop Isout a c emit_cexpr
  | Lprim (Pfloatofint, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Float_of_int, av)))
  | Lprim (Pintoffloat, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Int_of_float, av)))
  | Lprim (Pnegfloat, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Fneg, av)))
  | Lprim (Pabsfloat, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Fabs, av)))
  | Lprim (((Paddfloat | Psubfloat | Pmulfloat | Pdivfloat) as prim), [ a; c ], _) ->
      binop (Float_arithmetic (float_arithmetic prim)) a c emit_cexpr
  | Lprim (Pfloatcomp cmp, [ a; c ], _) -> binop (Fcmp cmp) a c emit_cexpr
  | Lprim (Pcompare_floats, [ a; c ], _) -> binop Compare_floats a c emit_cexpr
  | Lprim (Pbintofint bi, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Bint_of_int bi, av)))
  | Lprim (Pintofbint bi, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Int_of_bint bi, av)))
  | Lprim (Pcvtbint (src, dst), [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Bint_cvt (src, dst), av)))
  | Lprim (Pnegbint bi, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Unop (Bint_neg bi, av)))
  | Lprim (Paddbint bi, [ a; c ], _) -> binop (Bint_add bi) a c emit_cexpr
  | Lprim (Psubbint bi, [ a; c ], _) -> binop (Bint_sub bi) a c emit_cexpr
  | Lprim (Pmulbint bi, [ a; c ], _) -> binop (Bint_mul bi) a c emit_cexpr
  | Lprim (Pdivbint { size; _ }, [ a; c ], _) ->
      binop (Bint_div size) a c emit_cexpr
  | Lprim (Pmodbint { size; _ }, [ a; c ], _) ->
      binop (Bint_mod size) a c emit_cexpr
  | Lprim (Pandbint bi, [ a; c ], _) -> binop (Bint_and bi) a c emit_cexpr
  | Lprim (Porbint bi, [ a; c ], _) -> binop (Bint_or bi) a c emit_cexpr
  | Lprim (Pxorbint bi, [ a; c ], _) -> binop (Bint_xor bi) a c emit_cexpr
  | Lprim (Plslbint bi, [ a; c ], _) -> binop (Bint_lsl bi) a c emit_cexpr
  | Lprim (Plsrbint bi, [ a; c ], _) -> binop (Bint_lsr bi) a c emit_cexpr
  | Lprim (Pasrbint bi, [ a; c ], _) -> binop (Bint_asr bi) a c emit_cexpr
  | Lprim (Pbintcomp (bi, cmp), [ a; c ], _) ->
      binop (Bint_cmp (bi, cmp)) a c emit_cexpr
  | Lprim (Pcompare_bints bi, [ a; c ], _) ->
      binop (Compare_bints bi) a c emit_cexpr
  | Lprim (Patomic_load, [ ptr; idx ], _) ->
      conv_atoms [ ptr; idx ] (fun vs ->
          emit_cexpr (Ccall ("caml_atomic_load_field", vs)))
  | Lprim (Patomic_load, [ ptr ], _) ->
      conv_expr ptr (fun p ->
          emit_cexpr (Ccall ("caml_atomic_load_field", [ p; Int 0 ])))
  | Lprim (Pbswap16, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (Bswap16 av))
  | Lprim (Pbbswap bi, [ a ], _) ->
      conv_expr a (fun av -> emit_cexpr (BswapBint (bi, av)))
  | Lprim ((Pstring_load_16 unsafe | Pbytes_load_16 unsafe), [ s; i ], _) ->
      conv_atoms [ s; i ] (function
        | [ sa; ia ] -> emit_cexpr (BytesGetN (not unsafe, 2, sa, ia))
        | _ -> assert false)
  | Lprim ((Pstring_load_32 unsafe | Pbytes_load_32 unsafe), [ s; i ], _) ->
      conv_atoms [ s; i ] (function
        | [ sa; ia ] -> emit_cexpr (BytesGetN (not unsafe, 4, sa, ia))
        | _ -> assert false)
  | Lprim ((Pstring_load_64 unsafe | Pbytes_load_64 unsafe), [ s; i ], _) ->
      conv_atoms [ s; i ] (function
        | [ sa; ia ] -> emit_cexpr (BytesGetN (not unsafe, 8, sa, ia))
        | _ -> assert false)
  | Lprim (Pbytes_set_16 unsafe, [ b; i; v ], _) ->
      conv_atoms [ b; i; v ] (function
        | [ ba; ia; va ] -> emit_cexpr (BytesSetN (not unsafe, 2, ba, ia, va))
        | _ -> assert false)
  | Lprim (Pbytes_set_32 unsafe, [ b; i; v ], _) ->
      conv_atoms [ b; i; v ] (function
        | [ ba; ia; va ] -> emit_cexpr (BytesSetN (not unsafe, 4, ba, ia, va))
        | _ -> assert false)
  | Lprim (Pbytes_set_64 unsafe, [ b; i; v ], _) ->
      conv_atoms [ b; i; v ] (function
        | [ ba; ia; va ] -> emit_cexpr (BytesSetN (not unsafe, 8, ba, ia, va))
        | _ -> assert false)
  | Lprim (Pctconst c, _, _) ->
      let atom =
        match c with
        | Big_endian -> Int (if Sys.big_endian then 1 else 0)
        | Word_size -> Int 64
        | Int_size -> Int 63
        | Max_wosize -> Int ((1 lsl 29) - 1)
        | Ostype_unix -> Int (if Sys.win32 then 0 else 1)
        | Ostype_win32 -> Int (if Sys.win32 then 1 else 0)
        | Ostype_cygwin -> Int 0
        | Backend_type -> Int 0
        | Standard_library_default -> String ""
      in
      emit_cexpr (Atom atom)
  | Lprim (Popaque, [arg], _) ->
      conv_expr arg (fun value -> emit_cexpr (Ccall ("ocamlcc_opaque_identity", [value])))
  | Lprim (Ppoll, _, _) -> with_finalizer_poll (emit_cexpr (Atom Unit))
  | _ -> raise (Unsupported (describe lam))

(* A typed store demands a double. Propagate that demand only into local
   scalar expressions. Every other expression uses the ordinary value ABI. *)
and conv_float_operand lam k =
  let bind ce =
    let id = Ident.create_local "scalar" in
    Let (id, ce, k (Raw_scalar id))
  in
  match lam with
  | Lambda.Lprim (Pbigarrayref (unsafe, 1, ((Pbigarray_float32 | Pbigarray_float64) as kind), layout), [arr; index], _)
    when scalar_layout layout ->
      let access = { operation = `Get; rank = 1; kind;
                     layout; checked = not unsafe } in
      conv_expr arr (fun a -> conv_expr index (fun i -> bind (ScalarLoad (access, a, i))))
  | Lprim (((Paddfloat | Psubfloat | Pmulfloat | Pdivfloat) as prim), [lhs; rhs], _) ->
      conv_float_operand lhs (fun l ->
          conv_float_operand rhs (fun r -> bind (FloatBinop (float_arithmetic prim, l, r))))
  | Lifthenelse (cond, yes, no) ->
      conv_expr cond (fun cond ->
          let id = Ident.create_local "scalar_join" in
          let branches = ScalarIf (Double_scalar, cond, conv_float_tail yes, conv_float_tail no) in
          LetJoin (id, branches, k (Raw_scalar id)))
  | _ -> conv_expr lam (fun a -> k (Boxed_scalar a))

and conv_float_tail lam =
  conv_float_operand lam (function
    | Raw_scalar id -> HaltScalar id
    | Boxed_scalar value ->
        let id = Ident.create_local "scalar" in
        Let (id, ScalarValue (Double_scalar, Boxed_scalar value), HaltScalar id))

and binop op a c emit_cexpr =
  conv_expr a (fun av -> conv_expr c (fun cv -> emit_cexpr (Binop (op, av, cv))))

and conv_expr (lam : Lambda.lambda) (k : atom -> aexpr) : aexpr =
  match lam with
  | Lconst c -> k (conv_const c)
  | Lvar id -> k (variable id)
  | Lmutvar slot ->
      (match Ident.Map.find_opt slot !mutable_scalars with
      | None -> k (MutVar slot)
      | Some _ ->
          let id = Ident.create_local "slot_read" in
          conv_mut_read slot id (fun () -> k (Var id)))
  | Levent (l, _) | Lifused (_, l) ->
      conv_expr l k
  | Lprim (Psetglobal _, [ body ], _) -> conv_expr body k
  | Llet (_, vk, id, arg, body) ->
      conv_let vk id arg (fun () -> conv_expr body k)
  | Lmutlet (vk, id, arg, body) ->
      conv_mut_bind vk id arg (fun () -> conv_expr body k)
  | Lletrec (bindings, body) ->
      let rbs =
        List.map
          (fun (rb : Lambda.rec_binding) ->
            { id = rb.id; def = conv_fun rb.def })
          bindings
      in
      LetRec (rbs, conv_expr body k)
  | Lsequence (a, b) -> conv_sequence a (fun () -> conv_expr b k)
  | Lfunction lf ->
      let id = Ident.create_local "anon" in
      Let (id, Fun (conv_fun lf), k (Var id))
  | Lassign (id, rhs) ->
      let t = Ident.create_local "assign" in
      conv_expr rhs (fun a -> Let (t, mut_assignment id a, k (Var t)))
  | Lprim (Psequand, [ a; b ], _) ->
      let e =
        conv_expr a (fun ca -> If (ca, conv_tail b, Halt (Int 0)))
      in
      wrap_or_tail e k
  | Lprim (Psequor, [ a; b ], _) ->
      let e =
        conv_expr a (fun ca -> If (ca, Halt (Int 1), conv_tail b))
      in
      wrap_or_tail e k
  | Lifthenelse (cond, th, el) ->
      let e =
        conv_expr cond (fun ca -> If (ca, conv_tail th, conv_tail el))
      in
      wrap_or_tail e k
  | Lswitch (scrut, sw, _) ->
      let e =
        conv_expr scrut (fun sa ->
            Switch
              ( sa,
                { result_rep = None;
                  consts = List.map (fun (n, arm) -> (n, conv_tail arm)) sw.sw_consts;
                  blocks =
                    List.map (fun (t, arm) -> (t, conv_tail arm)) sw.sw_blocks;
                  fail = Option.map conv_tail sw.sw_failaction } ))
      in
      wrap_or_tail e k
  | Lstringswitch (scrut, cases, fail, _) ->
      let e =
        conv_expr scrut (fun sa ->
            StringSwitch
              ( sa,
                List.map (fun (s, arm) -> (s, conv_tail arm)) cases,
                Option.map conv_tail fail ))
      in
      wrap_or_tail e k
  | Lstaticcatch (body, (id, binders), handler) ->
      let e =
        StaticCatch
          (conv_tail body, id, List.map fst binders, conv_tail handler, None)
      in
      wrap_or_tail e k
  | Lstaticraise (id, args) ->
      conv_atoms args (fun vs -> StaticRaise (id, vs))
  | Ltrywith (body, exn_id, handler) ->
      let e = TryWith (conv_tail body, exn_id, conv_tail handler) in
      wrap_or_tail e k
  | Lwhile (cond, body) ->
      seq_stmt (while_with_poll (conv_tail cond) (conv_tail body)) (k Unit)
  | Lfor (id, start_e, stop_e, dir, body) ->
      conv_expr start_e (fun sa ->
          conv_expr stop_e (fun ea ->
              seq_stmt (For (id, sa, ea, dir, with_counted_loop_poll id sa (conv_tail body))) (k Unit)))
  | Lapply _ | Lprim _ ->
      let id = Ident.create_local "anf" in
      conv_simple id lam (fun () -> k (Var id))
  | Lsend _ -> raise (Unsupported (describe lam))

and wrap_or_tail e k =
  (* Avoid duplicating continuations across branches: only inline [Halt]. *)
  let id = Ident.create_local "join" in
  match k (Var id) with
  | Halt (Var v) when Ident.same v id -> e
  | cont -> LetJoin (id, e, cont)

and seq_stmt (stmt : aexpr) (next : aexpr) : aexpr =
  let id = Ident.create_local "seq" in
  LetJoin (id, stmt, next)

(* ------------------------------------------------------------------ *)
(* Free variables                                                      *)
(* ------------------------------------------------------------------ *)

let rec atom_vars acc = function
  | Var id | MutVar id -> Ident.Set.add id acc
  | BorrowedField (_, owner) -> atom_vars acc owner
  | Int _ | Char _ | String _ | Float _ | Int32 _ | Int64 _ | Nativeint _
  | ConstFloatArray _ | ConstBlock _ | Unit | ModuleSlot _ ->
      acc

let scalar_operand_vars acc = function
  | Boxed_scalar a -> atom_vars acc a
  | Raw_scalar id -> Ident.Set.add id acc

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
  | Binop (_, a, b) | IntSelect (_, a, b) -> atom_vars (atom_vars acc a) b
  | Unop (_, a) -> atom_vars acc a
  | MakeBlock (_, args) | MakeArray (_, args) ->
      List.fold_left atom_vars acc args
  | AllocReuse (reuse, _, args) ->
      let acc = Ident.Set.add reuse.primary (List.fold_left atom_vars acc args) in
      Option.fold ~none:acc ~some:(fun id -> Ident.Set.add id acc) reuse.fallback
  | Field (_, _, a) | FloatField (_, a) | OffsetRef (_, a) | CreateBytes a
  | Bswap16 a | BswapBint (_, a) ->
      atom_vars acc a
  | SetField (_, _, a, b)
  | SetFloatField (_, a, b)
  | StringGet (_, a, b)
  | BytesGetN (_, _, a, b)
  | ArrayGet (_, _, a, b)
  | MakeArrayInit (a, b) ->
      atom_vars (atom_vars acc a) b
  | BytesSet (_, a, b, c) | BytesSetN (_, _, a, b, c) | ArraySet (_, _, a, b, c) ->
      atom_vars (atom_vars (atom_vars acc a) b) c
  | App (fn, args) ->
      List.fold_left atom_vars (atom_vars acc fn) args
  | Builtin (_, _, a) -> atom_vars acc a
  | StoreModuleSlot (_, a) -> atom_vars acc a
  | BigarrayAccess (_, args) | Ccall (_, args) | NativeCcall (_, args)
  | DirectApp (_, args) | Recur args | KeepAlive args ->
      List.fold_left atom_vars acc args
  | GetGlobal _ | ImportDependency _ -> acc
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

type scalar_binding = Value of cexpr | Join of aexpr

let rec boxed_branch = function
  | Let (_, _, body) -> boxed_branch body
  | If _ | Switch (_, { result_rep = None; _ }) | StaticCatch (_, _, _, _, None) -> true
  | _ -> false

(* Conditional tests may bind temporaries before the branch itself. *)
let rec returns_scalar = function
  | Let (_, _, body) -> returns_scalar body
  | ScalarIf _ | Switch (_, { result_rep = Some _; _ })
  | StaticCatch (_, _, _, _, Some _) -> true
  | _ -> false

let bind_scalar_chain id binding body =
  match binding with
  | Value ce -> Let (id, ce, body)
  | Join rhs -> LetJoin (id, rhs, body)

let raw_boxed_arithmetic op lhs rhs =
  let binary kind op = Some (Integer_scalar kind, IntegerBinop (kind, op, lhs, Boxed_scalar rhs)) in
  let shift kind op = Some (Integer_scalar kind, IntegerShift (kind, op, lhs, rhs)) in
  match op with
  | Bint_add k -> binary k Add_int
  | Bint_sub k -> binary k Sub_int
  | Bint_mul k -> binary k Mul_int
  | Bint_div k -> binary k Div_int
  | Bint_mod k -> binary k Rem_int
  | Bint_and k -> binary k And_int
  | Bint_or k -> binary k Or_int
  | Bint_xor k -> binary k Xor_int
  | Bint_lsl k -> shift k Left_shift
  | Bint_lsr k -> shift k Logical_right
  | Bint_asr k -> shift k Arithmetic_right
  | _ -> None

let raw_producer = function
  | ArrayGet (safe, Lambda.Pfloatarray, arr, index) ->
      Some (Double_scalar, FloatArrayGet (safe, arr, index))
  | Binop (Float_arithmetic op, lhs, rhs) ->
      Some (Double_scalar, FloatBinop (op, Boxed_scalar lhs, Boxed_scalar rhs))
  | Binop (op, lhs, rhs) -> raw_boxed_arithmetic op (Boxed_scalar lhs) rhs
  | Unop (Float_of_int, value) -> Some (Double_scalar, FloatOfInt value)
  | Unop ((Fneg | Fabs as op), value) ->
      let op = match op with Fneg -> `Neg | _ -> `Abs in
      Some (Double_scalar, FloatSign (op, Boxed_scalar value))
  | Unop (Bint_of_int kind, value) ->
      Some (Integer_scalar kind, IntegerOfInt (kind, value))
  | Unop (Bint_cvt (src, dst), value) ->
      Some (Integer_scalar dst, IntegerConvert (src, dst, Boxed_scalar value))
  | Unop (Bint_neg kind, value) ->
      Some (Integer_scalar kind, IntegerNeg (kind, Boxed_scalar value))
  | _ -> None

let collect_scalar_binding id ce bindings =
  match raw_producer ce with
  | Some (rep, producer) ->
      let raw = Ident.create_local "scalar" in
      (id, Value (BoxScalar (rep, Raw_scalar raw))) :: (raw, Value producer) :: bindings
  | None ->
      let ce =
        match ce with
        | Unop (Int_of_bint kind, value) -> IntOfInteger (kind, Boxed_scalar value)
        | Unop (Int_of_float, value) -> IntOfFloat (Boxed_scalar value)
        | Binop (Bint_cmp (kind, cmp), lhs, rhs) ->
            IntegerCompare (kind, Predicate cmp, Boxed_scalar lhs, Boxed_scalar rhs)
        | Binop (Compare_bints kind, lhs, rhs) ->
            IntegerCompare (kind, Three_way, Boxed_scalar lhs, Boxed_scalar rhs)
        | Binop (Fcmp cmp, lhs, rhs) -> FloatCompare (cmp, Boxed_scalar lhs, Boxed_scalar rhs)
        | ArraySet (safe, Lambda.Pfloatarray, arr, index, value) ->
            FloatArraySet (safe, arr, index, Boxed_scalar value)
        | _ -> ce
      in
      (id, Value ce) :: bindings

(* Walk backwards from scalar consumers. Uses that cross a control-flow
   boundary or need an OCaml value keep the binding boxed. Conflicting
   scalar representations are recorded as a present demand with no choice. *)
let rec specialize_scalar_chain bindings tail =
  let demand rep vars = function
    | Boxed_scalar (Var id) ->
        Ident.Map.update id (function
          | None -> Some (Some rep)
          | Some previous -> Some (if previous = Some rep then previous else None)) vars
    | Boxed_scalar _ | Raw_scalar _ -> vars
  in
  let select (boxed, scalar, raw, code) (id, binding) =
    let wanted =
      if Ident.Set.mem id boxed then None
      else Option.join (Ident.Map.find_opt id scalar)
    in
    let binding, raw =
      match wanted, binding with
      | Some rep, Value (BoxScalar (actual, value)) when rep = actual ->
          Value (ScalarValue (rep, value)), Ident.Set.add id raw
      | Some rep, Value (Atom value) ->
          Value (ScalarValue (rep, Boxed_scalar value)), Ident.Set.add id raw
      | Some rep, Value (BigarrayAccess
          (({ operation = `Get; rank = 1; kind; layout; _ } as access), [arr; index]))
        when scalar_layout layout && scalar_rep kind = Some rep ->
          Value (ScalarLoad (access, arr, index)), Ident.Set.add id raw
      | Some rep, Join rhs ->
          Join (specialize_branch rep rhs), Ident.Set.add id raw
      | _ -> binding, raw
    in
    let boxed = Ident.Set.remove id boxed and scalar = Ident.Map.remove id scalar in
    let boxed, scalar =
      match binding with
      | Value (AssignScalar (slot, rep, value)) ->
          Ident.Set.add slot boxed, demand rep scalar value
      | Value (ScalarStore (access, arr, index, v)) ->
          let rep = Option.get (scalar_rep access.kind) in
          atom_vars (atom_vars boxed arr) index, demand rep scalar v
      | Value (FloatArraySet (_, arr, index, v)) ->
          atom_vars (atom_vars boxed arr) index, demand Double_scalar scalar v
      | Value (FloatBinop (_, lhs, rhs) | FloatCompare (_, lhs, rhs)) ->
          boxed, demand Double_scalar (demand Double_scalar scalar lhs) rhs
      | Value (IntOfFloat value | FloatSign (_, value)) ->
          boxed, demand Double_scalar scalar value
      | Value (IntegerBinop (kind, _, lhs, rhs) | IntegerCompare (kind, _, lhs, rhs)) ->
          let rep = Integer_scalar kind in
          boxed, demand rep (demand rep scalar lhs) rhs
      | Value (IntegerNeg (kind, value) | IntOfInteger (kind, value)
               | IntegerConvert (kind, _, value)) ->
          boxed, demand (Integer_scalar kind) scalar value
      | Value (IntegerShift (kind, _, value, count)) ->
          atom_vars boxed count, demand (Integer_scalar kind) scalar value
      | Value (ScalarValue (rep, value) | BoxScalar (rep, value)) ->
          boxed, demand rep scalar value
      | Value ce -> cexpr_vars free_vars boxed ce, scalar
      | Join rhs -> Ident.Set.union boxed (free_vars rhs), scalar
    in
    boxed, scalar, raw, (id, binding) :: code
  in
  let _, _, raw, code =
    List.fold_left select (free_vars tail, Ident.Map.empty, Ident.Set.empty, []) bindings
  in
  let operand = function
    | Boxed_scalar (Var id) when Ident.Set.mem id raw -> Raw_scalar id
    | v -> v
  in
  List.fold_right (fun (id, binding) body ->
    let binding =
      match binding with
      | Value (AssignScalar (slot, rep, value)) ->
          Value (AssignScalar (slot, rep, operand value))
      | Value (ScalarStore (access, arr, index, v)) ->
          Value (ScalarStore (access, arr, index, operand v))
      | Value (FloatBinop (op, lhs, rhs)) -> Value (FloatBinop (op, operand lhs, operand rhs))
      | Value (FloatCompare (op, lhs, rhs)) -> Value (FloatCompare (op, operand lhs, operand rhs))
      | Value (FloatArraySet (safe, arr, index, value)) ->
          Value (FloatArraySet (safe, arr, index, operand value))
      | Value (IntOfFloat value) -> Value (IntOfFloat (operand value))
      | Value (FloatSign (op, value)) -> Value (FloatSign (op, operand value))
      | Value (BoxScalar (rep, value)) -> Value (BoxScalar (rep, operand value))
      | Value (IntegerBinop (kind, op, lhs, rhs)) ->
          Value (IntegerBinop (kind, op, operand lhs, operand rhs))
      | Value (IntegerCompare (kind, op, lhs, rhs)) ->
          Value (IntegerCompare (kind, op, operand lhs, operand rhs))
      | Value (IntOfInteger (kind, value)) -> Value (IntOfInteger (kind, operand value))
      | Value (IntegerConvert (src, dst, value)) ->
          Value (IntegerConvert (src, dst, operand value))
      | Value (IntegerNeg (kind, value)) -> Value (IntegerNeg (kind, operand value))
      | Value (IntegerShift (kind, op, value, count)) ->
          Value (IntegerShift (kind, op, operand value, count))
      | Value (ScalarValue (rep, v)) -> Value (ScalarValue (rep, operand v))
      | _ -> binding
    in
    bind_scalar_chain id binding body) code tail

and specialize_branch rep = function
  | Let (id, ce, body) -> Let (id, ce, specialize_branch rep body)
  | If (cond, yes, no) ->
      ScalarIf (rep, cond, specialize_scalar_arm rep [] yes, specialize_scalar_arm rep [] no)
  | Switch (scrutinee, cases) ->
      let arm (tag, body) = tag, specialize_scalar_arm rep [] body in
      Switch (scrutinee,
              { result_rep = Some rep;
                consts = List.map arm cases.consts;
                blocks = List.map arm cases.blocks;
                fail = Option.map (specialize_scalar_arm rep []) cases.fail })
  | StaticCatch (body, label, params, handler, _) ->
      StaticCatch (specialize_scalar_arm rep [] body, label, params,
                   specialize_scalar_arm rep [] handler, Some rep)
  | _ -> assert false

and specialize_scalar_arm rep bindings = function
  | Let (id, ce, body) -> specialize_scalar_arm rep (collect_scalar_binding id ce bindings) body
  | LetJoin (id, rhs, body) when boxed_branch rhs ->
      specialize_scalar_arm rep ((id, Join rhs) :: bindings) body
  | Halt value ->
      let id = Ident.create_local "scalar" in
      let bindings = (id, Value (ScalarValue (rep, Boxed_scalar value))) :: bindings in
      specialize_scalar_chain bindings (HaltScalar id)
  | (StaticRaise _ | Raise _) as exit -> specialize_scalar_chain bindings exit
  | branch when boxed_branch branch ->
      let id = Ident.create_local "scalar" in
      let tail = LetJoin (id, specialize_branch rep branch, HaltScalar id) in
      specialize_scalar_chain bindings tail
  | expr ->
      (* A complex arm computes an ordinary OCaml value before unboxing. *)
      let boxed = Ident.create_local "boxed_arm" in
      let raw = Ident.create_local "scalar" in
      let tail = LetJoin (boxed, expr,
                          Let (raw, ScalarValue (rep, Boxed_scalar (Var boxed)), HaltScalar raw)) in
      specialize_scalar_chain bindings tail

(* A raw backedge is only emitted when every occurrence of the function
   rewrites to a jump and the selected inputs have exclusively scalar uses.
   The public entry and all results use the ordinary boxed calling convention. *)
let map_loop_children visit ~tail = function
  | Let (id, ce, body) -> Let (id, ce, visit ~tail body)
  | MutLet (id, ce, body) -> MutLet (id, ce, visit ~tail body)
  | LetJoin (id, rhs, body) -> LetJoin (id, visit ~tail:false rhs, visit ~tail body)
  | LetRec (defs, body) -> LetRec (defs, visit ~tail body)
  | If (cond, yes, no) -> If (cond, visit ~tail yes, visit ~tail no)
  | ScalarIf (rep, cond, yes, no) ->
      ScalarIf (rep, cond, visit ~tail:false yes, visit ~tail:false no)
  | Switch (value, cases) ->
      let arm (tag, body) = tag, visit ~tail body in
      Switch (value, { cases with consts = List.map arm cases.consts;
                                  blocks = List.map arm cases.blocks;
                                  fail = Option.map (visit ~tail) cases.fail })
  | StringSwitch (value, cases, fail) ->
      StringSwitch (value, List.map (fun (tag, body) -> tag, visit ~tail body) cases,
                    Option.map (visit ~tail) fail)
  | StaticCatch (body, label, params, handler, rep) ->
      let tail = tail && Option.is_none rep in
      StaticCatch (visit ~tail body, label, params, visit ~tail handler, rep)
  | TryWith (body, exn, handler) ->
      TryWith (visit ~tail:false body, exn, visit ~tail:false handler)
  | While (cond, body) -> While (visit ~tail:false cond, visit ~tail:false body)
  | For (id, start, stop, dir, body) -> For (id, start, stop, dir, visit ~tail:false body)
  | expr -> expr

let scalarize_loop specialize (rb : rec_binding) =
  let lf = rb.def in
  let reps =
    List.map (fun (_, kind) ->
      match kind with
      | Lambda.Pfloatval -> Some Double_scalar
      | Pboxedintval kind -> Some (Integer_scalar kind)
      | _ -> None) lf.params
  in
  let loop_scalars =
    List.filter_map Fun.id
      (List.map2 (fun (id, _) rep ->
        Option.map (fun rep -> id, (rep, Ident.create_local "loop_box")) rep) lf.params reps)
  in
  if loop_scalars = [] || not (Ident.Set.mem rb.id (free_vars lf.body)) then None
  else
    let exception Boxed_use in
    let raw_ids = Ident.Set.of_list (List.map fst loop_scalars) in
    let raw_rep id = Option.map fst (List.assoc_opt id loop_scalars) in
    let owners = List.map (fun (_, (_, owner)) -> Var owner) loop_scalars in
    let keep_alive body = Let (Ident.create_local "keep", KeepAlive owners, body) in
    let found = ref false in
    let rec prepare ~tail expr =
      match expr with
      | Let (id, App (Var fn, args), Halt (Var result))
        when tail && Ident.same rb.id fn && Ident.same id result
             && List.length args = List.length reps ->
          found := true;
          let args = List.map2 (fun rep arg ->
            match rep with
            | None -> arg, None
            | Some rep ->
                let raw = Ident.create_local "loop_scalar" in
                Var raw, Some (raw, ScalarValue (rep, Boxed_scalar arg))) reps args
          in
          List.fold_right (fun (_, binding) body ->
            match binding with
            | None -> body
            | Some (raw, ce) -> Let (raw, ce, body))
            args (Let (id, Recur (List.map fst args), Halt (Var result)))
      | Halt (Var id) when tail ->
          keep_alive (match List.assoc_opt id loop_scalars with
          | None -> expr
          | Some (rep, owner) ->
              let boxed = Ident.create_local "loop_result" in
              If (Var owner, Halt (Var owner),
                  Let (boxed, BoxScalar (rep, Raw_scalar id), Halt (Var boxed))))
      | Halt _ when tail -> keep_alive expr
      | expr -> map_loop_children prepare ~tail expr
    in
    let scalar_operand rep = function
      | Boxed_scalar (Var id) when raw_rep id = Some rep -> Raw_scalar id
      | operand -> operand
    in
    let float = scalar_operand Double_scalar in
    let int kind = scalar_operand (Integer_scalar kind) in
    let check_ids uses =
      if not (Ident.Set.disjoint raw_ids uses) then raise Boxed_use
    in
    let check_atom value = check_ids (atom_vars Ident.Set.empty value) in
    let rewrite_ce ce =
      let ce =
        match ce with
        | ScalarValue (rep, value) -> ScalarValue (rep, scalar_operand rep value)
        | AssignScalar (slot, rep, value) ->
            AssignScalar (slot, rep, scalar_operand rep value)
        | BoxScalar (rep, value) -> BoxScalar (rep, scalar_operand rep value)
        | FloatBinop (op, lhs, rhs) -> FloatBinop (op, float lhs, float rhs)
        | FloatCompare (op, lhs, rhs) -> FloatCompare (op, float lhs, float rhs)
        | FloatSign (op, value) -> FloatSign (op, float value)
        | IntOfFloat value -> IntOfFloat (float value)
        | FloatArraySet (safe, arr, index, value) -> FloatArraySet (safe, arr, index, float value)
        | ScalarStore (access, arr, index, value) ->
            let rep = Option.get (scalar_rep access.kind) in
            ScalarStore (access, arr, index, scalar_operand rep value)
        | IntegerBinop (kind, op, lhs, rhs) ->
            IntegerBinop (kind, op, int kind lhs, int kind rhs)
        | IntegerCompare (kind, op, lhs, rhs) ->
            IntegerCompare (kind, op, int kind lhs, int kind rhs)
        | IntOfInteger (kind, value) -> IntOfInteger (kind, int kind value)
        | IntegerConvert (src, dst, value) -> IntegerConvert (src, dst, int src value)
        | IntegerNeg (kind, value) -> IntegerNeg (kind, int kind value)
        | IntegerShift (kind, op, value, count) -> IntegerShift (kind, op, int kind value, count)
        | ce -> ce
      in
      check_ids (cexpr_vars ~include_raw:false free_vars Ident.Set.empty ce);
      ce
    in
    (* The scalar pass has decided whether a backedge input still has an
       observable box. Keep that box as an owner when present. *)
    let boxes = Hashtbl.create 8 in
    let box_for_operand = function
      | Boxed_scalar value -> Some value
      | Raw_scalar value ->
          (match List.assoc_opt value loop_scalars with
          | Some (_, owner) -> Some (Var owner)
          | None -> Option.value ~default:(Some Unit) (Hashtbl.find_opt boxes value))
    in
    let rec validate ~tail expr =
      match expr with
      | Let (id, Recur args, body) ->
          List.iter check_atom args;
          let backedge_boxes =
            List.filter_map Fun.id (List.map2 (fun rep arg ->
              match rep, arg with
              | None, _ -> None
              | Some _, Var arg ->
                  (match Hashtbl.find boxes arg with
                  | Some value -> Some value
                  | None -> raise Boxed_use)
              | Some _, _ -> assert false) reps args)
          in
          keep_alive (Let (id, Recur (args @ backedge_boxes), body))
      | Let (id, ce, body) ->
          let ce = rewrite_ce ce in
          (match ce with
          | ScalarValue (_, value) -> Hashtbl.add boxes id (box_for_operand value)
          | _ -> ());
          Let (id, ce, validate ~tail body)
      | LetJoin (id, rhs, body) when returns_scalar rhs ->
          Hashtbl.add boxes id None;
          LetJoin (id, validate ~tail:false rhs, validate ~tail body)
      | MutLet (id, ce, body) -> MutLet (id, rewrite_ce ce, validate ~tail body)
      | expr ->
          (match expr with
          | Halt value | Raise value | If (value, _, _) | ScalarIf (_, value, _, _)
          | Switch (value, _) | StringSwitch (value, _, _) -> check_atom value
          | StaticRaise (_, args) -> List.iter check_atom args
          | For (_, first, last, _, _) -> List.iter check_atom [first; last]
          | LetRec (defs, _) ->
              List.iter (fun (rb : rec_binding) -> check_ids (free_vars rb.def.body)) defs
          | _ -> ());
          map_loop_children validate ~tail expr
    in
    let body = prepare ~tail:true lf.body in
    if not !found || Ident.Set.mem rb.id (free_vars body) then None
    else
      match validate ~tail:true (specialize body) with
      | body -> Some { lf with body; loop_scalars }
      | exception Boxed_use -> None

let rec specialize_scalar_bindings = function
  | Let _ as expr -> specialize_let_chain [] expr
  | LetJoin (_, rhs, _) as expr when boxed_branch rhs ->
      specialize_let_chain [] expr
  | MutLet (id, ce, body) ->
      MutLet (id, ce, specialize_scalar_bindings body)
  | LetJoin (id, rhs, body) ->
      LetJoin (id, specialize_scalar_bindings rhs, specialize_scalar_bindings body)
  | LetRec (defs, body) ->
      let defs =
        match defs with
        | [rb] ->
            let def = match scalarize_loop specialize_scalar_bindings rb with
              | Some def -> def
              | None -> specialize_scalar_function rb.def
            in
            [{ rb with def }]
        | _ -> List.map (fun rb -> { rb with def = specialize_scalar_function rb.def }) defs
      in
      LetRec (defs, specialize_scalar_bindings body)
  | If (v, yes, no) ->
      If (v, specialize_scalar_bindings yes, specialize_scalar_bindings no)
  | ScalarIf (rep, v, yes, no) ->
      ScalarIf (rep, v, specialize_scalar_bindings yes, specialize_scalar_bindings no)
  | Switch (v, cases) ->
      Switch (v, { cases with consts = List.map specialize_scalar_case cases.consts;
                   blocks = List.map specialize_scalar_case cases.blocks;
                   fail = Option.map specialize_scalar_bindings cases.fail })
  | StringSwitch (v, cases, fail) ->
      StringSwitch (v, List.map specialize_scalar_case cases,
                    Option.map specialize_scalar_bindings fail)
  | StaticCatch (body, label, params, handler, result_rep) ->
      StaticCatch (specialize_scalar_bindings body, label, params,
                   specialize_scalar_bindings handler, result_rep)
  | TryWith (body, exn, handler) ->
      TryWith (specialize_scalar_bindings body, exn, specialize_scalar_bindings handler)
  | While (cond, body) ->
      While (specialize_scalar_bindings cond, specialize_scalar_bindings body)
  | For (id, start, stop, dir, body) ->
      For (id, start, stop, dir, specialize_scalar_bindings body)
  | expr -> expr

and specialize_let_chain bindings = function
  | Let (id, ce, body) ->
      let ce = match ce with Fun lf -> Fun (specialize_scalar_function lf) | _ -> ce in
      specialize_let_chain (collect_scalar_binding id ce bindings) body
  | LetJoin (id, rhs, body) when boxed_branch rhs ->
      let rhs = specialize_scalar_bindings rhs in
      specialize_let_chain ((id, Join rhs) :: bindings) body
  | tail ->
      let tail = specialize_scalar_bindings tail in
      if List.exists (function
        | _, Value (BoxScalar _ | AssignScalar _ | ScalarStore _ | FloatBinop _ | IntegerBinop _
                   | ScalarValue _ | IntegerCompare _ | IntOfInteger _
                   | FloatCompare _ | IntOfFloat _ | FloatArraySet _) -> true
        | _ -> false) bindings
      then specialize_scalar_chain bindings tail
      else List.fold_left (fun body (id, binding) -> bind_scalar_chain id binding body) tail bindings

and specialize_scalar_function lf =
  { lf with body = specialize_scalar_bindings lf.body }

and specialize_scalar_case : 'a. 'a * aexpr -> 'a * aexpr =
  fun (tag, arm) -> tag, specialize_scalar_bindings arm

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

(* Drop zero-occurrence [Alias] and [StrictOpt] let bindings before ANF
   lowering. [Matching] shares catch arms across constructors with different
   field arities and emits [Llet (Alias, _, w, Pfield i p, body)] for unused
   wildcard bindings; per [lambda.mli], 0-occurrence [Alias] / [StrictOpt]
   bindings must be discarded rather than evaluated out of bounds. *)
let drop_unused_alias_lets (lam : Lambda.lambda) : Lambda.lambda =
  let rec go (lam : Lambda.lambda) : Lambda.lambda * Ident.Set.t =
    match lam with
    | Lambda.Lvar id | Lambda.Lmutvar id -> (lam, Ident.Set.singleton id)
    | Lambda.Lconst _ -> (lam, Ident.Set.empty)
    | Lambda.Llet (((Lambda.Alias | Lambda.StrictOpt) as kind), vk, id, arg, body) ->
        let body', body_fvs = go body in
        if not (Ident.Set.mem id body_fvs) then (body', body_fvs)
        else
          let arg', arg_fvs = go arg in
          ( Lambda.Llet (kind, vk, id, arg', body'),
            Ident.Set.union arg_fvs (Ident.Set.remove id body_fvs) )
    | Lambda.Llet (Lambda.Strict, vk, id, arg, body) ->
        let arg', arg_fvs = go arg in
        let body', body_fvs = go body in
        ( Lambda.Llet (Lambda.Strict, vk, id, arg', body'),
          Ident.Set.union arg_fvs (Ident.Set.remove id body_fvs) )
    | Lambda.Lmutlet (vk, id, arg, body) ->
        let arg', arg_fvs = go arg in
        let body', body_fvs = go body in
        ( Lambda.Lmutlet (vk, id, arg', body'),
          Ident.Set.union arg_fvs (Ident.Set.remove id body_fvs) )
    | Lambda.Lletrec (decls, body) ->
        let fvs = ref Ident.Set.empty in
        let decls' =
          List.map
            (fun (rb : Lambda.rec_binding) ->
              let def =
                Lambda.map_lfunction
                  (fun b ->
                    let b', bfvs = go b in
                    let bfvs =
                      List.fold_left
                        (fun s (p, _) -> Ident.Set.remove p s)
                        bfvs rb.def.params
                    in
                    fvs := Ident.Set.union !fvs bfvs;
                    b')
                  rb.def
              in
              { rb with Lambda.def })
            decls
        in
        let body', body_fvs = go body in
        let all_fvs = Ident.Set.union !fvs body_fvs in
        let all_fvs =
          List.fold_left
            (fun s (rb : Lambda.rec_binding) -> Ident.Set.remove rb.id s)
            all_fvs decls
        in
        (Lambda.Lletrec (decls', body'), all_fvs)
    | Lambda.Lfunction lf ->
        let body_fvs = ref Ident.Set.empty in
        let def =
          Lambda.map_lfunction
            (fun b ->
              let b', bfvs = go b in
              body_fvs := bfvs;
              b')
            lf
        in
        let fvs =
          List.fold_left
            (fun s (p, _) -> Ident.Set.remove p s)
            !body_fvs lf.params
        in
        (Lambda.Lfunction def, fvs)
    | Lambda.Lstaticcatch (body, (id, params), handler) ->
        let body', body_fvs = go body in
        let handler', handler_fvs = go handler in
        let handler_fvs =
          List.fold_left
            (fun s (p, _) -> Ident.Set.remove p s)
            handler_fvs params
        in
        ( Lambda.Lstaticcatch (body', (id, params), handler'),
          Ident.Set.union body_fvs handler_fvs )
    | Lambda.Ltrywith (body, param, handler) ->
        let body', body_fvs = go body in
        let handler', handler_fvs = go handler in
        ( Lambda.Ltrywith (body', param, handler'),
          Ident.Set.union body_fvs (Ident.Set.remove param handler_fvs) )
    | Lambda.Lfor (v, lo, hi, dir, body) ->
        let lo', lo_fvs = go lo in
        let hi', hi_fvs = go hi in
        let body', body_fvs = go body in
        ( Lambda.Lfor (v, lo', hi', dir, body'),
          Ident.Set.union lo_fvs
            (Ident.Set.union hi_fvs (Ident.Set.remove v body_fvs)) )
    | Lambda.Lassign (id, rhs) ->
        let rhs', rhs_fvs = go rhs in
        (Lambda.Lassign (id, rhs'), Ident.Set.add id rhs_fvs)
    | _ ->
        let fvs = ref Ident.Set.empty in
        let child sub =
          let sub', sub_fvs = go sub in
          fvs := Ident.Set.union !fvs sub_fvs;
          sub'
        in
        let lam' = Lambda.shallow_map child lam in
        (lam', !fvs)
  in
  fst (go lam)

type call_uses = Calls of { arity : int; count : int } | Other_use

(* Inline before lowering creates closures and inserts polls. Lambda identifiers
   are globally unique. The compiler-libs copier freshens them, but leaves
   static exit labels alone. Freshen labels in the scope of their catch. *)
let inline_local_calls code =
  let open Lambda in
  let module Labels = Map.Make (Int) in
  let next_label = ref 0 in
  let uses = ref Ident.Map.empty in
  let callbacks = ref Ident.Set.empty in
  let callback_limit = 768 in
  let mark_other id = uses := Ident.Map.add id Other_use !uses in
  let rec size expr =
    (match expr with
    | Lstaticcatch (_, (id, _), _) | Lstaticraise (id, _) ->
        next_label := max !next_label id
    | _ -> ());
    let n = ref 1 in
    iter_head_constructor (fun child -> n := !n + size child) expr;
    !n
  in
  let rec record_uses skip = function
    | Lapply { ap_func = Lvar id; ap_args; _ } when not (Ident.Set.mem id skip) ->
        let arity = List.length ap_args in
        let use = match Ident.Map.find_opt id !uses with
          | None -> Calls { arity; count = 1 }
          | Some (Calls previous) when previous.arity = arity ->
              Calls { previous with count = previous.count + 1 }
          | Some _ -> Other_use
        in
        uses := Ident.Map.add id use !uses;
        List.iter (record_uses skip) ap_args
    | (Lvar id | Lmutvar id) when not (Ident.Set.mem id skip) -> mark_other id
    | expr -> iter_head_constructor (record_uses skip) expr
  in
  record_uses Ident.Set.empty code;
  let nodes = size code in
  let local_budget = ref (2 * nodes) in
  let import_budget = ref (min 2048 (nodes + 192)) in
  let budget = function None -> local_budget | Some _ -> import_budget in
  let rec fresh_exits labels = function
    | Lstaticcatch (body, (id, binders), handler) ->
        incr next_label;
        let fresh = !next_label in
        Lstaticcatch (fresh_exits (Labels.add id fresh labels) body,
          (fresh, binders), fresh_exits labels handler)
    | Lstaticraise (id, args) ->
        let id = Option.value ~default:id (Labels.find_opt id labels) in
        Lstaticraise (id, List.map (fresh_exits labels) args)
    | expr -> shallow_map (fresh_exits labels) expr
  in
  let known defs = function
    | Lfunction def -> Some (def, size def.body)
    | Lvar id -> Ident.Map.find_opt id defs
    | _ -> None
  in
  let known_callback defs (param, _) arg =
    match Ident.Map.find_opt param !uses, known defs arg with
    | Some (Calls { arity; count }), Some (def, cost) ->
        def.kind = Curried && List.length def.params = arity
        && def.attr.inline <> Never_inline
        && cost <= (if count = 1 then callback_limit else 24)
    | _ -> false
  in
  let should_inline defs def cost call =
    match def.attr.inline, call.ap_inlined with
    | Never_inline, _ | _, Never_inline -> false
    | (Always_inline | Hint_inline), _ | _, (Always_inline | Hint_inline) -> true
    | _ ->
        let small =
          match call.ap_func with
          | Lfunction _ -> cost <= 64
          | Lvar id ->
              Ident.Set.mem id !callbacks
              || (match Ident.Map.find_opt id !uses with
              | Some (Calls { count = 1; _ }) -> cost <= 64
              | Some (Calls _) -> cost <= 24
              | _ -> false)
          | _ -> false
        in
        small || (cost <= callback_limit
          && (def.attr.is_a_functor
              || List.exists2 (known_callback defs) def.params call.ap_args))
  in
  let callee defs call =
    match known defs call.ap_func with
    | Some (def, cost) when List.compare_lengths def.params call.ap_args = 0
                             && should_inline defs def cost call ->
        Some (def, cost, None)
    | Some _ -> None
    | None when call.ap_inlined = Never_inline -> None
    | None ->
        Option.bind (imported_callee_and_unit call.ap_func) (fun (target, unit_id) ->
          Option.map (fun def -> def, size def.body, Some unit_id) target.inline_lambda)
  in
  let rec visit depth defs = function
    | Llet (mode, kind, id, rhs, body) ->
        let def = known defs rhs in
        let defs' = match def with
          | Some def -> Ident.Map.add id def defs
          | None -> defs
        in
        let body = visit depth defs' body in
        let mode = if Option.is_some def then Alias else mode in
        Llet (mode, kind, id, visit depth defs rhs, body)
    | Lapply call ->
        (match callee defs call with
        | Some (def, cost, imported) when def.kind = Curried
            && List.compare_lengths def.params call.ap_args = 0
            && depth < 12 && cost <= !(budget imported) ->
            let remaining = budget imported in
            remaining := !remaining - cost;
            let def = duplicate_function def in
            let body = fresh_exits Labels.empty def.body in
            record_uses (free_variables (Lfunction def)) body;
            List.iter2 (fun ((id, _) as param) arg ->
              if known_callback defs param arg then
                callbacks := Ident.Set.add id !callbacks)
              def.params call.ap_args;
            (* [conv_atoms] evaluates arguments from left to right. Use
               strict bindings so effects are preserved even for unused formals. *)
            let body = List.fold_right2 (fun (id, kind) arg body ->
              Llet (Strict, kind, id, arg, body)) def.params call.ap_args body in
            let body = visit (depth + 1) defs body in
            (match imported with
             | None -> body
             | Some unit_id ->
                 Lsequence (Lprim (Pgetglobal unit_id, [], call.ap_loc), body))
        | _ -> shallow_map (visit depth defs) (Lapply call))
    | expr -> shallow_map (visit depth defs) expr
  in
  visit 0 Ident.Map.empty code

(* Inlining introduces argument bindings around the returned value.
   Move those bindings and any preceding effects out of strict right-hand
   sides so later passes can see the allocation being bound. Keep optional
   right-hand sides and control-flow regions separate. *)
let flatten_let_rhs code =
  let open Lambda in
  let rec visit next = function
    | Llet (mode, kind, id, rhs, body) ->
        let bind rhs = Llet (mode, kind, id, rhs, visit next body) in
        (match mode with
        | Strict -> visit bind rhs
        | Alias | StrictOpt -> bind (visit Fun.id rhs))
    | Lsequence (action, body) ->
        Lsequence (visit Fun.id action, visit next body)
    | expr -> next (shallow_map (visit Fun.id) expr)
  in
  visit Fun.id code

(* A known module block contains already-evaluated fields. Expose bindings
   introduced by a functor's inlined initializer so a later module
   projection can still name the original function. *)
let resolve_module_projections code =
  let open Lambda in
  let fields_of = function
    | Lprim (Pmakeblock (0, Immutable, None), fields, _)
      when List.for_all
        (function Lvar _ | Lconst (Const_int _ | Const_char _) -> true | _ -> false)
        fields ->
        Some (Array.of_list fields)
    | _ -> None
  in
  let extend modules id rhs =
    let fields =
      match rhs with Lvar alias -> Ident.Map.find_opt alias modules | _ -> fields_of rhs
    in
    match fields with
    | Some fields -> Ident.Map.add id fields modules
    | None -> modules
  in
  let rec returns_module = function
    | Llet (_, _, _, _, body) | Lletrec (_, body) | Lsequence (_, body) ->
        returns_module body
    | rhs -> Option.is_some (fields_of rhs)
  in
  let rec visit modules = function
    | Llet (mode, kind, id, rhs, body) ->
        let bind modules rhs =
          Llet (mode, kind, id, rhs, visit (extend modules id rhs) body)
        in
        let rhs = visit modules rhs in
        if mode = Strict && returns_module rhs then expose bind modules rhs
        else bind modules rhs
    | Lprim ((Pfield (index, _, Immutable) as field_prim), [owner], loc) ->
        let owner = visit modules owner in
        let field =
          match owner with
          | Lvar id ->
              Option.bind (Ident.Map.find_opt id modules) (fun fields ->
                if index >= 0 && index < Array.length fields then Some fields.(index)
                else None)
          | _ -> None
        in
        Option.value ~default:(Lprim (field_prim, [owner], loc)) field
    | expr -> shallow_map (visit modules) expr
  and expose bind modules = function
    | Llet (mode, kind, id, rhs, body) ->
        Llet (mode, kind, id, rhs, expose bind (extend modules id rhs) body)
    | Lletrec (defs, body) -> Lletrec (defs, expose bind modules body)
    | Lsequence (action, body) -> Lsequence (action, expose bind modules body)
    | rhs -> bind modules rhs
  in
  visit Ident.Map.empty code

(* The address of a one-field mutable block can be removed when every
   occurrence reads or writes that field. Immutable aliases have the same
   address. Closures, unknown calls and other uses can observe the block. *)
let promote_local_refs code =
  let open Lambda in
  let exception Escapes in
  let rec replace slot aliases may_store_pointer = function
    | Llet (_, _, alias, Lvar id, body) when Ident.Set.mem id aliases ->
        replace slot (Ident.Set.add alias aliases) may_store_pointer body
    | Lprim (Pfield (0, _, _), [ Lvar id ], _) when Ident.Set.mem id aliases ->
        Lmutvar slot
    | Lprim (Psetfield (0, repr, _), [ Lvar id; rhs ], _) when Ident.Set.mem id aliases ->
        if repr = Pointer then may_store_pointer := true;
        Lassign (slot, replace slot aliases may_store_pointer rhs)
    | Lprim (Poffsetref offset, [ Lvar id ], loc) when Ident.Set.mem id aliases ->
        Lassign (slot, Lprim (Poffsetint offset, [ Lmutvar slot ], loc))
    | Lvar id | Lmutvar id | Lassign (id, _) | Lifused (id, _)
      when Ident.Set.mem id aliases -> raise Escapes
    | Lfunction _ as expr ->
        if not (Ident.Set.disjoint aliases (free_variables expr)) then raise Escapes;
        expr
    | Lletrec (defs, body) ->
        List.iter (fun def ->
          if not (Ident.Set.disjoint aliases (free_variables (Lfunction def.def))) then
            raise Escapes) defs;
        Lletrec (defs, replace slot aliases may_store_pointer body)
    | expr -> shallow_map (replace slot aliases may_store_pointer) expr
  in
  let rec visit = function
    | Llet (mode, kind, id, Lprim ((Pmakeblock (0, Mutable, shape) as p), [init], loc), body) ->
        let init = visit init in
        let body = visit body in
        let may_store_pointer = ref false in
        (match replace id (Ident.Set.singleton id) may_store_pointer body with
        | body ->
            let slot_kind = match shape with
              | Some [kind] when not !may_store_pointer -> kind
              | _ -> Pgenval
            in
            Lmutlet (slot_kind, id, init, body)
        | exception Escapes -> Llet (mode, kind, id, Lprim (p, [init], loc), body))
    | expr -> shallow_map visit expr
  in
  visit code

(* An immutable block can disappear when all its uses project a field or
   inspect its known constructor. The fields still evaluate once, in the
   order used by allocation, even when the continuation ignores them. *)
let replace_local_aggregates code =
  let open Lambda in
  let exception Escapes in
  let small_aggregate fields =
    fields <> [] && List.compare_length_with fields 4 <= 0
  in
  let labels = lazy (
    let last = ref 0 in
    let rec scan expr =
      (match expr with
      | Lstaticcatch (_, (id, _), _) | Lstaticraise (id, _) -> last := max !last id
      | _ -> ());
      iter_head_constructor scan expr
    in
    scan code;
    last)
  in
  let fresh_label () =
    let last = Lazy.force labels in
    incr last;
    !last
  in
  let rec replace tag fields aliases = function
    | Llet (_, _, alias, Lvar id, body) when Ident.Set.mem id aliases ->
        replace tag fields (Ident.Set.add alias aliases) body
    | Lprim (Pfield (i, _, _), [Lvar id], _) when Ident.Set.mem id aliases ->
        (match List.nth_opt fields i with
        | Some field -> Lvar field
        | None -> raise Escapes)
    | Lprim (Pisint, [Lvar id], _) when Ident.Set.mem id aliases ->
        Lconst (Const_int 0)
    | Lifthenelse (Lvar id, yes, _) when Ident.Set.mem id aliases ->
        replace tag fields aliases yes
    | Lswitch (Lvar id, sw, _) when Ident.Set.mem id aliases ->
        let arm =
          match List.assoc_opt tag sw.sw_blocks with
          | Some _ as arm -> arm
          | None -> sw.sw_failaction
        in
        (match arm with
        | Some arm -> replace tag fields aliases arm
        | None -> raise Escapes)
    | Lvar id | Lmutvar id | Lassign (id, _) | Lifused (id, _)
      when Ident.Set.mem id aliases -> raise Escapes
    | Lfunction _ as expr ->
        if not (Ident.Set.disjoint aliases (free_variables expr)) then raise Escapes;
        expr
    | Lletrec (defs, body) ->
        List.iter (fun def ->
          if not (Ident.Set.disjoint aliases (free_variables (Lfunction def.def))) then
            raise Escapes) defs;
        Lletrec (defs, replace tag fields aliases body)
    | expr -> shallow_map (replace tag fields aliases) expr
  in
  (* Split matching branch results at a static join so the continuation is
     emitted once. Only the selected arm evaluates its field expressions. *)
  let join_fields id init body =
    let rec shape = function
      | Lprim (Pmakeblock (tag, Immutable, _), args, _)
        when small_aggregate args -> Some (tag, List.length args)
      | Lstaticraise _ | Lprim (Praise _, _, _) -> None
      | Llet (_, _, _, _, tail) | Lmutlet (_, _, _, tail) | Lsequence (_, tail) ->
          shape tail
      | Lifthenelse (_, yes, no) -> shared_shape [yes; no]
      | Lstaticcatch (body, _, handler) -> shared_shape [body; handler]
      | Lswitch (_, sw, _) ->
          shared_shape (List.map snd (sw.sw_consts @ sw.sw_blocks) @ Option.to_list sw.sw_failaction)
      | Lstringswitch (_, cases, fail, _) ->
          shared_shape (List.map snd cases @ Option.to_list fail)
      | _ -> raise Escapes
    and shared_shape arms =
      match List.filter_map shape arms with
      | [] -> None
      | first :: rest ->
          if List.for_all (( = ) first) rest then Some first else raise Escapes
    in
    let tag, arity = match shape init with Some shape -> shape | None -> raise Escapes in
    let fields = List.init arity (fun _ -> Ident.create_local "component") in
    let body = replace tag fields (Ident.Set.singleton id) body in
    let label = fresh_label () in
    let rec transfer = function
      | Lprim (Pmakeblock _, args, _) -> Lstaticraise (label, args)
      | (Lstaticraise _ | Lprim (Praise _, _, _)) as exit -> exit
      | Llet (mode, rep, id, value, tail) -> Llet (mode, rep, id, value, transfer tail)
      | Lmutlet (rep, id, value, tail) -> Lmutlet (rep, id, value, transfer tail)
      | Lsequence (value, tail) -> Lsequence (value, transfer tail)
      | Lifthenelse (cond, yes, no) -> Lifthenelse (cond, transfer yes, transfer no)
      | Lstaticcatch (body, binders, handler) ->
          Lstaticcatch (transfer body, binders, transfer handler)
      | Lswitch (value, sw, loc) ->
          let arm (tag, expr) = tag, transfer expr in
          Lswitch (value,
            { sw with sw_consts = List.map arm sw.sw_consts;
                      sw_blocks = List.map arm sw.sw_blocks;
                      sw_failaction = Option.map transfer sw.sw_failaction }, loc)
      | Lstringswitch (value, cases, fail, loc) ->
          Lstringswitch (value, List.map (fun (tag, arm) -> tag, transfer arm) cases,
                         Option.map transfer fail, loc)
      | _ -> assert false
    in
    Lstaticcatch (transfer init, (label, List.map (fun field -> field, Pgenval) fields), body)
  in
  let rec visit = function
    | Llet (mode, kind, id, Lprim ((Pmakeblock (tag, Immutable, shape) as prim), args, loc), body)
      when small_aggregate args ->
        let args = List.map visit args in
        let body = visit body in
        let fields = List.map (fun _ -> Ident.create_local "component") args in
        (match replace tag fields (Ident.Set.singleton id) body with
        | body ->
            let values = List.combine fields args in
            let kinds = Option.value ~default:(List.map (fun _ -> Pgenval) args) shape in
            List.fold_right2
              (fun (field, arg) kind body -> Llet (Strict, kind, field, arg, body))
              values kinds body
        | exception Escapes -> Llet (mode, kind, id, Lprim (prim, args, loc), body))
    | Llet (mode, kind, id, ((Lifthenelse _ | Lswitch _ | Lstringswitch _ | Lstaticcatch _) as init), body) ->
        let init = visit init in
        let body = visit body in
        (match join_fields id init body with
        | result -> result
        | exception Escapes -> Llet (mode, kind, id, init, body))
    | expr -> shallow_map visit expr
  in
  visit code

(* Groups that use their members only as saturated calls can share a
   dispatcher closure. Its environment stays borrowed across transitions.
   First-class uses outside the group call it through wrappers of the original
   arities, each owning the dispatcher independently. *)
let lift_recursive_calls program =
  let open Lambda in
  let free_fun def = free_variables (Lfunction def) in
  let rec visit mutable_ids static = function
    | Llet (mode, kind, id, rhs, body) ->
        let rhs = visit mutable_ids static rhs in
        let static =
          match rhs with
          | Lfunction def when Ident.Set.subset (free_fun def) static ->
              Ident.Set.add id static
          | _ -> static
        in
        Llet (mode, kind, id, rhs, visit mutable_ids static body)
    | Lmutlet (kind, id, rhs, body) ->
        Lmutlet (kind, id, visit mutable_ids static rhs,
          visit (Ident.Set.add id mutable_ids) static body)
    | Lletrec (bindings, body) ->
        let ids = Ident.Set.of_list (List.map (fun rb -> rb.id) bindings) in
        let free =
          List.fold_left
            (fun acc rb -> Ident.Set.union acc (free_fun rb.def))
            Ident.Set.empty bindings
        in
        let captures = Ident.Set.diff free (Ident.Set.union static ids) in
        let static = if Ident.Set.is_empty captures then Ident.Set.union ids static else static in
        let bindings =
          List.map
            (fun rb -> { rb with def = map_lfunction (visit mutable_ids static) rb.def })
            bindings
        in
        let body = visit mutable_ids static body in
        lift_group mutable_ids bindings captures body
    | expr -> shallow_map (visit mutable_ids static) expr
  and lift_group mutable_ids bindings captures body =
    let original = Lletrec (bindings, body) in
    let arity =
      List.fold_left (fun n rb -> max n (List.length rb.def.params)) 0 bindings
    in
    if List.length bindings < 2 || Ident.Set.is_empty captures
       || not (Ident.Set.disjoint mutable_ids captures)
       || arity + 1 > min 32 (Lambda.max_arity ())
       || List.exists (fun rb -> rb.def.kind <> Curried) bindings
    then original
    else
      let cases = List.mapi (fun tag rb -> tag, rb) bindings in
      let members =
        List.fold_left
          (fun acc (tag, rb) ->
            Ident.Map.add rb.id (tag, List.length rb.def.params) acc)
          Ident.Map.empty cases
      in
      let call_target id args =
        match Ident.Map.find_opt id members with
        | Some (tag, arity) when List.length args = arity -> Some tag
        | _ -> None
      in
      let rec uses_values = function
        | Lapply { ap_func = Lvar id; ap_args; _ }
          when Option.is_some (call_target id ap_args) ->
            List.exists uses_values ap_args
        | Lvar id -> Ident.Map.mem id members
        | expr ->
            let found = ref false in
            iter_head_constructor (fun e -> if uses_values e then found := true) expr;
            !found
      in
      if List.exists (fun rb -> uses_values rb.def.body) bindings then original
      else
        let dispatcher = Ident.create_local "mutrec_dispatch" in
        let selector = Ident.create_local "member" in
        let tag_and_args tag args =
          Lconst (Const_int tag)
          :: (args @ List.init (arity - List.length args) (fun _ -> lambda_unit))
        in
        let rec rewrite = function
          | Lapply ({ ap_func = Lvar id; ap_args; _ } as app) ->
              let args = List.map rewrite ap_args in
              (match call_target id args with
              | Some tag ->
                  Lapply { app with ap_func = Lvar dispatcher; ap_args = tag_and_args tag args }
              | None -> Lapply { app with ap_args = args })
          | expr -> shallow_map rewrite expr
        in
        let slots =
          List.init arity (fun i ->
              let immediate rb =
                match List.nth_opt rb.def.params i with
                | None | Some (_, Pintval) -> true
                | Some _ -> false
              in
              let kind = if List.for_all immediate bindings then Pintval else Pgenval in
              (Ident.create_local "arg", kind))
        in
        let arms =
          List.map
            (fun (tag, rb) ->
              let params = rb.def.params in
              let body =
                List.fold_right2
                  (fun (param, kind) (slot, _) body -> Llet (Alias, kind, param, Lvar slot, body))
                  params (List.take (List.length params) slots) (rewrite rb.def.body)
              in
              (tag, body))
            cases
        in
        let loc = (List.hd bindings).def.loc in
        let switch =
          Lswitch (Lvar selector,
            { sw_numconsts = List.length arms; sw_consts = arms;
              sw_numblocks = 0; sw_blocks = []; sw_failaction = None },
            loc)
        in
        let def =
          lfunction' ~kind:Curried ~params:((selector, Pintval) :: slots)
            ~return:Pgenval ~body:switch ~attr:default_function_attribute ~loc
        in
        let body = rewrite body in
        let value_uses = free_variables body in
        let body =
          List.fold_right
            (fun (tag, rb) body ->
              if not (Ident.Set.mem rb.id value_uses) then body
              else
                let def = rb.def in
                let params = List.map (fun (id, kind) -> Ident.rename id, kind) def.params in
                let args = List.map (fun (id, _) -> Lvar id) params in
                let call =
                  Lapply { ap_func = Lvar dispatcher; ap_args = tag_and_args tag args;
                    ap_loc = def.loc; ap_tailcall = Default_tailcall;
                    ap_inlined = Default_inline; ap_specialised = Default_specialise }
                in
                Llet (Strict, Pgenval, rb.id,
                  lfunction ~kind:Curried ~params ~return:def.return ~body:call
                    ~attr:def.attr ~loc:def.loc,
                  body))
            cases body
        in
        Lletrec ([ { id = dispatcher; def } ], body)
  in
  visit Ident.Set.empty Ident.Set.empty program

(* An immutable alias of a known stdlib selector still names that selector.
   Rewrite saturated applications only; the original binding remains available
   for exports, partial application, and other first-class uses. *)
let specialize_int_selector_aliases table code =
  let open Lambda in
  let rec visit aliases = function
    | Llet (mode, kind, id, rhs, body) ->
        let rhs = visit aliases rhs in
        let selector =
          match rhs with
          | Lvar source -> Ident.Map.find_opt source aliases
          | _ when Option.is_some (Builtins.resolve_int_selection table rhs) -> Some rhs
          | _ -> None
        in
        let aliases =
          match selector with
          | Some selector -> Ident.Map.add id selector aliases
          | None -> aliases
        in
        Llet (mode, kind, id, rhs, visit aliases body)
    | Lapply ({ ap_func = Lvar fn; ap_args = [ lhs; rhs ]; _ } as call) ->
        let ap_func = Option.value ~default:call.ap_func (Ident.Map.find_opt fn aliases) in
        Lapply { call with ap_func; ap_args = [ visit aliases lhs; visit aliases rhs ] }
    | expr -> shallow_map (visit aliases) expr
  in
  visit Ident.Map.empty code

(* Recover function identities from immutable Lambda blocks, including the
   conservative field reads emitted when a signature projects a submodule.
   Mutable records can change through aliases and never establish a shape. *)
type module_value = Unknown | Known_function of Ident.t | Structure of module_value array

let exported_functions code =
  let open Lambda in
  let rec scan env = function
    | Lvar id -> Option.value ~default:Unknown (Ident.Map.find_opt id env)
    | Llet (_, _, id, rhs, body) ->
        let value = match rhs with
          | Lfunction _ -> Known_function id
          | _ -> scan env rhs
        in
        scan (Ident.Map.add id value env) body
    | Lletrec (defs, body) ->
        let env = List.fold_left (fun env rb ->
          Ident.Map.add rb.id (Known_function rb.id) env) env defs in
        scan env body
    | Lmutlet (_, _, _, body) | Lsequence (_, body) | Levent (body, _) ->
        scan env body
    | Lprim (Psetglobal _, [body], _) -> scan env body
    | Lprim (Pmakeblock (0, Immutable, _), fields, _) ->
        Structure (Array.of_list (List.map (scan env) fields))
    | Lprim (Pfield (slot, _, _), [owner], _) ->
        (match scan env owner with
        | Structure fields when slot >= 0 && slot < Array.length fields -> fields.(slot)
        | _ -> Unknown)
    | _ -> Unknown
  in
  let rec gather path acc = function
    | Known_function id -> (List.rev path, id) :: acc
    | Structure fields ->
        let acc = ref acc in
        Array.iteri (fun i field -> acc := gather (i :: path) !acc field) fields;
        !acc
    | Unknown -> acc
  in
  gather [] [] (scan Ident.Map.empty code)

let propagate_immediate_constants code =
  let open Lambda in
  let rec visit constants = function
    | Lvar id as expr -> Option.value ~default:expr (Ident.Map.find_opt id constants)
    | Llet (mode, kind, id, rhs, body) ->
        (match visit constants rhs with
         | Lconst (Const_int _ | Const_char _) as value ->
             visit (Ident.Map.add id value constants) body
         | rhs -> Llet (mode, kind, id, rhs, visit constants body))
    | expr -> shallow_map (visit constants) expr
  in
  visit Ident.Map.empty code

let module_bindings code =
  let open Lambda in
  let rec bindings defs = function
    | Llet (_, kind, id, rhs, body) ->
        bindings (Ident.Map.add id (kind, rhs) defs) body
    | Lletrec (group, body) ->
        let defs = List.fold_left (fun defs rb ->
          Ident.Map.add rb.id (Pgenval, Lfunction rb.def) defs) defs group
        in
        bindings defs body
    | Lmutlet (_, _, _, body) | Lsequence (_, body) | Levent (body, _)
    | Lprim (Psetglobal _, [body], _) -> bindings defs body
    | _ -> defs
  in
  bindings Ident.Map.empty code

(* Make a module slot only for values already rooted by a published closure.
   Local functions and values that die in the initializer retain their normal
   lifetimes. Follow private direct helpers from the published definitions. *)
let module_captures defs exported =
  let rec follow (seen, slots) id =
    if Ident.Set.mem id seen then seen, slots
    else
      let seen = Ident.Set.add id seen in
      match Ident.Map.find_opt id defs with
      | Some (_, (Lambda.Lfunction _ as fn)) ->
          Ident.Set.fold (fun capture state -> follow state capture)
            (Lambda.free_variables fn) (seen, slots)
      | Some (kind, _) -> seen, Ident.Map.add id kind slots
      | None -> seen, slots
  in
  snd (List.fold_left (fun state (_, id) -> follow state id)
         (Ident.Set.empty, Ident.Map.empty) exported)

(* Publish allocation-producing small bodies before ANF consumes their field
   shapes. An acyclic helper can travel with the body, provided it has no
   module-local value captures and the complete copy still fits the budget. *)
let inline_export_bodies defs exported =
  let open Lambda in
  let exception Ineligible in
  let rec returns_product = function
    | Lprim (Pmakeblock (_, Immutable, _), fields, _) ->
        List.compare_length_with fields 2 >= 0 && List.compare_length_with fields 4 <= 0
    | Llet (_, _, _, _, tail) | Lsequence (_, tail) | Lmutlet (_, _, _, tail) ->
        returns_product tail
    | Lifthenelse (_, yes, no) | Lstaticcatch (yes, _, no) ->
        returns_product yes || returns_product no
    | Lswitch (_, sw, _) ->
        List.exists (fun (_, arm) -> returns_product arm) (sw.sw_consts @ sw.sw_blocks)
        || Option.exists returns_product sw.sw_failaction
    | Lstringswitch (_, cases, fail, _) ->
        List.exists (fun (_, arm) -> returns_product arm) cases
        || Option.exists returns_product fail
    | _ -> false
  in
  let function_at id =
    match Ident.Map.find_opt id defs with
    | Some (_, Lfunction def) when def.kind = Curried
        && def.attr.inline <> Never_inline && not def.attr.is_a_functor -> def
    | _ -> raise Ineligible
  in
  let called_helpers def =
    let captures = free_variables (Lfunction def) in
    let rec check = function
      | Lapply { ap_func = Lvar id; ap_args; _ } when Ident.Set.mem id captures ->
          let helper = function_at id in
          if List.compare_lengths ap_args helper.params <> 0 then raise Ineligible;
          List.iter check ap_args
      | Lvar id when Ident.Set.mem id captures -> raise Ineligible
      | expr -> iter_head_constructor check expr
    in
    check def.body;
    captures
  in
  let copy id =
    let def = function_at id in
    if not (returns_product def.body) then raise Ineligible;
    let remaining = ref 192 in
    let rec measure expr =
      decr remaining;
      if !remaining < 0 then raise Ineligible;
      iter_head_constructor measure expr
    in
    measure def.body;
    let rec close active (seen, helpers) id =
      if Ident.Set.mem id active then raise Ineligible;
      if Ident.Set.mem id seen then seen, helpers
      else
        let helper = function_at id in
        measure helper.body;
        let active = Ident.Set.add id active in
        let seen, helpers =
          Ident.Set.fold (fun id state -> close active state id)
            (called_helpers helper) (seen, helpers)
        in
        Ident.Set.add id seen, (id, helper) :: helpers
    in
    let _, helpers =
      Ident.Set.fold (fun capture state -> close (Ident.Set.singleton id) state capture)
        (called_helpers def) (Ident.Set.empty, [])
    in
    map_lfunction (fun body ->
      List.fold_left (fun body (id, helper) ->
        Llet (Alias, Pgenval, id, Lfunction helper, body))
        body helpers) def
  in
  List.fold_left (fun bodies (_, id) ->
    if Ident.Map.mem id bodies then bodies
    else match copy id with
      | def -> Ident.Map.add id def bodies
      | exception Ineligible -> bodies) Ident.Map.empty exported

(* Only private numeric values can lose their boxes. The slot initializer and
   writes must produce their own values, and a read that needs an OCaml value
   must leave the slot's scope. References that escape have already been
   excluded by [promote_local_refs]. *)
let specialize_mutable_slots code =
  let open Lambda in
  let exception Boxed_use in
  let slots = ref Ident.Map.empty in
  let produced_by = function
    | Paddfloat | Psubfloat | Pmulfloat | Pdivfloat
    | Pfloatofint | Pnegfloat | Pabsfloat | Pfloatfield _
    | Parrayrefu Pfloatarray | Parrayrefs Pfloatarray -> Some Double_scalar
    | Pbintofint k | Pcvtbint (_, k) | Pnegbint k
    | Paddbint k | Psubbint k | Pmulbint k | Pandbint k | Porbint k | Pxorbint k
    | Plslbint k | Plsrbint k | Pasrbint k
    | Pdivbint { size = k; _ } | Pmodbint { size = k; _ } -> Some (Integer_scalar k)
    | _ -> None
  in
  let rec producer = function
    | Lconst c ->
        let rep = match c with
          | Const_float _ -> Some Double_scalar
          | Const_int32 _ -> Some (Integer_scalar Pint32)
          | Const_int64 _ -> Some (Integer_scalar Pint64)
          | Const_nativeint _ -> Some (Integer_scalar Pnativeint)
          | _ -> None in
        Option.map (fun kind -> kind, Some c) rep
    | Lprim (p, _, _) -> Option.map (fun rep -> rep, None) (produced_by p)
    | Llet (_, _, _, _, tail) | Lsequence (_, tail) | Levent (tail, _) -> producer tail
    | Lifthenelse (_, yes, no) ->
        (match producer yes, producer no with
        | Some (rep, None), Some (other, None) when rep = other -> Some (rep, None)
        | _ -> None)
    | _ -> None
  in
  let consumes rep prim index =
    let expected = match prim with
      | Paddfloat | Psubfloat | Pmulfloat | Pdivfloat | Pfloatcomp _
      | Pnegfloat | Pabsfloat | Pintoffloat -> Some Double_scalar
      | Parraysets Pfloatarray | Parraysetu Pfloatarray when index = 2 -> Some Double_scalar
      | Paddbint k | Psubbint k | Pmulbint k | Pandbint k | Porbint k | Pxorbint k
      | Pdivbint { size = k; _ } | Pmodbint { size = k; _ }
      | Pbintcomp (k, _) | Pcompare_bints k
      | Pnegbint k | Pintofbint k | Pcvtbint (k, _) -> Some (Integer_scalar k)
      | (Plslbint k | Plsrbint k | Pasrbint k) when index = 0 -> Some (Integer_scalar k)
      | _ -> None in
    expected = Some rep
  in
  let prepare slot rep initial body =
    let assigns = ref false and boxed_exit = ref false and writes_literal = ref false in
    let rec visit flag ~exit expr =
      let check = visit flag ~exit:false in
      let tail = visit flag ~exit in
      match expr with
      | Lmutvar id when Ident.same id slot ->
          if not exit then raise Boxed_use;
          boxed_exit := true;
          (match flag with
          | None -> expr
          | Some (written, constant) ->
              Lifthenelse (Lmutvar written, expr, Lconst constant))
      | Lassign (id, rhs) when Ident.same id slot ->
          (match producer rhs with
          | Some (actual, literal) when actual = rep ->
              assigns := true;
              if Option.is_some literal then writes_literal := true
          | _ -> raise Boxed_use);
          let assignment = Lassign (id, check rhs) in
          (match flag with
          | None -> assignment
          | Some (written, _) ->
              Lsequence (assignment, Lassign (written, Lconst (Const_int 1))))
      | Lprim (prim, args, loc) ->
          let args = List.mapi (fun index value ->
            match value with
            | Lmutvar id when Ident.same id slot && consumes rep prim index -> value
            | _ -> check value) args in
          Lprim (prim, args, loc)
      | Llet (mode, kind, id, rhs, body) -> Llet (mode, kind, id, check rhs, tail body)
      | Lmutlet (kind, id, rhs, body) -> Lmutlet (kind, id, check rhs, tail body)
      | Lsequence (first, body) -> Lsequence (check first, tail body)
      | Lifthenelse (cond, yes, no) -> Lifthenelse (check cond, tail yes, tail no)
      | Lswitch (value, cases, loc) ->
          let arm (tag, body) = tag, tail body in
          Lswitch (check value,
            { cases with sw_consts = List.map arm cases.sw_consts;
                         sw_blocks = List.map arm cases.sw_blocks;
                         sw_failaction = Option.map tail cases.sw_failaction }, loc)
      | Lstringswitch (value, cases, fail, loc) ->
          Lstringswitch (check value, List.map (fun (tag, body) -> tag, tail body) cases,
                         Option.map tail fail, loc)
      | Lstaticcatch (body, binders, handler) ->
          Lstaticcatch (tail body, binders, tail handler)
      | Ltrywith (body, id, handler) -> Ltrywith (tail body, id, tail handler)
      | Levent (body, event) -> Levent (tail body, event)
      | Lfunction _ ->
          if Ident.Set.mem slot (free_variables expr) then raise Boxed_use;
          expr
      | Lletrec (defs, body) ->
          List.iter (fun def ->
            if Ident.Set.mem slot (free_variables (Lfunction def.def)) then raise Boxed_use) defs;
          Lletrec (defs, tail body)
      | _ -> shallow_map check expr
    in
    ignore (visit None ~exit:true body);
    if not !assigns || (!boxed_exit && !writes_literal) then raise Boxed_use;
    match initial with
    | Some constant when !boxed_exit ->
        (* A zero-write exit still returns a static constant. *)
        let written = Ident.create_local "slot_written" in
        Lmutlet (Pintval, written, Lconst (Const_int 0),
                 visit (Some (written, constant)) ~exit:true body)
    | _ -> body
  in
  let rec visit = function
    | Lmutlet (kind, id, init, body) ->
        let init = visit init in
        let body = visit body in
        let body =
          match producer init with
          | Some (rep, literal) ->
              (match prepare id rep literal body with
              | prepared -> slots := Ident.Map.add id rep !slots; prepared
              | exception Boxed_use -> body)
          | None -> body in
        Lmutlet (kind, id, init, body)
    | expr -> shallow_map visit expr
  in
  let code = visit code in
  code, !slots

(* The Lambda identifiers survive ANF conversion. Keep source representation
   facts alongside the tree so later rewrites can keep using the same binders. *)
let binding_kinds code =
  let kinds = ref Ident.Map.empty in
  let add id kind = kinds := Ident.Map.add id kind !kinds in
  let rec visit expr =
    (match expr with
    | Lambda.Llet (_, kind, id, _, _) | Lmutlet (kind, id, _, _) -> add id kind
    | Lstaticcatch (_, (_, binders), _) ->
        List.iter (fun (id, kind) -> add id kind) binders
    | _ -> ());
    Lambda.iter_head_constructor visit expr
  in
  visit code;
  !kinds

let of_lambda ?(use_builtins = true) ?(include_dirs = []) ?stdlib_dir ?(imports = [])
    ?(load_exports = fun _ -> None) ?on_export_ids (program : Lambda.program) : (program, string) result =
  let saved = !builtin_tables in
  let saved_imports = !unit_imports in
  let saved_scalars = !mutable_scalars in
  let saved_slots = !module_slots in
  let printing = if use_builtins then Some (Builtins.load ~include_dirs ()) else None in
  let stdlib_dir =
    match stdlib_dir with
    | None when use_builtins -> Some Config.standard_library
    | dir -> dir
  in
  let selectors =
    Option.map
      (fun stdlib_dir -> lazy (Builtins.load_int_selection ~include_dirs ~stdlib_dir))
      stdlib_dir
  in
  builtin_tables := (printing, selectors);
  unit_imports := (fun name ->
    match List.assoc_opt name imports with
    | Some _ as known -> known
    | None -> load_exports name);
  Fun.protect
    ~finally:(fun () ->
      builtin_tables := saved;
      unit_imports := saved_imports;
      mutable_scalars := saved_scalars;
      module_slots := saved_slots)
    (fun () ->
      try
        let code =
          match selectors with
          | Some table -> specialize_int_selector_aliases table program.code
          | None -> program.code
        in
        let cleaned =
          code |> propagate_immediate_constants |> inline_local_calls
          |> flatten_let_rhs |> resolve_module_projections
          |> drop_unused_alias_lets |> promote_local_refs
          |> replace_local_aggregates |> lift_recursive_calls
        in
        let cleaned, scalars = specialize_mutable_slots cleaned in
        mutable_scalars := scalars;
        let exports = exported_functions cleaned in
        let bindings = module_bindings cleaned in
        module_slots := module_captures bindings exports;
        let inline_bodies =
          if Option.is_some on_export_ids then inline_export_bodies bindings exports
          else Ident.Map.empty
        in
        Option.iter (fun save -> save exports) on_export_ids;
        let code = conv_tail cleaned |> specialize_scalar_bindings in
        Ok { module_ident = program.module_ident; code;
             value_kinds = binding_kinds cleaned; inline_bodies }
      with Unsupported what -> Error what)

(* A small closed expression over tagged scalar parameters can be copied into
   the caller. Its body uses neither ownership operations nor exception state. *)
let inline_export_leaves lambda code =
  let allowed = ref Ident.Set.empty in
  let add id (lf : Lambda.lfunction) =
    match lf.attr.inline with
    | Never_inline | Unroll _ -> ()
    | _ -> allowed := Ident.Set.add id !allowed
  in
  let rec visit expr =
    (match expr with
    | Lambda.Llet (_, _, id, Lfunction lf, _) -> add id lf
    | Lambda.Lletrec (defs, _) ->
        List.iter (fun (rb : Lambda.rec_binding) -> add rb.id rb.def) defs
    | _ -> ());
    Lambda.iter_head_constructor visit expr
  in
  visit lambda;
  let scalar = function Var _ | Int _ | Char _ | Unit -> true | _ -> false in
  let rec leaf remaining = function
    | Halt a when scalar a -> remaining - 1
    | Let (_, Atom a, body) when scalar a && remaining > 0 ->
        leaf (remaining - 1) body
    | Let (_, Binop ((Add | Sub | Mul | And | Or | Xor | Lsl | Lsr | Asr
                     | Cmp _ | Compare_ints | Isout), lhs, rhs), body)
      when scalar lhs && scalar rhs && remaining > 0 ->
        leaf (remaining - 1) body
    | Let (_, Unop ((Neg | Not | Offset _ | Isint), a), body)
      when scalar a && remaining > 0 ->
        leaf (remaining - 1) body
    | If (cond, yes, no) when scalar cond && remaining > 0 ->
        let after_yes = leaf (remaining - 1) yes in
        if after_yes >= 0 then leaf after_yes no else -1
    | LetJoin (_, rhs, body) when remaining > 0 ->
        let after_rhs = leaf (remaining - 1) rhs in
        if after_rhs >= 0 then leaf after_rhs body else -1
    | _ -> -1
  in
  let leaves = List.fold_left (fun acc (id, lf) ->
    let params = Ident.Set.of_list (List.map fst lf.params) in
    if Ident.Set.mem id !allowed
       && List.for_all (fun (_, rep) -> rep = Lambda.Pintval) lf.params
       && leaf 12 lf.body >= 0
       && Ident.Set.subset (free_vars lf.body) params
    then Ident.Map.add id lf acc else acc) Ident.Map.empty (pure_defs code)
  in
  fun id -> Ident.Map.find_opt id leaves

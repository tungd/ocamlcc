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

type atom =
  | Var of Ident.t
  | MutVar of Ident.t
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
  | Fadd
  | Fsub
  | Fmul
  | Fdiv
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

type cexpr =
  | Atom of atom
  | Binop of binop * atom * atom
  | Unop of unop * atom
  | MakeBlock of int * atom list
  | AllocReuse of Ident.t * int * atom list
  | MakeArray of Lambda.array_kind * atom list
  | Field of int * atom
  | SetField of int * atom * atom
  | FloatField of int * atom
  | SetFloatField of int * atom * atom
  | OffsetRef of int * atom
  | StringGet of bool * atom * atom
  | BytesSet of bool * atom * atom * atom
  | ArrayGet of bool * Lambda.array_kind * atom * atom
  | ArraySet of bool * Lambda.array_kind * atom * atom * atom
  | CreateBytes of atom
  | MakeArrayInit of atom * atom
  | App of atom * atom list
  | Builtin of string * Builtins.arg_kind * atom
  | Ccall of string * atom list
  | GetGlobal of string
  | Fun of lfunction
  | Assign of Ident.t * atom

and lfunction = {
  params : (Ident.t * Lambda.value_kind) list;
  body : aexpr;
}

and rec_binding = {
  id : Ident.t;
  def : lfunction;
}

and aexpr =
  | Halt of atom
  | Let of Ident.t * cexpr * aexpr
  | MutLet of Ident.t * cexpr * aexpr
  | LetJoin of Ident.t * aexpr * aexpr
  | LetRec of rec_binding list * aexpr
  | If of atom * aexpr * aexpr
  | Switch of atom * switch_cases
  | StringSwitch of atom * (string * aexpr) list * aexpr option
  | StaticCatch of aexpr * int * Ident.t list * aexpr
  | StaticRaise of int * atom list
  | While of aexpr * aexpr
  | For of Ident.t * atom * atom * Asttypes.direction_flag * aexpr
  | TryWith of aexpr * Ident.t * aexpr
  | Raise of atom
  | CheckExn of aexpr * aexpr
  | Unwind
  | Retain of Ident.t * aexpr
  | Release of Ident.t * aexpr
  | ReleaseMut of Ident.t * aexpr
  | DropReuse of Ident.t * Ident.t * aexpr
  | FreeReuse of Ident.t * aexpr
  | ShadowPush of Ident.t list * Ident.t list * Ident.t list * aexpr
  | ShadowPop of int * int * aexpr

and switch_cases = {
  consts : (int * aexpr) list;
  blocks : (int * aexpr) list;
  fail : aexpr option;
}

type program = {
  module_ident : Ident.t;
  code : aexpr;
}

exception Unsupported of string

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

let check_array_kind (_k : Lambda.array_kind) = ()

let builtins_enabled = ref true

let rec conv_tail (lam : Lambda.lambda) : aexpr =
  conv_expr lam (fun a -> Halt a)

and conv_atoms (lams : Lambda.lambda list) (k : atom list -> aexpr) : aexpr =
  match lams with
  | [] -> k []
  | x :: xs -> conv_expr x (fun a -> conv_atoms xs (fun rest -> k (a :: rest)))

and conv_fun (lf : Lambda.lfunction) : lfunction =
  match lf.kind with
  | Curried -> { params = lf.params; body = conv_tail lf.body }
  | Tupled ->
      let tup = Ident.create_local "tup" in
      let rec bind_fields i = function
        | [] -> conv_tail lf.body
        | (p, _) :: rest ->
            Let (p, Field (i, Var tup), bind_fields (i + 1) rest)
      in
      { params = [ (tup, Lambda.Pgenval) ]; body = bind_fields 0 lf.params }

and conv_bind (id : Ident.t) (rhs : Lambda.lambda) (k : unit -> aexpr) : aexpr =
  match rhs with
  | Levent (l, _) | Lifused (_, l) | Lprim (Popaque, [ l ], _) ->
      conv_bind id l k
  | Lprim (Psetglobal _, [ l ], _) -> conv_bind id l k
  | Llet (_, _, id1, arg1, body1) ->
      conv_bind id1 arg1 (fun () -> conv_bind id body1 k)
  | Lmutlet (_, id1, arg1, body1) ->
      conv_mut_bind id1 arg1 (fun () -> conv_bind id body1 k)
  | Lletrec (bindings, body1) ->
      let rbs =
        List.map
          (fun (rb : Lambda.rec_binding) ->
            { id = rb.id; def = conv_fun rb.def })
          bindings
      in
      LetRec (rbs, conv_bind id body1 k)
  | Lsequence (a, b) ->
      conv_expr a (fun _ -> conv_bind id b k)
  | Lconst c -> Let (id, Atom (conv_const c), k ())
  | Lvar v -> Let (id, Atom (Var v), k ())
  | Lmutvar v -> Let (id, Atom (MutVar v), k ())
  | Lfunction lf -> Let (id, Fun (conv_fun lf), k ())
  | Lassign (v, arg) ->
      conv_expr arg (fun a -> Let (id, Assign (v, a), k ()))
  | Lapply _ | Lprim _ -> (
      match rhs with
      | Lprim (Psequand, _, _)
      | Lprim (Psequor, _, _) ->
          LetJoin (id, conv_tail rhs, k ())
      | _ -> conv_simple id rhs k)
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

and conv_mut_bind (id : Ident.t) (rhs : Lambda.lambda) (k : unit -> aexpr) :
    aexpr =
  let t = Ident.create_local (Ident.name id ^ "_init") in
  conv_bind t rhs (fun () -> MutLet (id, Atom (Var t), k ()))

and conv_simple (id : Ident.t) (lam : Lambda.lambda) (k : unit -> aexpr) : aexpr =
  let emit_cexpr ce = Let (id, ce, k ()) in
  match lam with
  | Lapply { ap_func; ap_args; _ } -> (
      match (if !builtins_enabled then Builtins.resolve ap_func else None) with
      | Some { symbol; arg_kind } -> (
          match ap_args with
          | [ arg ] ->
              conv_expr arg (fun a -> emit_cexpr (Builtin (symbol, arg_kind, a)))
          | _ -> raise (Unsupported (describe lam)))
      | None ->
          conv_expr ap_func (fun fn ->
              conv_atoms ap_args (fun args -> emit_cexpr (App (fn, args)))))
  | Lprim (Pignore, [ arg ], _) ->
      conv_expr arg (fun _ -> emit_cexpr (Atom Unit))
  | Lprim (Pbytes_to_string, [ arg ], _)
  | Lprim (Pbytes_of_string, [ arg ], _) ->
      conv_expr arg (fun a -> emit_cexpr (Atom a))
  | Lprim (Pmakeblock (tag, _, _), args, _) -> (
      match args with
      | [] -> emit_cexpr (Atom Unit)
      | _ -> conv_atoms args (fun vs -> emit_cexpr (MakeBlock (tag, vs))))
  | Lprim (Pmakearray (kind, _), args, _) ->
      check_array_kind kind;
      conv_atoms args (fun vs -> emit_cexpr (MakeArray (kind, vs)))
  | Lprim (Pduparray (kind, _), [ Lambda.Lconst (Const_block (_, items)) ], _) ->
      check_array_kind kind;
      emit_cexpr (MakeArray (kind, List.map conv_const items))
  | Lprim (Pduparray (kind, _), [ Lambda.Lconst (Const_float_array sl) ], _) ->
      check_array_kind kind;
      emit_cexpr (MakeArray (kind, List.map (fun s -> Float (parse_const_float s)) sl))
  | Lprim (Pfield (i, _, _), [ arg ], _) ->
      conv_expr arg (fun a -> emit_cexpr (Field (i, a)))
  | Lprim (Psetfield (i, _, _), [ arg; rhs ], _) ->
      conv_expr arg (fun a ->
          conv_expr rhs (fun v -> emit_cexpr (SetField (i, a, v))))
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
  | Lprim (Pccall pd, args, _) -> (
      match (pd.Primitive.prim_name, args) with
      | "caml_create_bytes", [ len ] ->
          conv_expr len (fun la -> emit_cexpr (CreateBytes la))
      | "caml_array_make", [ len; init ] ->
          conv_expr len (fun la ->
              conv_expr init (fun ia -> emit_cexpr (MakeArrayInit (la, ia))))
      | "caml_fresh_oo_id", [ arg ] ->
          conv_expr arg (fun a -> emit_cexpr (Ccall ("caml_fresh_oo_id", [ a ])))
      | sym, args
        when pd.Primitive.prim_arity = List.length args
             && List.length args <= 6 -> (
          (* C externals: [caml_*] primitives must be registered with their
             C ABI in [Ccalls] (unknown ones are rejected — they are
             compiler/runtime implementation details, not a user ABI);
             non-[caml_] externals are user C FFI and always lower to
             [Ccall] with the conservative default ABI. *)
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
          else conv_atoms args (fun vs -> emit_cexpr (Ccall (sym, vs))))
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
  | Lprim (Paddfloat, [ a; c ], _) -> binop Fadd a c emit_cexpr
  | Lprim (Psubfloat, [ a; c ], _) -> binop Fsub a c emit_cexpr
  | Lprim (Pmulfloat, [ a; c ], _) -> binop Fmul a c emit_cexpr
  | Lprim (Pdivfloat, [ a; c ], _) -> binop Fdiv a c emit_cexpr
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
  | _ -> raise (Unsupported (describe lam))

and binop op a c emit_cexpr =
  conv_expr a (fun av -> conv_expr c (fun cv -> emit_cexpr (Binop (op, av, cv))))

and conv_expr (lam : Lambda.lambda) (k : atom -> aexpr) : aexpr =
  match lam with
  | Lconst c -> k (conv_const c)
  | Lvar id -> k (Var id)
  | Lmutvar id -> k (MutVar id)
  | Levent (l, _) | Lifused (_, l) | Lprim (Popaque, [ l ], _) ->
      conv_expr l k
  | Lprim (Psetglobal _, [ body ], _) -> conv_expr body k
  | Llet (_, _, id, arg, body) ->
      conv_bind id arg (fun () -> conv_expr body k)
  | Lmutlet (_, id, arg, body) ->
      conv_mut_bind id arg (fun () -> conv_expr body k)
  | Lletrec (bindings, body) ->
      let rbs =
        List.map
          (fun (rb : Lambda.rec_binding) ->
            { id = rb.id; def = conv_fun rb.def })
          bindings
      in
      LetRec (rbs, conv_expr body k)
  | Lsequence (a, b) -> conv_expr a (fun _ -> conv_expr b k)
  | Lfunction lf ->
      let id = Ident.create_local "anon" in
      Let (id, Fun (conv_fun lf), k (Var id))
  | Lassign (id, rhs) ->
      let t = Ident.create_local "assign" in
      conv_expr rhs (fun a -> Let (t, Assign (id, a), k (Var t)))
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
                { consts =
                    List.map (fun (n, arm) -> (n, conv_tail arm)) sw.sw_consts;
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
          (conv_tail body, id, List.map fst binders, conv_tail handler)
      in
      wrap_or_tail e k
  | Lstaticraise (id, args) ->
      conv_atoms args (fun vs -> StaticRaise (id, vs))
  | Ltrywith (body, exn_id, handler) ->
      let e = TryWith (conv_tail body, exn_id, conv_tail handler) in
      wrap_or_tail e k
  | Lwhile (cond, body) ->
      seq_stmt (While (conv_tail cond, conv_tail body)) (k Unit)
  | Lfor (id, start_e, stop_e, dir, body) ->
      conv_expr start_e (fun sa ->
          conv_expr stop_e (fun ea ->
              seq_stmt (For (id, sa, ea, dir, conv_tail body)) (k Unit)))
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

let atom_vars acc = function
  | Var id | MutVar id -> Ident.Set.add id acc
  | Int _ | Char _ | String _ | Float _ | Int32 _ | Int64 _ | Nativeint _
  | ConstFloatArray _ | ConstBlock _ | Unit ->
      acc

let cexpr_vars free_aexpr acc = function
  | Atom a -> atom_vars acc a
  | Binop (_, a, b) -> atom_vars (atom_vars acc a) b
  | Unop (_, a) -> atom_vars acc a
  | MakeBlock (_, args) | MakeArray (_, args) ->
      List.fold_left atom_vars acc args
  | AllocReuse (tok, _, args) ->
      Ident.Set.add tok (List.fold_left atom_vars acc args)
  | Field (_, a) | FloatField (_, a) | OffsetRef (_, a) | CreateBytes a ->
      atom_vars acc a
  | SetField (_, a, b)
  | SetFloatField (_, a, b)
  | StringGet (_, a, b)
  | ArrayGet (_, _, a, b)
  | MakeArrayInit (a, b) ->
      atom_vars (atom_vars acc a) b
  | BytesSet (_, a, b, c) | ArraySet (_, _, a, b, c) ->
      atom_vars (atom_vars (atom_vars acc a) b) c
  | App (fn, args) ->
      List.fold_left atom_vars (atom_vars acc fn) args
  | Builtin (_, _, a) -> atom_vars acc a
  | Ccall (_, args) -> List.fold_left atom_vars acc args
  | GetGlobal _ -> acc
  | Assign (id, a) -> Ident.Set.add id (atom_vars acc a)
  | Fun lf ->
      let body_free = free_aexpr lf.body in
      let body_free =
        List.fold_left
          (fun s (p, _) -> Ident.Set.remove p s)
          body_free lf.params
      in
      Ident.Set.union acc body_free

let rec free_vars (e : aexpr) : Ident.Set.t =
  match e with
  | Halt a -> atom_vars Ident.Set.empty a
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
                (fun s (p, _) -> Ident.Set.remove p s)
                f_b rb.def.params
            in
            Ident.Set.union acc (Ident.Set.diff f_b rec_ids))
          Ident.Set.empty bindings
      in
      let f_body = Ident.Set.diff (free_vars body) rec_ids in
      Ident.Set.union f_defs f_body
  | If (c, th, el) ->
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
  | StaticCatch (body, _, binders, handler) ->
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
  | CheckExn (on_err, on_ok) ->
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
      List.fold_left (fun s (p, _) -> Ident.Set.add p s) Ident.Set.empty lf.params
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
    | If (_, th, el) -> go known (go known acc th) el
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
    | StaticCatch (body, _, _, handler) ->
        go known (go known acc body) handler
    | TryWith (body, _, handler) -> go known (go known acc body) handler
    | While (cond, body) | CheckExn (cond, body) ->
        go known (go known acc cond) body
    | For (_, _, _, _, body) -> go known acc body
    | Halt _ | Raise _ | Unwind | StaticRaise _ -> acc
    | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
    | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        go known acc body
  in
  List.rev (go Ident.Set.empty [] e)

let of_lambda ?(use_builtins = true) (program : Lambda.program) :
    (program, string) result =
  let saved = !builtins_enabled in
  builtins_enabled := use_builtins;
  Fun.protect
    ~finally:(fun () -> builtins_enabled := saved)
    (fun () ->
      try Ok { module_ident = program.module_ident; code = conv_tail program.code }
      with Unsupported what -> Error what)

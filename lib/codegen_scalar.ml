(* Code generation for numeric values in boxed and scalar representations. *)

open Codegen_ctx
open Qbe_il

let load_double b (v : t) : t =
  let d = fresh_temp b "fval" in
  emit b (Load (Loadd, Double, d, v));
  d

let box_double b (d : t) : t =
  let dst = fresh_temp b "fbox" in
  emit b
    (Call (Long, dst, { fn = Global "ocamlcc_alloc_float"; args = [ (Double, d) ] }));
  mark_heap b dst

let bint_spec : Lambda.boxed_integer -> ty * int32 * int64 = function
  | Pint32 -> (Word, custom_kind_int32, 31L)
  | Pint64 -> (Long, custom_kind_int64, 63L)
  | Pnativeint -> (Long, custom_kind_nativeint, 63L)

let unbox_bint b bi (v : t) : t =
  let ty, _, _ = bint_spec bi in
  let op = match ty with Word -> Loadw | Long | Double -> Loadl in
  let dst = fresh_temp b "bi" in
  emit b (Load (op, ty, dst, v));
  dst

let box_bint b bi (raw : t) : t =
  let ty, kind, _ = bint_spec bi in
  let bits =
    match ty with
    | Word ->
        let ext = fresh_temp b "bext" in
        emit b (Extsw (ext, raw));
        ext
    | Long | Double -> raw
  in
  let dst = fresh_temp b "bbox" in
  emit b
    (Call
       ( Long,
         dst,
         { fn = Global "ocamlcc_alloc_custom";
           args = [ (Long, Int (Int64.of_int32 kind)); (Long, bits) ] } ));
  mark_heap b dst

let compile_bint_div_mod b ~boxed bi qop ua uc : t =
  let ty, _, _ = bint_spec bi in
  let wrap raw = if boxed then box_bint b bi raw else raw in
  let result_ty = if boxed then Long else ty in
  let failure = if boxed then unit_const else Int 0L in
  let lok = fresh_label b "bdiv_ok" in
  let lcheck = fresh_label b "bdiv_chk" in
  let lneg1 = fresh_label b "bdiv_m1" in
  let lzero = fresh_label b "bdiv_zero" in
  let ldone = fresh_label b "bdiv_done" in
  let nz = fresh_temp b "bdiv_nz" in
  emit b (Cmp (Ne, ty, nz, uc, Int 0L));
  close_block b (Br (nz, lcheck, lzero));
  start_block b lcheck;
  let is_m1 = fresh_temp b "ism1" in
  emit b (Cmp (Eq, ty, is_m1, uc, Int (-1L)));
  close_block b (Br (is_m1, lneg1, lok));
  start_block b lok;
  let raw_ok = fresh_temp b "bdivr" in
  emit b (Binop (qop, ty, raw_ok, ua, uc));
  let res_ok = wrap raw_ok in
  let lok_end = open_label b in
  close_block b (Jmp ldone);
  start_block b lneg1;
  let res_m1 =
    match qop with
    | Binop.Div ->
        let neg_a = fresh_temp b "bdivneg" in
        emit b (Binop (Binop.Sub, ty, neg_a, Int 0L, ua));
        wrap neg_a
    | _ -> wrap (Int 0L)
  in
  let lm1_end = open_label b in
  close_block b (Jmp ldone);
  start_block b lzero;
  let ex = fresh_temp b "divex" in
  emit b (Load (Loadl, Long, ex, Global "ocamlcc_global_Division_by_zero"));
  emit b (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, ex) ] });
  let lzero_end = open_label b in
  close_block b (Jmp ldone);
  start_block b ldone;
  let dst = fresh_temp b "bdivv" in
  emit b
    (Phi
       ( result_ty,
         dst,
         [ (lok_end, res_ok); (lm1_end, res_m1); (lzero_end, failure) ] ));
  dst

let compile_raw_bint_shift b bi qop ua cv : t =
  let ty, _, mask = bint_spec bi in
  let uc = untag b cv in
  let shw = fresh_temp b "shw" in
  emit b (Copy (Word, shw, uc));
  let shm = fresh_temp b "shm" in
  emit b (Binop (And, Word, shm, shw, Int mask));
  let res = fresh_temp b "bsh" in
  emit b (Binop (qop, ty, res, ua, shm));
  res

let float_compare b ~boxed (cmp : Lambda.float_comparison) lhs rhs =
  let da = if boxed then load_double b lhs else lhs in
  let db = if boxed then load_double b rhs else rhs in
  let fop, negate =
    match cmp with
    | CFeq -> (Fcmp.Feq, false)
    | CFneq -> (Fcmp.Fne, false)
    | CFlt -> (Fcmp.Flt, false)
    | CFle -> (Fcmp.Fle, false)
    | CFgt -> (Fcmp.Fgt, false)
    | CFge -> (Fcmp.Fge, false)
    | CFnlt -> (Fcmp.Flt, true)
    | CFnle -> (Fcmp.Fle, true)
    | CFngt -> (Fcmp.Fgt, true)
    | CFnge -> (Fcmp.Fge, true)
  in
  let raw = fresh_temp b "fcmp" in
  emit b (Fcmp (fop, Long, raw, da, db));
  let fin =
    if not negate then raw
    else
      let inv = fresh_temp b "fninv" in
      emit b (Binop (Xor, Long, inv, raw, Int 1L));
      inv
  in
  retag b fin

let integer_compare b ~boxed kind relation lhs rhs =
  let lhs = if boxed then unbox_bint b kind lhs else lhs in
  let rhs = if boxed then unbox_bint b kind rhs else rhs in
  let ty, _, _ = bint_spec kind in
  let compare op =
    let raw = fresh_temp b "bcmp" in
    emit b (Cmp (op, ty, raw, lhs, rhs));
    raw
  in
  let raw =
    match relation with
    | Anf.Predicate cmp -> compare (cmp_of_ocaml cmp)
    | Three_way ->
        let gt = compare Sgt in
        let lt = compare Slt in
        let diff = fresh_temp b "bcdiff" in
        emit b (Binop (Sub, Word, diff, gt, lt));
        diff
  in
  let extended = fresh_temp b "bcmp_l" in
  emit b (Extsw (extended, raw));
  retag b extended

let float_binop b ~boxed op lhs rhs =
  let left = if boxed then load_double b lhs else lhs in
  let right = if boxed then load_double b rhs else rhs in
  let qop =
    match op with
    | Anf.Addf -> Binop.Add
    | Subf -> Binop.Sub
    | Mulf -> Binop.Mul
    | Divf -> Binop.Div
  in
  let result = fresh_temp b "fop" in
  emit b (Binop (qop, Double, result, left, right));
  if boxed then box_double b result else result

let qbe_integer_arithmetic : Anf.integer_arithmetic -> Binop.t = function
  | Add_int -> Add | Sub_int -> Sub | Mul_int -> Mul
  | Div_int -> Div | Rem_int -> Rem
  | And_int -> And | Or_int -> Or | Xor_int -> Xor

let qbe_integer_shift : Anf.integer_shift -> Binop.t = function
  | Left_shift -> Shl | Logical_right -> Shr | Arithmetic_right -> Sar

let narrow_integer b raw =
  let word = fresh_temp b "int_word" in
  emit b (Copy (Word, word, raw));
  word

let extend_integer b raw =
  let long = fresh_temp b "int_long" in
  emit b (Extsw (long, raw));
  long

let integer_of_int b kind value =
  let raw = untag b value in
  match kind with
  | Lambda.Pint32 -> narrow_integer b raw
  | Pint64 | Pnativeint -> raw

let int_of_integer b kind raw =
  let long = match kind with
    | Lambda.Pint32 -> extend_integer b raw
    | Pint64 | Pnativeint -> raw
  in
  retag b long

let convert_integer b (src : Lambda.boxed_integer) (dst : Lambda.boxed_integer) raw =
  match src, dst with
  | Lambda.Pint32, (Pint64 | Pnativeint) -> extend_integer b raw
  | (Pint64 | Pnativeint), Pint32 -> narrow_integer b raw
  | _ -> raw

let float_of_int b value =
  let raw = untag b value in
  let dst = fresh_temp b "fofint" in
  emit b (Sltof (Double, dst, raw));
  dst

let int_of_float b value =
  let raw = fresh_temp b "ioff" in
  emit b (Dtosi (Long, raw, value));
  retag b raw

let float_sign b op value =
  match op with
  | `Neg ->
      let dst = fresh_temp b "fneg" in
      emit b (Neg (Double, dst, value));
      dst
  | `Abs ->
      let bits = fresh_temp b "fbits" in
      emit b (Cast (Long, bits, value));
      let masked = fresh_temp b "fabsm" in
      emit b (Binop (And, Long, masked, bits, Int 0x7fffffffffffffffL));
      let dst = fresh_temp b "fabsd" in
      emit b (Cast (Double, dst, masked));
      dst

let scalar_access_symbol op (access : Anf.bigarray_access) =
  let kind =
    match access.kind with
    | Lambda.Pbigarray_float32 -> "float32"
    | Pbigarray_float64 -> "float64"
    | Pbigarray_int32 -> "int32"
    | Pbigarray_int64 | Pbigarray_native_int -> "int64"
    | _ -> assert false
  in
  Printf.sprintf "ocamlcc_ba_%s_%s_1" op kind

let scalar_type = function
  | Anf.Double_scalar -> Double
  | Integer_scalar kind -> let ty, _, _ = bint_spec kind in ty

let scalar_store = function
  | Double -> Stored
  | Word -> Storew
  | Long -> Storel

let compare_floats b lhs rhs =
  let result = fresh_temp b "fcmp_v" in
  emit b (Call (Long, result,
    { fn = Global "caml_compare"; args = [(Long, lhs); (Long, rhs)] }));
  result

let integer_binop b ~boxed kind arithmetic lhs rhs =
  let lhs = if boxed then unbox_bint b kind lhs else lhs in
  let rhs = if boxed then unbox_bint b kind rhs else rhs in
  let qop = qbe_integer_arithmetic arithmetic in
  match arithmetic with
  | Anf.Div_int | Rem_int -> compile_bint_div_mod b ~boxed kind qop lhs rhs
  | Add_int | Sub_int | Mul_int | And_int | Or_int | Xor_int ->
      let dst = fresh_temp b (if boxed then "bop" else "integer_op") in
      emit b (Binop (qop, scalar_type (Integer_scalar kind), dst, lhs, rhs));
      if boxed then box_bint b kind dst else dst

let integer_shift b ~boxed kind shift lhs count =
  let lhs = if boxed then unbox_bint b kind lhs else lhs in
  let value = compile_raw_bint_shift b kind (qbe_integer_shift shift) lhs count in
  if boxed then box_bint b kind value else value

let integer_neg b ~boxed kind value =
  let value = if boxed then unbox_bint b kind value else value in
  let dst = fresh_temp b (if boxed then "bneg" else "integer_neg") in
  let ty = scalar_type (Integer_scalar kind) in
  if boxed then begin
    emit b (Neg (ty, dst, value));
    box_bint b kind dst
  end else begin
    emit b (Binop (Sub, ty, dst, Int 0L, value));
    dst
  end

let load_bigarray b access args =
  let ty = scalar_type (Option.get (Anf.scalar_rep access.Anf.kind)) in
  let dst = fresh_temp b "scalar_load" in
  emit b (Call (ty, dst, { fn = Global (scalar_access_symbol "get" access); args }));
  dst

let store_bigarray b access args rep value =
  emit b (Call_void { fn = Global (scalar_access_symbol "set" access);
                      args = args @ [scalar_type rep, value] });
  unit_const

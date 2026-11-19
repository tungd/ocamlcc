(* Codegen expression, control-flow, and primitive lowering. *)

open Codegen_ctx
open Qbe_il

type fn_hooks = {
  closure_value : Codegen_ctx.t -> Ident.t -> Qbe_il.t;
  compile_fun_binding :
    (Codegen_ctx.t -> bool -> Anf.aexpr -> Qbe_il.t) ->
    Codegen_ctx.t ->
    bool ->
    Ident.t ->
    Anf.lfunction ->
    Anf.aexpr ->
    Qbe_il.t;
  compile_letrec :
    (Codegen_ctx.t -> bool -> Anf.aexpr -> Qbe_il.t) ->
    Codegen_ctx.t ->
    bool ->
    Anf.rec_binding list ->
    Anf.aexpr ->
    Qbe_il.t;
}

let static_payload_ptr b base_name sym =
  let dst = fresh_temp b base_name in
  emit b (Binop (Add, Long, dst, Global sym, Int 16L));
  dst

let compile_atom hooks b (a : Anf.atom) : t =
  match a with
  | Int n -> Int (tag_int n)
  | Char c -> Int (tag_int (Char.code c))
  | Unit -> unit_const
  | String s -> static_payload_ptr b "str" (string_data b s)
  | Float f -> static_payload_ptr b "flt" (float_data b f)
  | Int32 n ->
      static_payload_ptr b "i32"
        (custom_data b custom_kind_int32 (Int64.of_int32 n))
  | Int64 n ->
      static_payload_ptr b "i64" (custom_data b custom_kind_int64 n)
  | Nativeint n ->
      static_payload_ptr b "nat"
        (custom_data b custom_kind_nativeint (Int64.of_nativeint n))
  | ConstFloatArray fs ->
      static_payload_ptr b "farr" (float_array_data b fs)
  | ConstBlock (tag, items) ->
      static_payload_ptr b "cblk" (emit_const_block b tag items)
  | Var id -> (
      match Hashtbl.find_opt b.vars id with
      | Some v -> v
      | None -> (
          match Hashtbl.find_opt b.funs id with
          | Some info when not info.has_closure -> hooks.closure_value b id
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

let compile_div_mod b qop (av : t) (cv : t) : t =
  let ua = untag b av in
  let uc = untag b cv in
  let lok = fresh_label b "div_ok" in
  let lzero = fresh_label b "div_zero" in
  let ldone = fresh_label b "div_done" in
  let nz = fresh_temp b "div_nz" in
  emit b (Cmp (Ne, Long, nz, uc, Int 0L));
  close_block b (Br (nz, lok, lzero));
  start_block b lok;
  let raw = fresh_temp b "divr" in
  emit b (Binop (qop, Long, raw, ua, uc));
  let res = retag b raw in
  let lok_end = b.cur_fn.open_label in
  close_block b (Jmp ldone);
  start_block b lzero;
  let ex = fresh_temp b "divex" in
  emit b (Load (Loadl, Long, ex, Global "ocamlcc_global_Division_by_zero"));
  emit b (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, ex) ] });
  let lzero_end = b.cur_fn.open_label in
  close_block b (Jmp ldone);
  start_block b ldone;
  let dst = fresh_temp b "divv" in
  emit b (Phi (Long, dst, [ (lok_end, res); (lzero_end, unit_const) ]));
  dst

let load_double b (v : t) : t =
  let d = fresh_temp b "fval" in
  emit b (Load (Loadd, Double, d, v));
  d

let box_double b (d : t) : t =
  let dst = fresh_temp b "fbox" in
  emit b
    (Call (Long, dst, { fn = Global "ocamlcc_alloc_float"; args = [ (Double, d) ] }));
  dst

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
  dst

let compile_bint_div_mod b bi qop (av : t) (cv : t) : t =
  let ty, _, _ = bint_spec bi in
  let ua = unbox_bint b bi av in
  let uc = unbox_bint b bi cv in
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
  let res_ok = box_bint b bi raw_ok in
  let lok_end = b.cur_fn.open_label in
  close_block b (Jmp ldone);
  start_block b lneg1;
  let res_m1 =
    match qop with
    | Binop.Div ->
        let neg_a = fresh_temp b "bdivneg" in
        emit b (Binop (Binop.Sub, ty, neg_a, Int 0L, ua));
        box_bint b bi neg_a
    | _ -> box_bint b bi (Int 0L)
  in
  let lm1_end = b.cur_fn.open_label in
  close_block b (Jmp ldone);
  start_block b lzero;
  let ex = fresh_temp b "divex" in
  emit b (Load (Loadl, Long, ex, Global "ocamlcc_global_Division_by_zero"));
  emit b (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, ex) ] });
  let lzero_end = b.cur_fn.open_label in
  close_block b (Jmp ldone);
  start_block b ldone;
  let dst = fresh_temp b "bdivv" in
  emit b
    (Phi
       ( Long,
         dst,
         [ (lok_end, res_ok); (lm1_end, res_m1); (lzero_end, unit_const) ] ));
  dst

let compile_bint_shift b bi qop av cv : t =
  let ty, _, mask = bint_spec bi in
  let ua = unbox_bint b bi av in
  let uc = untag b cv in
  let shw = fresh_temp b "shw" in
  emit b (Copy (Word, shw, uc));
  let shm = fresh_temp b "shm" in
  emit b (Binop (And, Word, shm, shw, Int mask));
  let res = fresh_temp b "bsh" in
  emit b (Binop (qop, ty, res, ua, shm));
  box_bint b bi res

let compile_fcmp b (cmp : Lambda.float_comparison) da db : t =
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

let compile_float_arithmetic b op left right =
  let qop =
    match op with
    | Anf.Addf -> Binop.Add
    | Subf -> Binop.Sub
    | Mulf -> Binop.Mul
    | Divf -> Binop.Div
  in
  let result = fresh_temp b "fop" in
  emit b (Binop (qop, Double, result, left, right));
  result

let compile_binop hooks b (op : Anf.binop) (a : Anf.atom) (c : Anf.atom) : t =
  let av = compile_atom hooks b a in
  let cv = compile_atom hooks b c in
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
  | Float_arithmetic op ->
      let da = load_double b av in
      let db = load_double b cv in
      box_double b (compile_float_arithmetic b op da db)
  | Fcmp cmp ->
      let da = load_double b av in
      let db = load_double b cv in
      compile_fcmp b cmp da db
  | Compare_floats ->
      let dst = fresh_temp b "fcmp_v" in
      emit b
        (Call (Long, dst, { fn = Global "caml_compare"; args = [ (Long, av); (Long, cv) ] }));
      dst
  | Bint_add bi | Bint_sub bi | Bint_mul bi | Bint_and bi | Bint_or bi | Bint_xor bi ->
      let ty, _, _ = bint_spec bi in
      let ua = unbox_bint b bi av in
      let uc = unbox_bint b bi cv in
      let qop =
        match op with
        | Bint_add _ -> Binop.Add
        | Bint_sub _ -> Binop.Sub
        | Bint_mul _ -> Binop.Mul
        | Bint_and _ -> Binop.And
        | Bint_or _ -> Binop.Or
        | Bint_xor _ -> Binop.Xor
        | _ -> assert false
      in
      let res = fresh_temp b "bop" in
      emit b (Binop (qop, ty, res, ua, uc));
      box_bint b bi res
  | Bint_div bi -> compile_bint_div_mod b bi Div av cv
  | Bint_mod bi -> compile_bint_div_mod b bi Rem av cv
  | Bint_lsl bi -> compile_bint_shift b bi Shl av cv
  | Bint_lsr bi -> compile_bint_shift b bi Shr av cv
  | Bint_asr bi -> compile_bint_shift b bi Sar av cv
  | Bint_cmp (bi, cmp) ->
      let ty, _, _ = bint_spec bi in
      let ua = unbox_bint b bi av in
      let uc = unbox_bint b bi cv in
      let raw = fresh_temp b "bcmp" in
      emit b (Cmp (cmp_of_ocaml cmp, ty, raw, ua, uc));
      let raw_l =
        match ty with
        | Word ->
            let ext = fresh_temp b "bcmp_l" in
            emit b (Extsw (ext, raw));
            ext
        | Long | Double -> raw
      in
      retag b raw_l
  | Compare_bints bi ->
      let ty, _, _ = bint_spec bi in
      let ua = unbox_bint b bi av in
      let uc = unbox_bint b bi cv in
      let gt = fresh_temp b "bcgt" in
      let lt = fresh_temp b "bclt" in
      let diff = fresh_temp b "bcdiff" in
      emit b (Cmp (Sgt, ty, gt, ua, uc));
      emit b (Cmp (Slt, ty, lt, ua, uc));
      emit b (Binop (Sub, ty, diff, gt, lt));
      let diff_l =
        match ty with
        | Word ->
            let ext = fresh_temp b "bdiff_l" in
            emit b (Extsw (ext, diff));
            ext
        | Long | Double -> diff
      in
      retag b diff_l

let compile_unop hooks b (op : Anf.unop) (a : Anf.atom) : t =
  let av = compile_atom hooks b a in
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
  | Float_of_int ->
      let ua = untag b av in
      let d = fresh_temp b "fofint" in
      emit b (Sltof (Double, d, ua));
      box_double b d
  | Int_of_float ->
      let d = load_double b av in
      let raw = fresh_temp b "ioff" in
      emit b (Dtosi (Long, raw, d));
      retag b raw
  | Fneg ->
      let d = load_double b av in
      let r = fresh_temp b "fneg" in
      emit b (Neg (Double, r, d));
      box_double b r
  | Fabs ->
      let bits = fresh_temp b "fbits" in
      emit b (Load (Loadl, Long, bits, av));
      let masked = fresh_temp b "fabsm" in
      emit b (Binop (And, Long, masked, bits, Int 0x7fffffffffffffffL));
      let d = fresh_temp b "fabsd" in
      emit b (Cast (Double, d, masked));
      box_double b d
  | Bint_of_int bi ->
      let ty, _, _ = bint_spec bi in
      let ua = untag b av in
      let raw =
        match ty with
        | Word ->
            let w = fresh_temp b "i2w" in
            emit b (Copy (Word, w, ua));
            w
        | Long | Double -> ua
      in
      box_bint b bi raw
  | Int_of_bint bi ->
      let raw = unbox_bint b bi av in
      let raw_l =
        match bint_spec bi with
        | Word, _, _ ->
            let ext = fresh_temp b "w2l" in
            emit b (Extsw (ext, raw));
            ext
        | (Long | Double), _, _ -> raw
      in
      retag b raw_l
  | Bint_neg bi ->
      let ty, _, _ = bint_spec bi in
      let ua = unbox_bint b bi av in
      let r = fresh_temp b "bneg" in
      emit b (Neg (ty, r, ua));
      box_bint b bi r
  | Bint_cvt (src, dst) ->
      let u = unbox_bint b src av in
      let dst_ty, _, _ = bint_spec dst in
      let converted =
        match (src, dst_ty) with
        | Pint32, Long ->
            let ext = fresh_temp b "cvt_ext" in
            emit b (Extsw (ext, u));
            ext
        | (Pint64 | Pnativeint), Word ->
            let w = fresh_temp b "cvt_tr" in
            emit b (Copy (Word, w, u));
            w
        | _ -> u
      in
      box_bint b dst converted

let apply_closure b clos_val (arg_vals : t list) : t =
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

let rec apply hooks b tail (fn_atom : Anf.atom) (ap_args : Anf.atom list) : t =
  let is_self id =
    match b.cur_fn.self with
    | Some s -> Ident.same s id
    | None -> false
  in
  match fn_atom with
  | Var id -> (
      match Hashtbl.find_opt b.funs id with
      | Some info when List.length ap_args = info.arity -> (
          if info.has_closure then begin
            if tail && is_self id then begin
              let vs = List.map (compile_atom hooks b) ap_args in
              b.cur_fn.tail_sites <- (b.cur_fn.open_label, vs) :: b.cur_fn.tail_sites;
              close_block b (Jmp b.cur_fn.entry_label);
              unit_const
            end
            else begin
              let clos_val = Hashtbl.find b.vars id in
              let arg_vals = List.map (compile_atom hooks b) ap_args in
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
            | Some tag, true when b.cur_fn.cur_group = info.group_name ->
                let vs =
                  pad_to info.group_arity
                    (List.map (compile_atom hooks b) ap_args)
                in
                b.cur_fn.tail_sites <-
                  (b.cur_fn.open_label, Int tag :: vs) :: b.cur_fn.tail_sites;
                close_block b (Jmp b.cur_fn.entry_label);
                unit_const
            | Some tag, _ ->
                let vs =
                  pad_to info.group_arity
                    (List.map (compile_atom hooks b) ap_args)
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
                let vs = List.map (compile_atom hooks b) ap_args in
                b.cur_fn.tail_sites <- (b.cur_fn.open_label, vs) :: b.cur_fn.tail_sites;
                close_block b (Jmp b.cur_fn.entry_label);
                unit_const
            | None, _ ->
                let args =
                  List.map (fun a -> (Long, compile_atom hooks b a)) ap_args
                in
                let dst = fresh_temp b "call" in
                emit b (Call (Long, dst, { fn = Global info.global; args }));
                dst)
      | Some info when List.length ap_args > info.arity ->
          let first_args, rest_args = split_at info.arity ap_args in
          let clos_res = apply hooks b false fn_atom first_args in
          let rest_vals = List.map (compile_atom hooks b) rest_args in
          let ex = fresh_temp b "oex" in
          emit b (Call (Long, ex, { fn = Global "ocamlcc_get_exn"; args = [] }));
          let lerr = fresh_label b "oapp_err" in
          let lok = fresh_label b "oapp_ok" in
          let ljoin = fresh_label b "oapp_join" in
          let has_ex = fresh_temp b "ohasex" in
          emit b (Cmp (Ne, Long, has_ex, ex, Int 0L));
          close_block b (Br (has_ex, lerr, lok));
          start_block b lerr;
          List.iter
            (fun v ->
              emit b
                (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] }))
            rest_vals;
          let lerr_end = b.cur_fn.open_label in
          close_block b (Jmp ljoin);
          start_block b lok;
          let final_v = apply_closure b clos_res rest_vals in
          emit b
            (Call_void
               { fn = Global "arc_release_val"; args = [ (Long, clos_res) ] });
          let lok_end = b.cur_fn.open_label in
          close_block b (Jmp ljoin);
          start_block b ljoin;
          let dst = fresh_temp b "oapp" in
          emit b (Phi (Long, dst, [ (lerr_end, unit_const); (lok_end, final_v) ]));
          dst
      | Some info ->
          let clos_val =
            if info.has_closure then Hashtbl.find b.vars id
            else hooks.closure_value b id
          in
          let arg_vals = List.map (compile_atom hooks b) ap_args in
          apply_closure b clos_val arg_vals
      | None ->
          let clos_val = compile_atom hooks b fn_atom in
          let arg_vals = List.map (compile_atom hooks b) ap_args in
          apply_closure b clos_val arg_vals)
  | _ ->
      let clos_val = compile_atom hooks b fn_atom in
      let arg_vals = List.map (compile_atom hooks b) ap_args in
      apply_closure b clos_val arg_vals

let compile_ccall hooks b sym args =
  let dst = fresh_temp b "cc" in
  let cargs = List.map (fun a -> (Long, compile_atom hooks b a)) args in
  emit b (Call (Long, dst, { fn = Global sym; args = cargs }));
  dst

let compile_scalar_operand hooks b rep = function
  | Anf.Raw_scalar id -> Hashtbl.find b.vars id
  | Boxed_scalar a ->
      let boxed = compile_atom hooks b a in
      match rep with
      | Anf.Double_scalar -> load_double b boxed
      | Integer_scalar kind -> unbox_bint b kind boxed

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

let compile_cexpr hooks b ~tail (ce : Anf.cexpr) : t =
  match ce with
  | Atom a -> compile_atom hooks b a
  | Binop (op, a, c) -> compile_binop hooks b op a c
  | Unop (op, a) -> compile_unop hooks b op a
  | MakeBlock (tag, args) ->
      emit_block_alloc b tag (List.map (compile_atom hooks b) args)
  | AllocReuse (tok_id, tag, args) ->
      let tok = Hashtbl.find b.vars tok_id in
      emit_block_alloc b ~reuse_tok:tok tag (List.map (compile_atom hooks b) args)
  | MakeArray (kind, args) -> (
      let vs = List.map (compile_atom hooks b) args in
      let n = List.length vs in
      match kind with
      | Lambda.Pfloatarray ->
          let arr = fresh_temp b "farr" in
          emit b
            (Call
               ( Long,
                 arr,
                 { fn = Global "arc_alloc";
                   args =
                     [ (Long, Int (Int64.of_int arc_tag_float_array));
                       (Long, Int 0L);
                       (Long, Int (Int64.of_int (8 * n))) ] } ));
          List.iteri
            (fun i v ->
              let d = load_double b v in
              let addr = ptr_offset b arr (8 * i) "farrp" in
              emit b (Store (Stored, d, addr));
              emit b (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] }))
            vs;
          arr
      | Lambda.Pgenarray when n > 0 ->
          let buf = fresh_temp b "gbuf" in
          emit b (Alloc8 (buf, Int (Int64.of_int (8 * n))));
          List.iteri
            (fun i v ->
              let addr = ptr_offset b buf (8 * i) "gbufp" in
              emit b (Store (Storel, v, addr)))
            vs;
          let arr = fresh_temp b "garr" in
          emit b
            (Call
               ( Long,
                 arr,
                 { fn = Global "ocamlcc_gen_makearray";
                   args = [ (Long, Int (Int64.of_int n)); (Long, buf) ] } ));
          arr
      | Lambda.Pintarray | Paddrarray | Pgenarray ->
          let scan =
            match kind with
            | Lambda.Pintarray -> 0
            | Pgenarray | Paddrarray | Pfloatarray -> min n 0xffff
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
          arr)
  | Field (i, arg) ->
      let obj = compile_atom hooks b arg in
      let addr = ptr_offset b obj (8 * i) "fldp" in
      let dst = fresh_temp b "fld" in
      emit b (Load (Loadl, Long, dst, addr));
      emit b (Call_void { fn = Global "arc_retain_val"; args = [ (Long, dst) ] });
      dst
  | SetField (i, arg, rhs) ->
      let obj = compile_atom hooks b arg in
      let v = compile_atom hooks b rhs in
      let addr = ptr_offset b obj (8 * i) "fldp" in
      let old_v = fresh_temp b "oldf" in
      emit b (Load (Loadl, Long, old_v, addr));
      emit b (Store (Storel, v, addr));
      emit b
        (Call_void { fn = Global "arc_release_val"; args = [ (Long, old_v) ] });
      unit_const
  | FloatField (i, arg) ->
      let obj = compile_atom hooks b arg in
      let addr = ptr_offset b obj (8 * i) "ffldp" in
      box_double b (load_double b addr)
  | SetFloatField (i, arg, rhs) ->
      let obj = compile_atom hooks b arg in
      let v = compile_atom hooks b rhs in
      let d = load_double b v in
      let addr = ptr_offset b obj (8 * i) "ffldp" in
      emit b (Store (Stored, d, addr));
      unit_const
  | OffsetRef (k, arg) ->
      let obj = compile_atom hooks b arg in
      let cur = fresh_temp b "refv" in
      emit b (Load (Loadl, Long, cur, obj));
      let next = fresh_temp b "refn" in
      emit b (Binop (Add, Long, next, cur, Int (Int64.mul (Int64.of_int k) 2L)));
      emit b (Store (Storel, next, obj));
      unit_const
  | StringGet (safe, s, idx) ->
      let sv = compile_atom hooks b s in
      let iv = compile_atom hooks b idx in
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
      let bsv = compile_atom hooks b bs in
      let iv = compile_atom hooks b idx in
      let cv = compile_atom hooks b ch in
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
  | ArrayGet (safe, kind, arr, idx) -> (
      let av = compile_atom hooks b arr in
      let iv = compile_atom hooks b idx in
      match kind with
      | Lambda.Pgenarray ->
          let dst = fresh_temp b "gavel" in
          emit b
            (Call
               ( Long,
                 dst,
                 { fn = Global "ocamlcc_gen_array_get";
                   args =
                     [ (Long, Int (if safe then 1L else 0L));
                       (Long, av);
                       (Long, iv) ] } ));
          dst
      | Lambda.Pfloatarray ->
          let ui = untag b iv in
          let do_read () =
            let off = fresh_temp b "aoff" in
            emit b (Binop (Shl, Long, off, ui, Int 3L));
            let eaddr = fresh_temp b "arrp" in
            emit b (Binop (Add, Long, eaddr, av, off));
            box_double b (load_double b eaddr)
          in
          if safe then
            let len = array_len_raw b av in
            compile_bounds_guarded b ui len do_read
          else do_read ()
      | Lambda.Paddrarray | Pintarray ->
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
          else do_read ())
  | ArraySet (safe, kind, arr, idx, v) -> (
      let av = compile_atom hooks b arr in
      let iv = compile_atom hooks b idx in
      let vv = compile_atom hooks b v in
      match kind with
      | Lambda.Pgenarray ->
          let dst = fresh_temp b "gaset" in
          emit b
            (Call
               ( Long,
                 dst,
                 { fn = Global "ocamlcc_gen_array_set";
                   args =
                     [ (Long, Int (if safe then 1L else 0L));
                       (Long, av);
                       (Long, iv);
                       (Long, vv) ] } ));
          unit_const
      | Lambda.Pfloatarray ->
          let ui = untag b iv in
          let do_write () =
            let off = fresh_temp b "aoff" in
            emit b (Binop (Shl, Long, off, ui, Int 3L));
            let eaddr = fresh_temp b "arrp" in
            emit b (Binop (Add, Long, eaddr, av, off));
            let d = load_double b vv in
            emit b (Store (Stored, d, eaddr));
            emit b (Call_void { fn = Global "arc_release_val"; args = [ (Long, vv) ] });
            unit_const
          in
          if safe then
            let len = array_len_raw b av in
            compile_bounds_guarded b ~drop_on_oob:vv ui len do_write
          else do_write ()
      | Lambda.Pintarray | Paddrarray ->
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
          else do_write ())
  | CreateBytes len ->
      let lv = compile_atom hooks b len in
      let ul = untag b lv in
      let dst = fresh_temp b "bytes" in
      emit b
        (Call (Long, dst, { fn = Global "arc_alloc_bytes"; args = [ (Long, ul) ] }));
      dst
  | MakeArrayInit (len, init) ->
      let lv = compile_atom hooks b len in
      let iv = compile_atom hooks b init in
      let ul = untag b lv in
      let dst = fresh_temp b "arr" in
      emit b
        (Call
           ( Long,
             dst,
             { fn = Global "arc_alloc_array"; args = [ (Long, ul); (Long, iv) ] } ));
      dst
  | Builtin (symbol, arg_kind, arg) ->
      let v = compile_atom hooks b arg in
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
  | ScalarLoad (access, arr, index) ->
      let args = List.map (fun a -> Long, compile_atom hooks b a) [arr; index] in
      let ty = scalar_type (Option.get (Anf.scalar_rep access.kind)) in
      let dst = fresh_temp b "scalar_load" in
      emit b (Call (ty, dst, { fn = Global (scalar_access_symbol "get" access); args }));
      dst
  | ScalarValue (rep, value) -> compile_scalar_operand hooks b rep value
  | FloatBinop (op, lhs, rhs) ->
      let l = compile_scalar_operand hooks b Double_scalar lhs in
      let r = compile_scalar_operand hooks b Double_scalar rhs in
      compile_float_arithmetic b op l r
  | IntegerBinop (kind, op, lhs, rhs) ->
      let rep = Anf.Integer_scalar kind in
      let l = compile_scalar_operand hooks b rep lhs in
      let r = compile_scalar_operand hooks b rep rhs in
      let qop = match op with
        | Add_int -> Binop.Add | Sub_int -> Binop.Sub | Mul_int -> Binop.Mul
      in
      let dst = fresh_temp b "integer_op" in
      emit b (Binop (qop, scalar_type rep, dst, l, r));
      dst
  | ScalarStore (access, arr, index, value) ->
      let args = List.map (fun a -> Long, compile_atom hooks b a) [arr; index] in
      let rep = Option.get (Anf.scalar_rep access.kind) in
      let v = compile_scalar_operand hooks b rep value in
      emit b (Call_void { fn = Global (scalar_access_symbol "set" access);
                          args = args @ [scalar_type rep, v] });
      unit_const
  | BigarrayAccess (access, args) ->
      let op = match access.operation with `Get -> "get" | `Set -> "set" in
      compile_ccall hooks b (Printf.sprintf "caml_ba_%s_%d" op access.rank) args
  | Ccall (sym, args) -> compile_ccall hooks b sym args
  | GetGlobal mod_name ->
      let gsym = "ocamlcc_global_" ^ sanitize mod_name in
      let gv = fresh_temp b "glob" in
      emit b (Load (Loadl, Long, gv, Global gsym));
      emit b (Call_void { fn = Global "arc_retain_val"; args = [ (Long, gv) ] });
      gv
  | App (fn, args) -> apply hooks b tail fn args
  | Fun _ -> failwith "codegen: Fun must be bound by Let"
  | Assign (id, rhs) -> (
      let v = compile_atom hooks b rhs in
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

let emit_unwind b : t =
  match b.cur_fn.try_stack with
  | lcatch :: _ ->
      close_block b (Jmp lcatch);
      unit_const
  | [] ->
      if b.cur_fn.in_init then begin
        let ex = fresh_temp b "unex" in
        emit b (Call (Long, ex, { fn = Global "ocamlcc_get_exn"; args = [] }));
        emit b
          (Call_void { fn = Global "arc_release_val"; args = [ (Long, ex) ] });
        emit b
          (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, Int 0L) ] });
        emit b (Call_void { fn = Global "pal_abort"; args = [] });
        close_block b Hlt;
        unit_const
      end
      else begin
        close_block b (Ret (Some unit_const));
        unit_const
      end

let rec compile_aexpr hooks b (tail : bool) (e : Anf.aexpr) : t =
  match e with
  | Halt a -> compile_atom hooks b a
  | HaltScalar id -> Hashtbl.find b.vars id
  | Let (id, Fun lf, body) ->
      hooks.compile_fun_binding (compile_aexpr hooks) b tail id lf body
  | Let (id, (App _ as ce), Halt (Var v)) when tail && Ident.same id v ->
      compile_cexpr hooks b ~tail:true ce
  | Let (id, ce, body) ->
      let v = compile_cexpr hooks b ~tail:false ce in
      if b.cur_fn.term <> None then unit_const
      else begin
        Hashtbl.replace b.vars id v;
        let res = compile_aexpr hooks b tail body in
        Hashtbl.remove b.vars id;
        res
      end
  | MutLet (id, ce, body) ->
      let v = compile_cexpr hooks b ~tail:false ce in
      let slot = fresh_temp b "mslot" in
      emit b (Alloc8 (slot, Int 8L));
      emit b (Store (Storel, v, slot));
      Hashtbl.replace b.mut_vars id slot;
      let res = compile_aexpr hooks b tail body in
      Hashtbl.remove b.mut_vars id;
      res
  | LetJoin (id, rhs, body) ->
      let v = compile_aexpr hooks b false rhs in
      if b.cur_fn.term <> None then unit_const
      else begin
        Hashtbl.replace b.vars id v;
        let res = compile_aexpr hooks b tail body in
        Hashtbl.remove b.vars id;
        res
      end
  | LetRec (bindings, body) ->
      hooks.compile_letrec (compile_aexpr hooks) b tail bindings body
  | If (cond, th, el) -> compile_if hooks b tail Long cond th el
  | ScalarIf (rep, cond, th, el) -> compile_if hooks b false (scalar_type rep) cond th el
  | Switch (scrut, sw) -> compile_switch hooks b tail scrut sw
  | StringSwitch (scrut, cases, fail) ->
      compile_stringswitch hooks b tail scrut cases fail
  | StaticCatch (body, id, binders, handler) ->
      staticcatch hooks b tail id binders body handler
  | StaticRaise (id, args) -> (
      match Hashtbl.find_opt b.cur_fn.handlers id with
      | Some h ->
          let vs = List.map (compile_atom hooks b) args in
          h.hpreds <- (b.cur_fn.open_label, vs) :: h.hpreds;
          close_block b (Jmp h.hlabel);
          unit_const
      | None -> failwith "codegen: uncaught static raise")
  | While (cond, body) ->
      let lcond = fresh_label b "wcond" in
      close_block b (Jmp lcond);
      start_block b lcond;
      let cv_tagged = compile_aexpr hooks b false cond in
      if b.cur_fn.term = None then begin
        let lbody = fresh_label b "wbody" in
        let ldone = fresh_label b "wdone" in
        let cv = fresh_temp b "wcmp" in
        emit b (Cmp (Ne, Long, cv, cv_tagged, Int 1L));
        close_block b (Br (cv, lbody, ldone));
        start_block b lbody;
        ignore (compile_aexpr hooks b false body);
        if b.cur_fn.term = None then close_block b (Jmp lcond);
        start_block b ldone
      end;
      unit_const
  | For (id, start_a, stop_a, dir, body) ->
      let sv = compile_atom hooks b start_a in
      let ev = compile_atom hooks b stop_a in
      let enter_op, cont_op, step =
        match dir with
        | Asttypes.Upto -> (Cmp.Sle, Cmp.Slt, 2L)
        | Asttypes.Downto -> (Cmp.Sge, Cmp.Sgt, -2L)
      in
      let enter = fresh_temp b "forenter" in
      emit b (Cmp (enter_op, Long, enter, sv, ev));
      let lpre = b.cur_fn.open_label in
      let lbody = fresh_label b "fbody" in
      let lstep = fresh_label b "fstep" in
      let lnext = fresh_label b "fnext" in
      let ldone = fresh_label b "fdone" in
      let iv = fresh_temp b "fori" in
      let next_i = fresh_temp b "forn" in
      close_block b (Br (enter, lbody, ldone));
      start_block b lbody;
      emit b (Phi (Long, iv, [ (lpre, sv); (lnext, next_i) ]));
      with_shadowed_vars b [ id ] (fun () ->
          Hashtbl.replace b.vars id iv;
          ignore (compile_aexpr hooks b false body));
      if b.cur_fn.term = None then close_block b (Jmp lstep);
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
      let v = compile_atom hooks b (Var id) in
      emit b (Call_void { fn = Global "arc_retain_val"; args = [ (Long, v) ] });
      compile_aexpr hooks b tail body
  | Release (id, body) ->
      let v = compile_atom hooks b (Var id) in
      emit b (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] });
      compile_aexpr hooks b tail body
  | ReleaseMut (id, body) ->
      (match Hashtbl.find_opt b.mut_vars id with
      | Some slot ->
          let v = fresh_temp b "mrel" in
          emit b (Load (Loadl, Long, v, slot));
          emit b
            (Call_void { fn = Global "arc_release_val"; args = [ (Long, v) ] })
      | None -> ());
      compile_aexpr hooks b tail body
  | DropReuse (v_id, tok_id, body) ->
      let v = compile_atom hooks b (Var v_id) in
      let tok = fresh_temp b "rtok" in
      emit b
        (Call (Long, tok, { fn = Global "arc_drop_reuse"; args = [ (Long, v) ] }));
      Hashtbl.replace b.vars tok_id tok;
      let res = compile_aexpr hooks b tail body in
      Hashtbl.remove b.vars tok_id;
      res
  | FreeReuse (tok_id, body) ->
      let tok = Hashtbl.find b.vars tok_id in
      emit b
        (Call_void { fn = Global "arc_free_reuse"; args = [ (Long, tok) ] });
      compile_aexpr hooks b tail body
  | ShadowPush (vars, muts, rtoks, body) ->
      List.iter
        (fun id ->
          let v = compile_atom hooks b (Var id) in
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
      compile_aexpr hooks b tail body
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
      compile_aexpr hooks b tail body
  | Unwind -> emit_unwind b
  | Raise a ->
      let v = compile_atom hooks b a in
      emit b (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, v) ] });
      emit_unwind b
  | CheckExn (on_err, on_ok) ->
      let ex = fresh_temp b "exchk" in
      emit b (Call (Long, ex, { fn = Global "ocamlcc_get_exn"; args = [] }));
      let lerr = fresh_label b "exn_err" in
      let lok = fresh_label b "exn_ok" in
      let has_ex = fresh_temp b "hasex" in
      emit b (Cmp (Ne, Long, has_ex, ex, Int 0L));
      close_block b (Br (has_ex, lerr, lok));
      start_block b lerr;
      ignore (compile_aexpr hooks b false on_err);
      if b.cur_fn.term = None then ignore (emit_unwind b);
      start_block b lok;
      compile_aexpr hooks b tail on_ok
  | TryWith (body, exn_id, handler) ->
      let lcatch = fresh_label b "catch" in
      let ljoin = fresh_label b (if tail then "ret" else "tryj") in
      let res = fresh_temp b (if tail then "res" else "tryv") in
      let preds = ref [] in
      b.cur_fn.try_stack <- lcatch :: b.cur_fn.try_stack;
      let bv = compile_aexpr hooks b tail body in
      b.cur_fn.try_stack <- List.tl b.cur_fn.try_stack;
      if b.cur_fn.term = None then begin
        preds := (b.cur_fn.open_label, bv) :: !preds;
        close_block b (Jmp ljoin)
      end;
      start_block b lcatch;
      let ex = fresh_temp b "exn" in
      emit b (Call (Long, ex, { fn = Global "ocamlcc_get_exn"; args = [] }));
      emit b
        (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, Int 0L) ] });
      Hashtbl.replace b.vars exn_id ex;
      let hv = compile_aexpr hooks b tail handler in
      Hashtbl.remove b.vars exn_id;
      if b.cur_fn.term = None then begin
        preds := (b.cur_fn.open_label, hv) :: !preds;
        close_block b (Jmp ljoin)
      end;
      (match !preds with
      | [] -> unit_const
      | _ ->
          start_block b ljoin;
          emit b (Phi (Long, res, List.rev !preds));
          res)

and compile_if hooks b tail result_ty (cond : Anf.atom) th el =
  let v = compile_atom hooks b cond in
  let cv = fresh_temp b "cond" in
  emit b (Cmp (Ne, Long, cv, v, Int 1L));
  let lthen = fresh_label b "then" in
  let lelse = fresh_label b "else" in
  close_block b (Br (cv, lthen, lelse));
  let lepi = fresh_label b (if tail then "ret" else "join") in
  let res = fresh_temp b (if tail then "res" else "if") in
  let preds = ref [] in
  start_block b lthen;
  let tv = compile_aexpr hooks b tail th in
  if b.cur_fn.term = None then begin
    preds := (b.cur_fn.open_label, tv) :: !preds;
    close_block b (Jmp lepi)
  end;
  start_block b lelse;
  let ev = compile_aexpr hooks b tail el in
  if b.cur_fn.term = None then begin
    preds := (b.cur_fn.open_label, ev) :: !preds;
    close_block b (Jmp lepi)
  end;
  (match !preds with
  | [] -> ()
  | _ ->
      start_block b lepi;
      emit b (Phi (result_ty, res, List.rev !preds)));
  res

and compile_switch hooks b tail (scrut : Anf.atom) (sw : Anf.switch_cases) =
  let sv = compile_atom hooks b scrut in
  let lfail = fresh_label b "swfail" in
  let lepi = fresh_label b (if tail then "swret" else "swjoin") in
  let res = fresh_temp b "sw" in
  let preds = ref [] in
  let emit_arm arm =
    let v = compile_aexpr hooks b tail arm in
    if b.cur_fn.term = None then begin
      preds := (b.cur_fn.open_label, v) :: !preds;
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
  | [], _ :: _ ->
      if sw.fail <> None then begin
        let isint = fresh_temp b "isint" in
        emit b (Binop (And, Long, isint, sv, Int 1L));
        let lblocks = fresh_label b "swblocks" in
        close_block b (Br (isint, lfail, lblocks));
        start_block b lblocks
      end;
      emit_block_switch ()
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

and compile_stringswitch hooks b tail (scrut : Anf.atom) cases fail =
  let sv = compile_atom hooks b scrut in
  let slen = string_len_raw b sv in
  let lfail = fresh_label b "ssfail" in
  let lepi = fresh_label b (if tail then "ssret" else "ssjoin") in
  let res = fresh_temp b "ss" in
  let preds = ref [] in
  let emit_arm arm =
    let v = compile_aexpr hooks b tail arm in
    if b.cur_fn.term = None then begin
      preds := (b.cur_fn.open_label, v) :: !preds;
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
          let lpre = b.cur_fn.open_label in
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

and staticcatch hooks b tail id binder_idents body handler =
  let h =
    { hlabel = fresh_label b "catch";
      hbinders = binder_idents;
      hpreds = [] }
  in
  Hashtbl.replace b.cur_fn.handlers id h;
  let v = compile_aexpr hooks b tail body in
  Hashtbl.remove b.cur_fn.handlers id;
  let ljoin = fresh_label b "catchjoin" in
  let res = fresh_temp b "catch" in
  let preds = ref [] in
  let merge value =
    preds := (b.cur_fn.open_label, value) :: !preds;
    close_block b (Jmp ljoin)
  in
  if b.cur_fn.term = None then merge v;
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
    let hv = compile_aexpr hooks b tail handler in
    List.iter (fun bid -> Hashtbl.remove b.vars bid) h.hbinders;
    if b.cur_fn.term = None then merge hv
  end;
  match !preds with
  | [] -> unit_const
  | _ ->
      start_block b ljoin;
      emit b (Phi (Long, res, List.rev !preds));
      res

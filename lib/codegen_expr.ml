(* Codegen expression, control-flow, and primitive lowering. *)

open Codegen_ctx
open Qbe_il
open Codegen_scalar

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
  mark_heap b dst

let load_field b obj index =
  let addr = ptr_offset b obj (8 * index) "fldp" in
  let dst = fresh_temp b "fld" in
  emit b (Load (Loadl, Long, dst, addr));
  dst

let with_shadow_stack b emit_calls =
  let created = fresh_temp b "stackful" in
  let active = fresh_label b "shadow_active" in
  let done_ = fresh_label b "shadow_done" in
  (* An aligned word load is a relaxed atomic read on the supported
     targets. Root stacks ignore shadow calls even if a fiber is
     created between the push and the pop. *)
  emit b (Load (Loadw, Word, created, Global "ocamlcc_stackful_fibers_created"));
  close_block b (Br (created, active, done_));
  start_block b active;
  emit_calls ();
  close_block b (Jmp done_);
  start_block b done_

let shadow_call b fn value =
  emit b (Call_void { fn = Global fn; args = [ (Long, value) ] })

let shadow_count n = Int (Int64.of_int n)

let shadow_push_values b fn values =
  emit b (Call_void { fn = Global fn; args = List.map (fun value -> Long, value) values })

let shadow_push b values tokens =
  match values, tokens with
  | [], [] -> ()
  | [value], [] -> shadow_call b "arc_fiber_push" value
  | [ _; _ ], [] -> shadow_push_values b "arc_fiber_push2" values
  | [ _; _; _ ], [] -> shadow_push_values b "arc_fiber_push3" values
  | [ _; _; _; _ ], [] -> shadow_push_values b "arc_fiber_push4" values
  | [], [token] -> shadow_call b "arc_fiber_push_reuse" token
  | _ ->
      let value_count = List.length values and token_count = List.length tokens in
      let batch = shadow_batch_slot b (value_count + token_count) in
      List.iteri (fun i root ->
        let dst = ptr_offset b batch (8 * i) "shadow_arg" in
        emit b (Store (Storel, root, dst))) (values @ tokens);
      emit b (Call_void { fn = Global "arc_fiber_push_batch";
                         args = [Long, batch; Long, shadow_count value_count;
                                 Long, shadow_count token_count] })

let shadow_pop b values tokens =
  match values, tokens with
  | 0, 0 -> ()
  | n, 0 -> shadow_call b "arc_fiber_pop" (shadow_count n)
  | 0, n -> shadow_call b "arc_fiber_pop_reuse" (shadow_count n)
  | _ -> emit b (Call_void { fn = Global "arc_fiber_pop_batch";
                            args = [Long, shadow_count values; Long, shadow_count tokens] })

let emit_finalizer_poll b idle =
  let check = fresh_label b "finalizers_check" in
  let run = fresh_label b "finalizers_run" in
  Option.iter (fun tick ->
    let phase = fresh_temp b "poll_phase" in
    let sample = fresh_label b "finalizers_sample" in
    emit b (Binop (And, Word, phase, tick, Int 63L));
    close_block b (Br (phase, idle, sample));
    start_block b sample) (poll_tick b);
  let count = fresh_temp b "finalizer_count" in
  let active = fresh_temp b "finalizers_active" in
  (* An aligned load is a relaxed atomic read on the supported targets. *)
  emit b (Load (Loadl, Long, count, Global "ocamlcc_finalizer_count"));
  emit b (Cmp (Ne, Long, active, count, Int 0L));
  close_block b (Br (active, check, idle));
  start_block b check;
  let polled = fresh_temp b "polled" in
  emit b (Call (Long, polled, { fn = Global "ocamlcc_finalizers_due"; args = [] }));
  let due = fresh_temp b "finalizers_due" in
  emit b (Cmp (Ne, Long, due, polled, unit_const));
  close_block b (Br (due, run, idle));
  start_block b run;
  emit b (Call_void { fn = Global "ocamlcc_poll_finalizers"; args = [] })

let module_slot b id =
  "ocamlcc_modvar_" ^ (module_prefix b) ^ "_" ^ sanitize (Ident.unique_name id)

let rec compile_atom hooks b (a : Anf.atom) : t =
  match a with
  | ModuleSlot (id, _) ->
      let value = fresh_temp b "modvar" in
      emit b (Load (Loadl, Long, value, Global (module_slot b id)));
      value
  | BorrowedField (index, owner) -> load_field b (compile_atom hooks b owner) index
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
      match find_ocaml_value b id with
      | Some v -> v
      | None -> (
          match function_info_opt b id with
          | Some info when not info.has_closure -> hooks.closure_value b id
          | _ ->
              failwith
                (Printf.sprintf "codegen: unbound variable %s"
                   (sanitize (Ident.name id)))))
  | MutVar id -> (
      match mutable_slot_opt b id with
      | Some slot ->
          let dst = fresh_temp b "mut" in
          emit b (Load (Loadl, Long, dst, slot));
          if known_heap_slot b id then mark_heap b dst else dst
      | None -> (
          match bound_value_opt b id with
          | Some v -> v
          | None ->
              failwith
                (Printf.sprintf "codegen: unbound mutable variable %s"
                   (sanitize (Ident.name id)))))

let compile_untagged hooks b = function
  | Anf.Var id as atom ->
      (match untagged_index b id with
       | Some index -> index
       | None -> untag b (compile_atom hooks b atom))
  | atom -> untag b (compile_atom hooks b atom)

let compile_div_mod b qop (av : t) (cv : t) : t =
  let ua = untag b av in
  let uc = untag b cv in
  let divide () =
    let raw = fresh_temp b "divr" in
    emit b (Binop (qop, Long, raw, ua, uc));
    retag b raw
  in
  match cv with
  | Int n when n <> 1L -> divide ()
  | _ ->
      let lok = fresh_label b "div_ok" in
      let lzero = fresh_label b "div_zero" in
      let ldone = fresh_label b "div_done" in
      let nz = fresh_temp b "div_nz" in
      emit b (Cmp (Ne, Long, nz, uc, Int 0L));
      close_block b (Br (nz, lok, lzero));
      start_block b lok;
      let res = divide () in
      let lok_end = open_label b in
      close_block b (Jmp ldone);
      start_block b lzero;
      let ex = fresh_temp b "divex" in
      emit b (Load (Loadl, Long, ex, Global "ocamlcc_global_Division_by_zero"));
      emit b (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, ex) ] });
      let lzero_end = open_label b in
      close_block b (Jmp ldone);
      start_block b ldone;
      let dst = fresh_temp b "divv" in
      emit b (Phi (Long, dst, [ (lok_end, res); (lzero_end, unit_const) ]));
      dst

let compile_binop hooks b (op : Anf.binop) (a : Anf.atom) (c : Anf.atom) : t =
  let av = compile_atom hooks b a in
  let cv = compile_atom hooks b c in
  let arith opcode lhs rhs =
    let dst = fresh_temp b "arith" in
    emit b (Binop (opcode, Long, dst, lhs, rhs));
    dst
  in
  match op with
  | Add -> (
      match av, cv with
      | Int k, x | x, Int k -> arith Add x (Int (Int64.sub k 1L))
      | _ -> arith Sub (arith Add av cv) (Int 1L))
  | Sub -> (
      match av, cv with
      | x, Int k -> arith Sub x (Int (Int64.sub k 1L))
      | Int k, x -> arith Sub (Int (Int64.add k 1L)) x
      | _ -> arith Add (arith Sub av cv) (Int 1L))
  | Mul -> (
      match av, cv with
      | Int tagged, value | value, Int tagged ->
          (* k * (2x + 1) + (1 - k) is 2kx + 1 modulo 2^64. *)
          let factor = Int64.shift_right tagged 1 in
          let scaled =
            if factor > 0L && Int64.logand factor (Int64.pred factor) = 0L then
              arith Shl value (Int (Int64.of_int (Int64.trailing_zeros factor)))
            else arith Mul value (Int factor)
          in
          arith Add scaled (Int (Int64.sub 1L factor))
      | _ ->
          let ua = untag b av in
          let uc = untag b cv in
          let prod = fresh_temp b "mul" in
          emit b (Binop (Mul, Long, prod, ua, uc));
          retag b prod)
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
  | Float_arithmetic op -> float_binop b ~boxed:true op av cv
  | Fcmp cmp -> float_compare b ~boxed:true cmp av cv
  | Compare_floats -> compare_floats b av cv
  | Bint_arith (kind, operation) -> integer_binop b ~boxed:true kind operation av cv
  | Bint_shift (kind, shift) -> integer_shift b ~boxed:true kind shift av cv
  | Bint_cmp (kind, cmp) -> integer_compare b ~boxed:true kind (Predicate cmp) av cv
  | Compare_bints kind -> integer_compare b ~boxed:true kind Three_way av cv

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
  | Float_of_int -> box_double b (float_of_int b av)
  | Int_of_float -> int_of_float b (load_double b av)
  | Fneg -> box_double b (float_sign b `Neg (load_double b av))
  | Fabs -> box_double b (float_sign b `Abs (load_double b av))
  | Bint_of_int kind -> box_bint b kind (integer_of_int b kind av)
  | Int_of_bint kind -> int_of_integer b kind (unbox_bint b kind av)
  | Bint_neg kind -> integer_neg b ~boxed:true kind av
  | Bint_cvt (src, dst) ->
      let raw = unbox_bint b src av in
      box_bint b dst (convert_integer b src dst raw)

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
  | 1 -> call_helper "ocamlcc_apply1_raw" arg_vals
  | 2 -> call_helper "ocamlcc_apply2_raw" arg_vals
  | 3 -> call_helper "ocamlcc_apply3_raw" arg_vals
  | 4 -> call_helper "ocamlcc_apply4_raw" arg_vals
  | _ ->
      let arr = fresh_temp b "argv" in
      emit_start_alloc b arr (8 * n);
      List.iteri
        (fun i v ->
          let addr = ptr_offset b arr (8 * i) "argp" in
          emit b (Store (Storel, v, addr)))
        arg_vals;
      emit b
        (Call
           ( Long,
             dst,
             { fn = Global "ocamlcc_apply_n_raw";
               args =
                 [ (Long, clos_val); (Long, Int (Int64.of_int n)); (Long, arr) ] } ));
      dst

let self_backedge b values =
  let values = match (poll_tick b) with
    | None -> values
    | Some tick ->
        let next = fresh_temp b "poll_next" in
        emit b (Binop (Add, Word, next, tick, Int 1L));
        values @ [next]
  in
  jump_to_entry b values;
  unit_const

let rec apply hooks b tail (fn_atom : Anf.atom) (ap_args : Anf.atom list) : t =
  let is_self id =
    match self b with
    | Some s -> Ident.same s id
    | None -> false
  in
  match fn_atom with
  | Var id -> (
      match function_info_opt b id with
      | Some info when List.length ap_args = info.arity -> (
          let clos_prefix =
            if info.has_closure then [ bound_value b id ] else []
          in
          match (info.tag, tail) with
          | Some tag, true
            when current_group b <> None
                 && current_group b = info.group_name ->
              let vs =
                pad_to info.group_arity
                  (List.map (compile_atom hooks b) ap_args)
              in
              jump_to_entry b (clos_prefix @ (Int tag :: vs));
              unit_const
          | Some tag, _ ->
              let vs =
                pad_to info.group_arity
                  (List.map (compile_atom hooks b) ap_args)
              in
              let args =
                List.map (fun v -> (Long, v)) (clos_prefix @ (Int tag :: vs))
              in
              let dst = fresh_temp b "call" in
              emit b (Call (Long, dst, { fn = Global info.global; args }));
              dst
          | None, true when is_self id ->
              self_backedge b (List.map (compile_atom hooks b) ap_args)
          | None, _ ->
              let arg_vals = List.map (compile_atom hooks b) ap_args in
              let args =
                List.map (fun v -> (Long, v)) (clos_prefix @ arg_vals)
              in
              let dst = fresh_temp b "call" in
              emit b (Call (Long, dst, { fn = Global info.global; args }));
              dst)
      | Some info when List.length ap_args > info.arity ->
          let first_args, rest_args = split_at info.arity ap_args in
          (* The tail arguments remain in this frame while the known entry
             runs. They need shadowing only if that exact call can suspend.
             The returned closure still uses the generic application path. *)
          let rest_vals = List.map (compile_atom hooks b) rest_args in
          let shadow_tail = may_suspend b id in
          if shadow_tail then with_shadow_stack b (fun () -> shadow_push b rest_vals []);
          let clos_res = apply hooks b false fn_atom first_args in
          if shadow_tail then with_shadow_stack b (fun () -> shadow_pop b (List.length rest_vals) 0);
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
          let lerr_end = open_label b in
          close_block b (Jmp ljoin);
          start_block b lok;
          with_shadow_stack b (fun () ->
              shadow_call b "arc_fiber_push" clos_res);
          let final_v = apply_closure b clos_res rest_vals in
          with_shadow_stack b (fun () -> shadow_pop b 1 0);
          emit b
            (Call_void
               { fn = Global "arc_release_val"; args = [ (Long, clos_res) ] });
          let lok_end = open_label b in
          close_block b (Jmp ljoin);
          start_block b ljoin;
          let dst = fresh_temp b "oapp" in
          emit b (Phi (Long, dst, [ (lerr_end, unit_const); (lok_end, final_v) ]));
          dst
      | Some info ->
          let clos_val =
            if info.has_closure then bound_value b id
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
  | Anf.Raw_scalar id -> bound_value b id
  | Boxed_scalar a ->
      let boxed = compile_atom hooks b a in
      match rep with
      | Anf.Double_scalar -> load_double b boxed
      | Integer_scalar kind -> unbox_bint b kind boxed

let compile_native_ccall hooks b (prim : Primitive.description) args =
  let arg rep value =
    match Anf.native_scalar rep with
    | Some scalar ->
        scalar_type scalar, compile_scalar_operand hooks b scalar (Boxed_scalar value)
    | None ->
        let value = compile_atom hooks b value in
        Long, (if rep = Primitive.Untagged_immediate then untag b value else value)
  in
  let args = List.map2 arg prim.prim_native_repr_args args in
  let rep = prim.prim_native_repr_res in
  let ty = Option.fold ~none:Long ~some:scalar_type (Anf.native_scalar rep) in
  let dst = fresh_temp b "native_cc" in
  emit b (Call (ty, dst, { fn = Global (Primitive.native_name prim); args }));
  if rep = Primitive.Untagged_immediate then retag b dst else dst

let array_address b arr index =
  let offset = fresh_temp b "aoff" in
  emit b (Binop (Shl, Long, offset, index, Int 3L));
  let addr = fresh_temp b "arrp" in
  emit b (Binop (Add, Long, addr, arr, offset));
  addr

let compile_cexpr ?on_oob hooks b ~tail (ce : Anf.cexpr) : t =
  match ce with
  | Atom a -> compile_atom hooks b a
  | LoopPollDue (index, start) ->
      let index = compile_untagged hooks b index in
      let phase = fresh_temp b "poll_phase" in
      (* Preserve the first check at an arbitrary loop start, in either
         direction. Only the low six bits of the distance are observed. *)
      let distance =
        match compile_untagged hooks b start with
        | Int 0L -> index
        | start ->
            let distance = fresh_temp b "poll_distance" in
            emit b (Binop (Sub, Long, distance, index, start));
            distance
      in
      emit b (Binop (And, Long, phase, distance, Int 63L));
      let due = fresh_temp b "loop_poll_due" in
      emit b (Cmp (Eq, Long, due, phase, Int 0L));
      retag b due
  | Binop (op, a, c) -> compile_binop hooks b op a c
  | IntSelect (op, a, c) ->
      let lhs = compile_atom hooks b a in
      let rhs = compile_atom hooks b c in
      let cmp = match op with Builtins.Min -> Cmp.Sle | Max -> Cmp.Sge in
      (* The signed ordering of tagged ints is the same as their value order. *)
      let choose_left = fresh_temp b "intcmp" in
      emit b (Cmp (cmp, Long, choose_left, lhs, rhs));
      let left = fresh_label b "intleft" in
      let right = fresh_label b "intright" in
      let join = fresh_label b "intjoin" in
      close_block b (Br (choose_left, left, right));
      start_block b left;
      close_block b (Jmp join);
      start_block b right;
      close_block b (Jmp join);
      start_block b join;
      let dst = fresh_temp b "intsel" in
      emit b (Phi (Long, dst, [ (left, lhs); (right, rhs) ]));
      dst
  | Unop (op, a) -> compile_unop hooks b op a
  | MakeBlock (tag, scan, args) ->
      emit_block_alloc b scan tag (List.map (compile_atom hooks b) args)
  | AllocReuse (reuse, tag, scan, args) ->
      let primary = bound_value b reuse.primary in
      let fallback = Option.map (bound_value b) reuse.fallback in
      emit_block_alloc b ~reuse:(primary, fallback) scan tag (List.map (compile_atom hooks b) args)
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
          mark_heap b arr
      | Lambda.Pgenarray when n > 0 ->
          let buf = fresh_temp b "gbuf" in
          emit_start_alloc b buf (8 * n);
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
          mark_heap b arr
      | Lambda.Pintarray | Paddrarray | Pgenarray ->
          let bytes = Long, Int (Int64.of_int (8 * n)) in
          let allocator =
            if kind = Lambda.Pintarray then
              { fn = Global "ocamlcc_alloc_immediate_array";
                args = [Word, Int (Int64.of_int (8 * n))] }
            else
              { fn = Global "arc_alloc";
                args = [Long, Int (Int64.of_int arc_tag_array);
                        Long, Int (Int64.of_int (min n 0xffff)); bytes] }
          in
          let arr = fresh_temp b "arr" in
          emit b (Call (Long, arr, allocator));
          List.iteri
            (fun i v ->
              let addr = ptr_offset b arr (8 * i) "arrp" in
              emit b (Store (Storel, v, addr)))
            vs;
          mark_heap b arr)
  | Field (i, kind, arg) ->
      let obj = compile_atom hooks b arg in
      let dst = load_field b obj i in
      if kind <> Anf.Immediate_field then emit_arc_if_heap b `Retain dst;
      dst
  | SetField (i, repr, arg, rhs) ->
      let obj = compile_atom hooks b arg in
      let v = compile_atom hooks b rhs in
      let addr = ptr_offset b obj (8 * i) "fldp" in
      (match repr with
      | Lambda.Immediate -> emit b (Store (Storel, v, addr))
      | Pointer ->
          let old_v = fresh_temp b "oldf" in
          emit b (Load (Loadl, Long, old_v, addr));
          emit b (Store (Storel, v, addr));
          emit_arc_if_heap b `Release old_v);
      unit_const
  | FloatField (i, arg) ->
      let obj = compile_atom hooks b arg in
      let addr = ptr_offset b obj (8 * i) "ffldp" in
      load_double b addr
  | SetFloatField (i, arg, rhs) ->
      let obj = compile_atom hooks b arg in
      let d = compile_scalar_operand hooks b Double_scalar rhs in
      let addr = ptr_offset b obj (8 * i) "ffldp" in
      emit b (Store (Stored, d, addr));
      unit_const
  | SetBoxedFloatField (i, arg, rhs) ->
      let obj = compile_atom hooks b arg in
      let d = compile_scalar_operand hooks b Double_scalar rhs in
      let addr = ptr_offset b obj (8 * i) "ffldp" in
      emit b (Call_void { fn = Global "ocamlcc_store_boxed_float";
                          args = [Long, addr; Double, d] });
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
      let ui = compile_untagged hooks b idx in
      let do_read () =
        let caddr = fresh_temp b "strp" in
        emit b (Binop (Add, Long, caddr, sv, ui));
        let ch = fresh_temp b "chr" in
        emit b (Load (Loadub, Long, ch, caddr));
        retag b ch
      in
      if safe then
        let len = string_len_raw b sv in
        compile_bounds_guarded b ?on_oob ui len do_read
      else do_read ()
  | BytesSet (safe, bs, idx, ch) ->
      let bsv = compile_atom hooks b bs in
      let ui = compile_untagged hooks b idx in
      let cv = compile_atom hooks b ch in
      let uc = untag b cv in
      let do_write () =
        let caddr = fresh_temp b "strp" in
        emit b (Binop (Add, Long, caddr, bsv, ui));
        emit b (Store (Storeb, uc, caddr));
        unit_const
      in
      if safe then
        let len = string_len_raw b bsv in
        compile_bounds_guarded b ?on_oob ui len do_write
      else do_write ()
  | BytesGetN (safe, mode, bs, idx) ->
      let bsv = compile_atom hooks b bs in
      let ui = compile_untagged hooks b idx in
      let width, load, ty = match mode with
        | Uint16 -> 2, Loaduh, Long
        | Boxed_word Word32 | Raw_word Word32 -> 4, Loadw, Word
        | Boxed_word Word64 | Raw_word Word64 -> 8, Loadl, Long
      in
      let do_read () =
        let addr = fresh_temp b "bgptr" in
        emit b (Binop (Add, Long, addr, bsv, ui));
        let raw = fresh_temp b "bg" in
        emit b (Load (load, ty, raw, addr));
        match mode with
        | Uint16 -> retag b raw
        | Raw_word _ -> raw
        | Boxed_word word -> box_bint b (Builtins.Byte_access.boxed_integer word) raw
      in
      if safe then
        let len = string_len_raw b bsv in
        let result_type = match mode with Raw_word _ -> ty | _ -> Long in
        compile_bytes_slice_bounds_guarded b ?on_oob ~result_type ui len width do_read
      else do_read ()
  | BytesSetN (safe, bs, idx, word) ->
      let bsv = compile_atom hooks b bs in
      let ui = compile_untagged hooks b idx in
      let do_write () =
        let addr = fresh_temp b "bsptr" in
        emit b (Binop (Add, Long, addr, bsv, ui));
        let store, value = match word with
          | Uint16 v -> Storeh, compile_untagged hooks b v
          | Int32 v -> Storew, compile_scalar_operand hooks b (Integer_scalar Pint32) v
          | Int64 v -> Storel, compile_scalar_operand hooks b (Integer_scalar Pint64) v
        in
        emit b (Store (store, value, addr));
        unit_const
      in
      if safe then
        let len = string_len_raw b bsv in
        compile_bytes_slice_bounds_guarded b ?on_oob ui len (Anf.Byte_store.width word) do_write
      else do_write ()
  | Bswap16 a ->
      let av = compile_atom hooks b a in
      let u = untag b av in
      let lo = fresh_temp b "bs16lo" in
      emit b (Binop (And, Long, lo, u, Int 0xffL));
      let slo = fresh_temp b "bs16slo" in
      emit b (Binop (Shl, Long, slo, lo, Int 8L));
      let shi = fresh_temp b "bs16shi" in
      emit b (Binop (Shr, Long, shi, u, Int 8L));
      let hi = fresh_temp b "bs16hi" in
      emit b (Binop (And, Long, hi, shi, Int 0xffL));
      let res = fresh_temp b "bs16" in
      emit b (Binop (Or, Long, res, slo, hi));
      retag b res
  | BswapBint (bi, a) ->
      let av = compile_atom hooks b a in
      let u = unbox_bint b bi av in
      let mask_shift ty v mask shift_op amount name =
        let t = fresh_temp b name in
        (match mask with
        | None -> emit b (Binop (shift_op, ty, t, v, Int amount))
        | Some m ->
            let mtmp = fresh_temp b (name ^ "_m") in
            emit b (Binop (And, ty, mtmp, v, Int m));
            emit b (Binop (shift_op, ty, t, mtmp, Int amount)));
        t
      in
      let swapped =
        match bi with
        | Pint32 ->
            let b0 = mask_shift Word u (Some 0xffL) Shl 24L "bs32_0" in
            let b1 = mask_shift Word u (Some 0xff00L) Shl 8L "bs32_1" in
            let b2s = mask_shift Word u None Shr 8L "bs32_2s" in
            let b2 = fresh_temp b "bs32_2" in
            emit b (Binop (And, Word, b2, b2s, Int 0xff00L));
            let b3 = mask_shift Word u None Shr 24L "bs32_3" in
            let o1 = fresh_temp b "bs32_o1" in
            emit b (Binop (Or, Word, o1, b0, b1));
            let o2 = fresh_temp b "bs32_o2" in
            emit b (Binop (Or, Word, o2, b2, b3));
            let o3 = fresh_temp b "bs32_o3" in
            emit b (Binop (Or, Word, o3, o1, o2));
            o3
        | Pint64 | Pnativeint ->
            let swar_step x mask amt name =
              let left = mask_shift Long x (Some mask) Shl amt (name ^ "l") in
              let rs = mask_shift Long x None Shr amt (name ^ "rs") in
              let right = fresh_temp b (name ^ "r") in
              emit b (Binop (And, Long, right, rs, Int mask));
              let out = fresh_temp b name in
              emit b (Binop (Or, Long, out, left, right));
              out
            in
            let x1 = swar_step u 0x00FF00FF00FF00FFL 8L "bs64_1" in
            let x2 = swar_step x1 0x0000FFFF0000FFFFL 16L "bs64_2" in
            let hi = mask_shift Long x2 None Shl 32L "bs64_3h" in
            let lo = mask_shift Long x2 None Shr 32L "bs64_3l" in
            let out = fresh_temp b "bs64_3" in
            emit b (Binop (Or, Long, out, hi, lo));
            out
      in
      box_bint b bi swapped
  | ArrayGet (safe, kind, arr, idx) -> (
      let av = compile_atom hooks b arr in
      match kind with
      | Lambda.Pgenarray ->
          let read () =
            let iv = compile_atom hooks b idx in
            let dst = fresh_temp b "gavel" in
            emit b (Call (Long, dst, { fn = Global "ocamlcc_gen_array_get";
              args = [Long, Int 0L; Long, av; Long, iv] }));
            dst
          in
          if safe then compile_bounds_guarded b ?on_oob (compile_untagged hooks b idx) (array_len_raw b av) read
          else read ()
      | Lambda.Pfloatarray ->
          let ui = compile_untagged hooks b idx in
          let do_read () =
            let eaddr = array_address b av ui in
            box_double b (load_double b eaddr)
          in
          if safe then
            let len = array_len_raw b av in
            compile_bounds_guarded b ?on_oob ui len do_read
          else do_read ()
      | Lambda.Paddrarray | Pintarray ->
          let ui = compile_untagged hooks b idx in
          let do_read () =
            let eaddr = array_address b av ui in
            let dst = fresh_temp b "avel" in
            emit b (Load (Loadl, Long, dst, eaddr));
            if kind = Lambda.Paddrarray then emit_arc_if_heap b `Retain dst;
            dst
          in
          if safe then
            let len = array_len_raw b av in
            compile_bounds_guarded b ?on_oob ui len do_read
          else do_read ())
  | ArraySet (safe, kind, arr, idx, v) -> (
      let av = compile_atom hooks b arr in
      let vv = compile_atom hooks b v in
      match kind with
      | Lambda.Pgenarray ->
          let write () =
            let iv = compile_atom hooks b idx in
            let dst = fresh_temp b "gaset" in
            emit b (Call (Long, dst, { fn = Global "ocamlcc_gen_array_set";
              args = [Long, Int 0L; Long, av; Long, iv; Long, vv] }));
            unit_const
          in
          if safe then compile_bounds_guarded b ?on_oob ~drop_on_oob:vv
            (compile_untagged hooks b idx) (array_len_raw b av) write
          else write ()
      | Lambda.Pfloatarray ->
          let ui = compile_untagged hooks b idx in
          let do_write () =
            let eaddr = array_address b av ui in
            let d = load_double b vv in
            emit b (Store (Stored, d, eaddr));
            emit_arc_if_heap b `Release vv;
            unit_const
          in
          if safe then
            let len = array_len_raw b av in
            compile_bounds_guarded b ?on_oob ~drop_on_oob:vv ui len do_write
          else do_write ()
      | Lambda.Pintarray | Paddrarray ->
          let ui = compile_untagged hooks b idx in
          let do_write () =
            if kind = Lambda.Pintarray then begin
              let eaddr = array_address b av ui in
              emit b (Store (Storel, vv, eaddr))
            end else begin
              let iv = compile_atom hooks b idx in
              emit b (Call_void { fn = Global "ocamlcc_addr_array_set";
                args = [Long, av; Long, iv; Long, vv] })
            end;
            unit_const
          in
          if safe then
            let len = array_len_raw b av in
            let drop_on_oob = if kind = Lambda.Pintarray then None else Some vv in
            compile_bounds_guarded b ?on_oob ?drop_on_oob ui len do_write
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
      load_bigarray b access args
  | ScalarValue (rep, value) -> compile_scalar_operand hooks b rep value
  | BoxScalar (rep, value) ->
      let raw = compile_scalar_operand hooks b rep value in
      (match rep with
      | Double_scalar -> box_double b raw
      | Integer_scalar kind -> box_bint b kind raw)
  | FloatArrayGet (safe, arr, index) ->
      let av = compile_atom hooks b arr in
      let idx = compile_untagged hooks b index in
      let load () = load_double b (array_address b av idx) in
      if safe then
        compile_bounds_guarded b ?on_oob ~result_type:Double idx (array_len_raw b av) load
      else load ()
  | FloatArraySet (safe, arr, index, value) ->
      let av = compile_atom hooks b arr in
      let idx = compile_untagged hooks b index in
      let store () =
        let v = compile_scalar_operand hooks b Double_scalar value in
        emit b (Store (Stored, v, array_address b av idx));
        unit_const
      in
      if safe then compile_bounds_guarded b ?on_oob idx (array_len_raw b av) store
      else store ()
  | FloatOfInt value -> float_of_int b (compile_atom hooks b value)
  | IntOfFloat value -> int_of_float b (compile_scalar_operand hooks b Double_scalar value)
  | FloatSign (op, value) -> float_sign b op (compile_scalar_operand hooks b Double_scalar value)
  | FloatCompare (op, lhs, rhs) ->
      let l = compile_scalar_operand hooks b Double_scalar lhs in
      let r = compile_scalar_operand hooks b Double_scalar rhs in
      float_compare b ~boxed:false op l r
  | FloatBinop (op, lhs, rhs) ->
      let l = compile_scalar_operand hooks b Double_scalar lhs in
      let r = compile_scalar_operand hooks b Double_scalar rhs in
      float_binop b ~boxed:false op l r
  | IntegerBinop (kind, op, lhs, rhs) ->
      let rep = Anf.Integer_scalar kind in
      let l = compile_scalar_operand hooks b rep lhs in
      let r = compile_scalar_operand hooks b rep rhs in
      integer_binop b ~boxed:false kind op l r
  | IntegerCompare (kind, relation, lhs, rhs) ->
      let rep = Anf.Integer_scalar kind in
      let l = compile_scalar_operand hooks b rep lhs in
      let r = compile_scalar_operand hooks b rep rhs in
      integer_compare b ~boxed:false kind relation l r
  | IntegerOfInt (kind, value) ->
      integer_of_int b kind (compile_atom hooks b value)
  | IntOfInteger (kind, value) ->
      let raw = compile_scalar_operand hooks b (Integer_scalar kind) value in
      int_of_integer b kind raw
  | IntegerConvert (src, dst, value) ->
      let raw = compile_scalar_operand hooks b (Integer_scalar src) value in
      convert_integer b src dst raw
  | IntegerNeg (kind, value) ->
      let rep = Anf.Integer_scalar kind in
      let value = compile_scalar_operand hooks b rep value in
      integer_neg b ~boxed:false kind value
  | IntegerShift (kind, op, value, count) ->
      let value = compile_scalar_operand hooks b (Integer_scalar kind) value in
      let count = compile_atom hooks b count in
      integer_shift b ~boxed:false kind op value count
  | ScalarStore (access, arr, index, value) ->
      let args = List.map (fun a -> Long, compile_atom hooks b a) [arr; index] in
      let rep = Option.get (Anf.scalar_rep access.kind) in
      let v = compile_scalar_operand hooks b rep value in
      store_bigarray b access args rep v
  | BigarrayAccess (access, args) ->
      let op = match access.operation with `Get -> "get" | `Set -> "set" in
      compile_ccall hooks b (Printf.sprintf "caml_ba_%s_%d" op access.rank) args
  | PollFinalizers -> failwith "codegen: missing cleanup for finalizer poll"
  | Ccall (sym, args) -> compile_ccall hooks b sym args
  | NativeCcall (prim, args) -> compile_native_ccall hooks b prim args
  | DirectApp (target, args) ->
      let symbol = Option.fold ~none:target.symbol ~some:fst target.borrowed_entry in
      compile_ccall hooks b symbol args
  | ImportDependency _ -> unit_const
  | GetGlobal mod_name ->
      let gsym = "ocamlcc_global_" ^ sanitize mod_name in
      let gv = fresh_temp b "glob" in
      emit b (Load (Loadl, Long, gv, Global gsym));
      emit b (Call_void { fn = Global "arc_retain_val"; args = [ (Long, gv) ] });
      gv
  | StoreModuleSlot (id, atom) ->
      let name = module_slot b id in
      add_data b { name; export = false; align = Some 8; items = [D_long 0L] };
      let value = compile_atom hooks b atom in
      emit b (Store (Storel, value, Global name));
      unit_const
  | App (fn, args) -> apply hooks b tail fn args
  | KeepAlive _ -> unit_const
  | Recur args ->
      self_backedge b (List.map (compile_atom hooks b) args)
  | Fun _ -> failwith "codegen: Fun must be bound by Let"
  | ReadScalarSlot (rep, id) ->
      let slot = mutable_slot b id in
      (match rep with
      | Double_scalar -> load_double b slot
      | Integer_scalar kind -> unbox_bint b kind slot)
  | AssignScalar (id, rep, value) ->
      let slot = mutable_slot b id in
      let value = compile_scalar_operand hooks b rep value in
      emit b (Store (scalar_store (scalar_type rep), value, slot));
      forget_heap_slot b id;
      unit_const
  | Assign (id, rhs) | AssignImm (id, rhs) -> (
      let v = compile_atom hooks b rhs in
      match mutable_slot_opt b id with
      | Some slot ->
          (match ce with
          | AssignImm _ -> emit b (Store (Storel, v, slot))
          | _ ->
              let old_v = fresh_temp b "oldm" in
              emit b (Load (Loadl, Long, old_v, slot));
              emit b (Store (Storel, v, slot));
              emit b
                (Call_void { fn = Global "arc_release_val"; args = [ (Long, old_v) ] }));
          forget_heap_slot b id;
          unit_const
      | None ->
          failwith
            (Printf.sprintf "codegen: assignment to non-mutable %s"
               (sanitize (Ident.name id))))

let emit_unwind b : t =
  match try_handler b with
  | Some lcatch ->
      close_block b (Jmp lcatch);
      unit_const
  | None ->
      if in_initializer b then begin
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

let with_dereferenced_receiver b (ce : Anf.cexpr) f =
  let receiver =
    match ce with
    | Field (_, _, obj) | SetField (_, _, obj, _) | FloatField (_, obj)
    | SetFloatField (_, obj, _) | StringGet (_, obj, _)
    | BytesSet (_, obj, _, _) | BytesGetN (_, _, obj, _)
    | BytesSetN (_, obj, _, _) | ArrayGet (_, _, obj, _)
    | ArraySet (true, _, obj, _, _)
    | ArraySet (false, (Pintarray | Pfloatarray), obj, _, _)
    | FloatArrayGet (_, obj, _) | FloatArraySet (_, obj, _, _)
    | Unop ((String_length | Array_length), obj) -> Some obj
    | _ -> None
  in
  match receiver with
  | Some (Anf.Var id) ->
      (match bound_value_opt b id with
      | Some value -> with_known_heap b value f
      | None -> f ())
  | Some (Anf.MutVar slot) -> with_heap_slot b slot f
  | _ -> f ()

(* Keep each emitter's temporaries in its own frame. A recursive walk of a
   large ANF function can keep thousands of these continuations active. *)
let rec compile_aexpr hooks b (tail : bool) (e : Anf.aexpr) : t =
  match e with
  | Halt a -> compile_atom hooks b a
  | HaltScalar id -> bound_value b id
  | Let (id, Fun lf, body) ->
      hooks.compile_fun_binding (compile_aexpr hooks) b tail id lf body
  | Let (id, (App _ as ce), Halt (Var v)) when tail && Ident.same id v ->
      compile_cexpr hooks b ~tail:true ce
  | Let (id, PollFinalizers, CheckExn (exception_kind, on_err, on_ok)) ->
      compile_finalizer_poll hooks b tail id exception_kind on_err on_ok
  | Let (id, (StringGet (true, _, _) | BytesSet (true, _, _, _)
            | BytesGetN (true, _, _, _) | BytesSetN (true, _, _, _)
            | ArrayGet (true, _, _, _) | ArraySet (true, _, _, _, _)
            | FloatArrayGet (true, _, _) | FloatArraySet (true, _, _, _) as ce),
      CheckExn (_, on_err, on_ok)) ->
      compile_checked_access hooks b tail id ce on_err on_ok
  | Let (id, ce, body) ->
      compile_let hooks b tail id ce body
  | MutLet (id, ce, body) ->
      compile_mutable_let hooks b tail id ce body
  | LetJoin (id, rhs, body) ->
      compile_join hooks b tail id rhs body
  | LetRec (bindings, body) ->
      hooks.compile_letrec (compile_aexpr hooks) b tail bindings body
  | If (cond, th, el) -> compile_if hooks b tail Long cond th el
  | ScalarIf (rep, cond, th, el) -> compile_if hooks b false (scalar_type rep) cond th el
  | Switch (scrut, sw) -> compile_switch hooks b tail scrut sw
  | StringSwitch (scrut, cases, fail) ->
      compile_stringswitch hooks b tail scrut cases fail
  | StaticCatch (body, id, binders, handler, result_rep) ->
      let result_ty = Option.fold ~none:Long ~some:scalar_type result_rep in
      staticcatch hooks b tail result_ty id binders body handler
  | StaticRaise (id, args) ->
      jump_static_handler b id (fun () -> List.map (compile_atom hooks b) args);
      unit_const
  | While (cond, body) ->
      compile_while hooks b cond body
  | For (id, start_a, stop_a, dir, body) ->
      compile_for hooks b id start_a stop_a dir body
  | Retain (id, body) ->
      let v = compile_atom hooks b (Var id) in
      emit_arc_if_heap b `Retain v;
      compile_aexpr hooks b tail body
  | (Release _ | ReleaseMut _) as cleanup ->
      compile_releases hooks b tail cleanup
  | DropReuse (v_id, tok_id, body) ->
      compile_drop_reuse hooks b tail v_id tok_id body
  | FreeReuse (tok_id, body) ->
      let tok = bound_value b tok_id in
      emit b
        (Call_void { fn = Global "arc_free_reuse"; args = [ (Long, tok) ] });
      compile_aexpr hooks b tail body
  | ShadowPush (vars, muts, rtoks, body) ->
      compile_shadow_push hooks b tail vars muts rtoks body
  | ShadowPop (n_vals, n_reuse, body) ->
      if n_vals > 0 || n_reuse > 0 then
        with_shadow_stack b (fun () -> shadow_pop b n_vals n_reuse);
      compile_aexpr hooks b tail body
  | Unwind -> emit_unwind b
  | Raise a ->
      let v = compile_atom hooks b a in
      emit b (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, v) ] });
      emit_unwind b
  | CheckExn (exception_kind, on_err, on_ok) ->
      compile_check_exn hooks b exception_kind on_err (fun () -> compile_aexpr hooks b tail on_ok)
  | TryWith (body, exn_id, handler) ->
      compile_try_with hooks b tail body exn_id handler

and[@inline never] compile_finalizer_poll hooks b tail id exception_kind on_err on_ok =
  let done_ = fresh_label b "finalizers_done" in
  emit_finalizer_poll b done_;
  ignore (compile_check_exn hooks b exception_kind on_err (fun () ->
    close_block b (Jmp done_);
    unit_const));
  start_block b done_;
  with_shadowed_vars b [id] (fun () ->
    bind_value b id unit_const;
    compile_aexpr hooks b tail on_ok)

and[@inline never] compile_checked_access hooks b tail id ce on_err on_ok =
  let on_oob () = ignore (compile_aexpr hooks b tail on_err) in
  let value = compile_cexpr ~on_oob hooks b ~tail:false ce in
  bind_value b id value;
  let res = with_dereferenced_receiver b ce (fun () ->
    compile_aexpr hooks b tail on_ok) in
  forget_value b id;
  res

and[@inline never] compile_let hooks b tail id ce body =
  let v =
    match ce with
    | DirectApp ({ inline_leaf = Some lf; _ }, args) -> inline_leaf hooks b lf args
    | _ -> compile_cexpr hooks b ~tail:false ce
  in
  if not (block_is_open b) then unit_const
  else begin
    bind_value b id v;
    let res =
      match ce, body with
      | (CreateBytes _ | MakeArrayInit _), CheckExn (_, on_err, on_ok) ->
          (* Checked allocators return a tagged failure value on error. *)
          compile_check_exn hooks b Anf.May_raise on_err (fun () ->
              with_known_heap b v (fun () -> compile_aexpr hooks b tail on_ok))
      | _ -> with_dereferenced_receiver b ce (fun () ->
          compile_aexpr hooks b tail body) in
    forget_value b id;
    res
  end

and[@inline never] compile_mutable_let hooks b tail id ce body =
  let v = compile_cexpr hooks b ~tail:false ce in
  let slot = fresh_temp b "mslot" in
  emit_start_alloc b slot 8;
  let store = match ce with
    | ScalarValue (rep, _) -> scalar_store (scalar_type rep)
    | _ -> Storel in
  emit b (Store (store, v, slot));
  bind_slot b id slot;
  let res = with_dereferenced_receiver b ce (fun () ->
    compile_aexpr hooks b tail body) in
  forget_slot b id;
  res

and[@inline never] compile_join hooks b tail id rhs body =
  let v = compile_aexpr hooks b false rhs in
  forget_heap_slots b;
  if not (block_is_open b) then unit_const
  else begin
    bind_value b id v;
    let res = compile_aexpr hooks b tail body in
    forget_value b id;
    res
  end

and[@inline never] compile_while hooks b cond body =
  forget_heap_slots b;
  let lcond = fresh_label b "wcond" in
  close_block b (Jmp lcond);
  start_block b lcond;
  let cv_tagged = compile_aexpr hooks b false cond in
  if block_is_open b then begin
    let lbody = fresh_label b "wbody" in
    let ldone = fresh_label b "wdone" in
    let cv = fresh_temp b "wcmp" in
    emit b (Cmp (Ne, Long, cv, cv_tagged, Int 1L));
    close_block b (Br (cv, lbody, ldone));
    start_block b lbody;
    ignore (compile_aexpr hooks b false body);
    if block_is_open b then close_block b (Jmp lcond);
    start_block b ldone
  end;
  unit_const

and[@inline never] compile_for hooks b id start_a stop_a dir body =
  let sv = compile_untagged hooks b start_a in
  let ev = compile_untagged hooks b stop_a in
  forget_heap_slots b;
  let enter_op, cont_op, step =
    match dir with
    | Asttypes.Upto -> (Cmp.Sle, Cmp.Slt, 1L)
    | Asttypes.Downto -> (Cmp.Sge, Cmp.Sgt, -1L)
  in
  let enter = fresh_temp b "forenter" in
  emit b (Cmp (enter_op, Long, enter, sv, ev));
  let lpre = open_label b in
  let lbody = fresh_label b "fbody" in
  let lstep = fresh_label b "fstep" in
  let lnext = fresh_label b "fnext" in
  let ldone = fresh_label b "fdone" in
  let iv = fresh_temp b "fori" in
  let next_i = fresh_temp b "forn" in
  close_block b (Br (enter, lbody, ldone));
  start_block b lbody;
  emit b (Phi (Long, iv, [ (lpre, sv); (lnext, next_i) ]));
  with_untagged_index b id iv
    (fun () -> ignore (compile_aexpr hooks b false body));
  if block_is_open b then close_block b (Jmp lstep);
  start_block b lstep;
  let more = fresh_temp b "formore" in
  emit b (Cmp (cont_op, Long, more, iv, ev));
  close_block b (Br (more, lnext, ldone));
  start_block b lnext;
  emit b (Binop (Add, Long, next_i, iv, Int step));
  close_block b (Jmp lbody);
  start_block b ldone;
  unit_const

and[@inline never] compile_releases hooks b tail cleanup =
  let rec ends_in_raise = function
    | Anf.Release (_, body) | ReleaseMut (_, body) -> ends_in_raise body
    | Raise _ | Unwind -> true
    | _ -> false
  in
  let rec emit_releases = function
    | Anf.Release (id, body) ->
        emit_arc_if_heap b `Release (compile_atom hooks b (Var id));
        emit_releases body
    | ReleaseMut (id, body) ->
        (match mutable_slot_opt b id with
        | Some _ ->
            emit_arc_if_heap b `Release (compile_atom hooks b (MutVar id))
        | None -> ());
        emit_releases body
    | rest -> rest
  in
  let body =
    if (inline_rc b) && not (compact_arc b) && ends_in_raise cleanup
    then with_compact_arc b (fun () -> emit_releases cleanup)
    else emit_releases cleanup
  in
  compile_aexpr hooks b tail body

and[@inline never] compile_drop_reuse hooks b tail v_id tok_id body =
  let v = compile_atom hooks b (Var v_id) in
  let tok = fresh_temp b "rtok" in
  emit b
    (Call (Long, tok, { fn = Global "arc_drop_reuse"; args = [ (Long, v) ] }));
  bind_value b tok_id tok;
  let res = compile_aexpr hooks b tail body in
  forget_value b tok_id;
  res

and[@inline never] compile_shadow_push hooks b tail vars muts rtoks body =
  if vars <> [] || muts <> [] || rtoks <> [] then
    with_shadow_stack b (fun () ->
        let values = List.map (fun id -> compile_atom hooks b (Var id)) vars in
        let mutable_values = List.map (fun mid ->
          let v = fresh_temp b "shmut" in
          emit b (Load (Loadl, Long, v, mutable_slot b mid));
          v) muts in
        let tokens = List.map (bound_value b) rtoks in
        shadow_push b (values @ mutable_values) tokens);
  compile_aexpr hooks b tail body

and[@inline never] compile_try_with hooks b tail body exn_id handler =
  let lcatch = fresh_label b "catch" in
  let ljoin = fresh_label b (if tail then "ret" else "tryj") in
  let res = fresh_temp b (if tail then "res" else "tryv") in
  let preds = ref [] in
  let bv = with_try_handler b lcatch (fun () -> compile_aexpr hooks b tail body) in
  if block_is_open b then begin
    preds := (open_label b, bv) :: !preds;
    close_block b (Jmp ljoin)
  end;
  start_block b lcatch;
  let ex = fresh_temp b "exn" in
  emit b (Call (Long, ex, { fn = Global "ocamlcc_get_exn"; args = [] }));
  emit b
    (Call_void { fn = Global "ocamlcc_set_exn"; args = [ (Long, Int 0L) ] });
  bind_value b exn_id ex;
  let hv = compile_aexpr hooks b tail handler in
  forget_value b exn_id;
  if block_is_open b then begin
    preds := (open_label b, hv) :: !preds;
    close_block b (Jmp ljoin)
  end;
  (match !preds with
  | [] -> unit_const
  | _ ->
      start_block b ljoin;
      emit b (Phi (Long, res, List.rev !preds));
      res)

and inline_leaf hooks b (lf : Anf.lfunction) args =
  let args = List.map (compile_atom hooks b) args in
  let rec bindings ids = function
    | Anf.Let (id, _, body) -> bindings (id :: ids) body
    | LetJoin (id, lhs, rhs) -> bindings (bindings (id :: ids) lhs) rhs
    | If (_, yes, no) -> bindings (bindings ids yes) no
    | Halt _ -> ids
    | _ -> assert false
  in
  let params = List.map fst lf.params in
  with_shadowed_vars b (bindings params lf.body) (fun () ->
    List.iter2 (bind_value b) params args;
    compile_aexpr hooks b false lf.body)

and compile_check_exn hooks b exception_kind on_err on_ok =
  let lerr = fresh_label b "exn_err" in
  let lok = fresh_label b "exn_ok" in
  let guard symbol =
    let active = fresh_temp b "exn_active" in
    let lcheck = fresh_label b "exn_check" in
    emit b (Load (Loadw, Word, active, Global symbol));
    close_block b (Br (active, lcheck, lok));
    start_block b lcheck
  in
  if exception_kind = Anf.Finalizer_raise then
    guard "ocamlcc_automatic_finalizer_raised"
  else if not (inline_rc b) then
    guard "ocamlcc_exn_active";
  let ex = fresh_temp b "exchk" in
  if (inline_rc b) then
    emit b (Load (Loadl, Long, ex, Global "ocamlcc_exn_slot"))
  else
    emit b (Call (Long, ex, { fn = Global "ocamlcc_get_exn"; args = [] }));
  let has_ex = fresh_temp b "hasex" in
  emit b (Cmp (Ne, Long, has_ex, ex, Int 0L));
  close_block b (Br (has_ex, lerr, lok));
  start_block b lerr;
  with_compact_arc b (fun () -> ignore (compile_aexpr hooks b false on_err));
  if block_is_open b then ignore (emit_unwind b);
  start_block b lok;
  on_ok ()

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
  if block_is_open b then begin
    preds := (open_label b, tv) :: !preds;
    close_block b (Jmp lepi)
  end;
  start_block b lelse;
  let ev = compile_aexpr hooks b tail el in
  if block_is_open b then begin
    preds := (open_label b, ev) :: !preds;
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
    if block_is_open b then begin
      preds := (open_label b, v) :: !preds;
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
      let result_ty = Option.fold ~none:Long ~some:scalar_type sw.result_rep in
      emit b (Phi (result_ty, res, List.rev !preds));
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
    if block_is_open b then begin
      preds := (open_label b, v) :: !preds;
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
          let lpre = open_label b in
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

and staticcatch hooks b tail result_ty id binder_idents body handler =
  let handler_label = fresh_label b "catch" in
  let v, sites =
    with_static_handler b id handler_label (fun () -> compile_aexpr hooks b tail body)
  in
  let ljoin = fresh_label b "catchjoin" in
  let res = fresh_temp b "catch" in
  let preds = ref [] in
  let merge value =
    preds := (open_label b, value) :: !preds;
    close_block b (Jmp ljoin)
  in
  if block_is_open b then merge v;
  if sites <> [] then begin
    start_block b handler_label;
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
        bind_value b bid bt)
      binder_idents;
    let hv = compile_aexpr hooks b tail handler in
    List.iter (fun bid -> forget_value b bid) binder_idents;
    if block_is_open b then merge hv
  end;
  match !preds with
  | [] -> unit_const
  | _ ->
      start_block b ljoin;
      emit b (Phi (result_ty, res, List.rev !preds));
      res

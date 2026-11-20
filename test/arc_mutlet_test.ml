(* ARC pass regression tests: a [MutLet] slot must be released exactly once.

   These tests drive hand-written [Lmutlet] terms through [Anf.of_lambda]
   and [Arc_pass.run] to exercise mutable-slot control flow directly.
   [local_refs_test.ml] covers promotion from OCaml source.

   A mutable slot lives until the enclosing scope exits (the function-exit
   [Halt] or a [Raise]). Control flowing through a [LetJoin] rhs, loop
   condition/body, or loop-exit continuation is NOT a scope exit, so none of
   those positions may emit [ReleaseMut] for a mutable that stays in scope. *)

let const n = Lambda.Lconst (Const_int n)

(* Compact diagnostic dump of an ANF expression (ident names only). *)
let dump_ident id = Ident.name id
let rec dump (e : Anf.aexpr) : string =
  match e with
  | Anf.Halt a -> Printf.sprintf "(halt %s)" (dump_atom a)
  | Anf.HaltScalar id -> Printf.sprintf "(halt_scalar %s)" (dump_ident id)
  | Anf.Let (id, ce, body) ->
      Printf.sprintf "(let %s %s %s)" (dump_ident id) (dump_ce ce) (dump body)
  | Anf.MutLet (id, ce, body) ->
      Printf.sprintf "(mutlet %s %s %s)" (dump_ident id) (dump_ce ce) (dump body)
  | Anf.LetJoin (id, rhs, body) ->
      Printf.sprintf "(join %s %s %s)" (dump_ident id) (dump rhs) (dump body)
  | Anf.Release (id, cont) -> Printf.sprintf "(release %s %s)" (dump_ident id) (dump cont)
  | Anf.ReleaseMut (id, cont) ->
      Printf.sprintf "(release_mut %s %s)" (dump_ident id) (dump cont)
  | Anf.Retain (id, cont) -> Printf.sprintf "(retain %s %s)" (dump_ident id) (dump cont)
  | Anf.Raise a -> Printf.sprintf "(raise %s)" (dump_atom a)
  | Anf.Unwind -> "unwind"
  | Anf.If (c, th, el) | Anf.ScalarIf (_, c, th, el) ->
      Printf.sprintf "(if %s %s %s)" (dump_atom c) (dump th) (dump el)
  | Anf.While (cond, body) -> Printf.sprintf "(while %s %s)" (dump cond) (dump body)
  | Anf.For (i, s, e2, _, body) ->
      Printf.sprintf "(for %s %s %s %s)" (dump_ident i) (dump_atom s) (dump_atom e2)
        (dump body)
  | Anf.CheckExn (a, b) -> Printf.sprintf "(checkexn %s %s)" (dump a) (dump b)
  | Anf.TryWith (body, x, h) ->
      Printf.sprintf "(try %s %s %s)" (dump body) (dump_ident x) (dump h)
  | Anf.StaticCatch (body, hid, _, h, _) ->
      Printf.sprintf "(catch %d %s %s)" hid (dump body) (dump h)
  | Anf.StaticRaise (hid, args) ->
      Printf.sprintf "(sraise %d [%s])" hid
        (String.concat ", " (List.map dump_atom args))
  | Anf.LetRec (bs, body) ->
      Printf.sprintf "(letrec [%s] %s)"
        (String.concat "; " (List.map (fun rb -> dump_ident rb.Anf.id) bs))
        (dump body)
  | Anf.Switch (a, sw) ->
      Printf.sprintf "(switch %s [%s] [%s] %s)" (dump_atom a)
        (String.concat "; "
           (List.map (fun (k, arm) -> Printf.sprintf "%d:%s" k (dump arm)) sw.Anf.consts))
        (String.concat "; "
           (List.map (fun (k, arm) -> Printf.sprintf "%d:%s" k (dump arm)) sw.Anf.blocks))
        (match sw.Anf.fail with Some f -> dump f | None -> "-")
  | Anf.StringSwitch (a, cases, fail) ->
      Printf.sprintf "(strswitch %s [%s] %s)" (dump_atom a)
        (String.concat "; "
           (List.map (fun (s, arm) -> Printf.sprintf "%s:%s" s (dump arm)) cases))
        (match fail with Some f -> dump f | None -> "-")
  | Anf.ShadowPush (a, b, c, cont) ->
      Printf.sprintf "(spush [%s] [%s] [%s] %s)"
        (String.concat "," (List.map dump_ident a))
        (String.concat "," (List.map dump_ident b))
        (String.concat "," (List.map dump_ident c)) (dump cont)
  | Anf.ShadowPop (n, m, cont) -> Printf.sprintf "(spop %d %d %s)" n m (dump cont)
  | Anf.DropReuse (v, t, cont) ->
      Printf.sprintf "(dropreuse %s %s %s)" (dump_ident v) (dump_ident t) (dump cont)
  | Anf.FreeReuse (t, cont) -> Printf.sprintf "(freereuse %s %s)" (dump_ident t) (dump cont)
and dump_atom (a : Anf.atom) : string =
  match a with
  | Anf.Var id -> dump_ident id
  | Anf.MutVar id -> "*" ^ dump_ident id
  | Anf.Int n -> string_of_int n
  | Anf.Char c -> Printf.sprintf "%C" c
  | Anf.String s -> Printf.sprintf "%S" s
  | Anf.Float f -> string_of_float f
  | Anf.Int32 n -> Printf.sprintf "%ldl" n
  | Anf.Int64 n -> Printf.sprintf "%LdL" n
  | Anf.Nativeint n -> Printf.sprintf "%ndn" n
  | Anf.BorrowedField (i, owner) -> Printf.sprintf "(borrow-field%d %s)" i (dump_atom owner)
  | Anf.ConstFloatArray fs ->
      Printf.sprintf "farr[%d]" (List.length fs)
  | Anf.ConstBlock (t, _) -> Printf.sprintf "blk%d" t
  | Anf.Unit -> "()"
and dump_ce (ce : Anf.cexpr) : string =
  match ce with
  | Anf.Atom a -> dump_atom a
  | Anf.Binop (op, a, b) ->
      let name =
        match op with
        | Anf.Add -> "add" | Anf.Sub -> "sub" | Anf.Mul -> "mul"
        | Anf.Div -> "div" | Anf.Mod -> "mod" | Anf.And -> "and"
        | Anf.Or -> "or" | Anf.Xor -> "xor" | Anf.Lsl -> "lsl"
        | Anf.Lsr -> "lsr" | Anf.Asr -> "asr" | Anf.Cmp _ -> "cmp"
        | Anf.Compare_ints -> "icmp" | Anf.Isout -> "isout"
        | Anf.Float_arithmetic Addf -> "fadd" | Anf.Float_arithmetic Subf -> "fsub"
        | Anf.Float_arithmetic Mulf -> "fmul" | Anf.Float_arithmetic Divf -> "fdiv"
        | Anf.Fcmp _ -> "fcmp"
        | Anf.Compare_floats -> "fcmp3"
        | Anf.Bint_add _ -> "badd" | Anf.Bint_sub _ -> "bsub"
        | Anf.Bint_mul _ -> "bmul" | Anf.Bint_div _ -> "bdiv"
        | Anf.Bint_mod _ -> "bmod" | Anf.Bint_and _ -> "band"
        | Anf.Bint_or _ -> "bor" | Anf.Bint_xor _ -> "bxor"
        | Anf.Bint_lsl _ -> "blsl" | Anf.Bint_lsr _ -> "blsr"
        | Anf.Bint_asr _ -> "basr" | Anf.Bint_cmp _ -> "bcmp"
        | Anf.Compare_bints _ -> "bcmp3"
      in
      Printf.sprintf "(binop %s %s %s)" name (dump_atom a) (dump_atom b)
  | Anf.Unop (op, a) ->
      let name =
        match op with
        | Anf.Neg -> "neg" | Anf.Not -> "not" | Anf.Offset n ->
            Printf.sprintf "offset%d" n
        | Anf.Isint -> "isint" | Anf.String_length -> "strlen"
        | Anf.Array_length -> "arrlen"
        | Anf.Float_of_int -> "fofint" | Anf.Int_of_float -> "ioff"
        | Anf.Fneg -> "fneg" | Anf.Fabs -> "fabs"
        | Anf.Bint_of_int _ -> "bofint" | Anf.Int_of_bint _ -> "iofb"
        | Anf.Bint_cvt _ -> "bcvt" | Anf.Bint_neg _ -> "bneg"
      in
      Printf.sprintf "(unop %s %s)" name (dump_atom a)
  | Anf.MakeBlock (t, args) ->
      Printf.sprintf "(blk%d %s)" t (String.concat "," (List.map dump_atom args))
  | Anf.AllocReuse (reuse, t, args) ->
      let tokens = reuse.primary :: Option.to_list reuse.fallback in
      Printf.sprintf "(reuse %s %d [%s])"
        (String.concat "/" (List.map dump_ident tokens)) t
        (String.concat "," (List.map dump_atom args))
  | Anf.App (f, args) ->
      Printf.sprintf "(app %s [%s])" (dump_atom f)
        (String.concat "," (List.map dump_atom args))
  | Anf.DirectApp (target, args) ->
      Printf.sprintf "(direct %s [%s])" target.symbol
        (String.concat "," (List.map dump_atom args))
  | Anf.Fun _ -> "(fun)"
  | Anf.Assign (id, a) | Anf.AssignImm (id, a) -> Printf.sprintf "(assign %s %s)" (dump_ident id) (dump_atom a)
  | Anf.Field (i, _, a) -> Printf.sprintf "(field%d %s)" i (dump_atom a)
  | Anf.SetField (i, _, a, b) ->
      Printf.sprintf "(setfield%d %s %s)" i (dump_atom a) (dump_atom b)
  | Anf.Ccall (name, args) ->
      Printf.sprintf "(ccall %s [%s])" name (String.concat "," (List.map dump_atom args))
  | Anf.GetGlobal g -> Printf.sprintf "(global %s)" g
  | _ -> "<cexpr>"


(* Count [ReleaseMut] instructions targeting [id] in an ANF expression. *)
let rec count_release_mut id (e : Anf.aexpr) : int =
  let count_atom acc = function
    | Anf.BorrowedField _ -> acc
    | Anf.Var _ | Anf.MutVar _ | Anf.Int _ | Anf.Char _ | Anf.String _
    | Anf.Float _ | Anf.Int32 _ | Anf.Int64 _ | Anf.Nativeint _
    | Anf.ConstFloatArray _ | Anf.ConstBlock _ | Anf.Unit ->
        acc
  in
  let count_ce acc = function
    | Anf.Atom a -> count_atom acc a
    | Anf.Binop (_, a, b) | Anf.IntSelect (_, a, b) -> count_atom (count_atom acc a) b
    | Anf.Unop (_, a) -> count_atom acc a
    | Anf.MakeBlock (_, args) | Anf.AllocReuse (_, _, args)
    | Anf.MakeArray (_, args) ->
        List.fold_left count_atom acc args
    | Anf.Field (_, _, a) | Anf.FloatField (_, a) | Anf.OffsetRef (_, a)
    | Anf.CreateBytes a | Anf.Bswap16 a | Anf.BswapBint (_, a) ->
        count_atom acc a
    | Anf.SetField (_, _, a, b) | Anf.SetFloatField (_, a, b) ->
        count_atom (count_atom acc a) b
    | Anf.StringGet (_, a, b) | Anf.BytesGetN (_, _, a, b)
    | Anf.ArrayGet (_, _, a, b) ->
        count_atom (count_atom acc a) b
    | Anf.BytesSet (_, a, b, c) | Anf.BytesSetN (_, _, a, b, c) ->
        count_atom (count_atom (count_atom acc a) b) c
    | Anf.ArraySet (_, _, a, b, c) ->
        count_atom (count_atom (count_atom acc a) b) c
    | Anf.MakeArrayInit (a, b) -> count_atom (count_atom acc a) b
    | Anf.App (f, args) -> List.fold_left count_atom (count_atom acc f) args
    | Anf.Builtin (_, _, a) -> count_atom acc a
    | Anf.BigarrayAccess (_, args) | Anf.Ccall (_, args) | Anf.DirectApp (_, args) ->
        List.fold_left count_atom acc args
    | Anf.IntegerOfInt _ | Anf.IntOfInteger _ | Anf.IntegerConvert _ -> acc
    | Anf.ScalarLoad _ | Anf.ScalarStore _ | Anf.FloatBinop _ | Anf.IntegerBinop _ | Anf.IntegerCompare _ | Anf.IntegerNeg _ | Anf.IntegerShift _ | Anf.ScalarValue _ | Anf.GetGlobal _ -> acc
    | Anf.Fun lf -> count_release_mut id lf.Anf.body
    | Anf.Assign (_, a) | Anf.AssignImm (_, a) -> count_atom acc a
  in
  match e with
  | Anf.Release (_rel, cont) -> count_release_mut id cont
  | Anf.ReleaseMut (m', cont) ->
      (if Ident.same m' id then 1 else 0) + count_release_mut id cont
  | Anf.Halt a -> count_atom 0 a
  | Anf.HaltScalar _ -> 0
  | Anf.Let (_, ce, body) | Anf.MutLet (_, ce, body) ->
      count_ce (count_release_mut id body) ce
  | Anf.LetJoin (_, rhs, body) ->
      count_release_mut id rhs + count_release_mut id body
  | Anf.LetRec (bindings, body) ->
      List.fold_left
        (fun acc rb -> acc + count_release_mut id rb.Anf.def.Anf.body)
        (count_release_mut id body) bindings
  | Anf.If (_, th, el) | Anf.ScalarIf (_, _, th, el) -> count_release_mut id th + count_release_mut id el
  | Anf.Switch (_, sw) ->
      let arms =
        List.map snd sw.Anf.consts @ List.map snd sw.Anf.blocks
        @ (match sw.Anf.fail with Some f -> [ f ] | None -> [])
      in
      List.fold_left (fun acc a -> acc + count_release_mut id a) 0 arms
  | Anf.StringSwitch (_, cases, fail) ->
      List.fold_left
        (fun acc (_, a) -> acc + count_release_mut id a)
        (match fail with Some f -> count_release_mut id f | None -> 0)
        cases
  | Anf.StaticCatch (body, _, _, handler, _) ->
      count_release_mut id body + count_release_mut id handler
  | Anf.StaticRaise (_, args) -> List.fold_left count_atom 0 args
  | Anf.CheckExn (unwind, ok) ->
      (* A poll may leave the function early. Check that exit independently
         of the normal path, where the slot remains live past the loop. *)
      let releases = count_release_mut id unwind in
      if releases <> 1 then
        failwith (Printf.sprintf "expected one mutable release on unwind, got %d: %s"
                    releases (dump unwind));
      count_release_mut id ok
  | Anf.While (cond, body) ->
      count_release_mut id cond + count_release_mut id body
  | Anf.For (_, _, _, _, body) -> count_release_mut id body
  | Anf.TryWith (body, _, handler) ->
      count_release_mut id body + count_release_mut id handler
  | Anf.Raise a -> count_atom 0 a
  | Anf.Unwind -> 0
  | Anf.Retain (_, cont) | Anf.DropReuse (_, _, cont) | Anf.FreeReuse (_, cont)
  | Anf.ShadowPop (_, _, cont) ->
      count_release_mut id cont
  | Anf.ShadowPush (_, _, _, cont) -> count_release_mut id cont

let run_case name lam expected =
  let m = Ident.create_local "m" in
  let lam : Lambda.lambda = lam m in
  match
    Anf.of_lambda
      { Lambda.module_ident = Ident.create_local "Test";
        main_module_block_size = 0;
        required_globals = Ident.Set.empty;
        code = lam }
  with
  | Error msg ->
      Printf.printf "%s: ERROR %s\n" name msg;
      false
  | Ok anf -> (
      let arc = Arc_pass.run anf in
      let got = count_release_mut m arc.Anf.code in
      if got = expected then begin
        Printf.printf "%s: PASS (%d release)\n" name got;
        true
      end
      else begin
        Printf.printf "%s: FAIL expected %d ReleaseMut, got %d\nARC ANF: %s\n"
          name expected got (dump arc.Anf.code);
        false
      end)

(* --- Lambda term shapes -------------------------------------------------- *)

let heap_init =
  Lambda.Lprim (Pmakeblock (0, Immutable, None), [const 1; const 2],
                Debuginfo.Scoped_location.Loc_unknown)

(* [let mutable m = (1, 2) in
     (if 1 then 2 else 3);
     m]
   The [if] is in non-tail position, so the frontend ANF lowering wraps it in
   [LetJoin (join, If (..., Halt .., Halt ..), ... read m ... Halt ..)] and
   the mutable stays live in the join body. *)
let letjoin_case m =
  Lambda.Lmutlet (Pgenval, m, heap_init,
    Lambda.Lsequence
      ( Lambda.Lifthenelse (const 1, const 2, const 3),
        Lambda.Lmutvar m ))

(* [let mutable m = (1, 2) in while 1 do () done; m] *)
let while_case m =
  Lambda.Lmutlet (Pgenval, m, heap_init,
    Lambda.Lsequence
      (Lambda.Lwhile (const 1, const 0), Lambda.Lmutvar m))

(* [let mutable m = (1, 2) in for _i = 0 to 9 do () done; m] *)
let for_case m =
  let i = Ident.create_local "i" in
  Lambda.Lmutlet (Pgenval, m, heap_init,
    Lambda.Lsequence
      ( Lambda.Lfor (i, const 0, const 9, Asttypes.Upto, const 0),
        Lambda.Lmutvar m ))

(* Control: [let mutable m = (1, 2) in m] — exactly one release at the
   function-exit Halt, no join or loop in between. *)
let plain_case m = Lambda.Lmutlet (Pgenval, m, heap_init, Lambda.Lmutvar m)

let () =
  let failures = ref 0 in
  let check name lam expected =
    if not (run_case name lam expected) then incr failures
  in
  check "mutlet alone" plain_case 1;
  check "mutlet across letjoin" letjoin_case 1;
  check "mutlet across while" while_case 1;
  check "mutlet across for" for_case 1;
  exit (if !failures = 0 then 0 else 1)

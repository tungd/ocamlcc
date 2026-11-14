(* Lambda -> QBE IL code generation for the supported subset.

   Value representation (design doc §4.2): the least-significant bit tags
   immediates — [val land 1 = 1] is an unboxed 63-bit integer (OCaml [int],
   bool, constant constructor), even words are pointers to heap-allocated
   objects (today: string literals; later: ARC-managed objects).

   Supported Lambda subset:
   - integer constants, string literals (data emission), let bindings,
     sequences, arithmetic/comparison primitives, if/then/else
   - top-level (possibly recursive) unary-or-n-ary function definitions
     with direct saturated calls
   - self tail-calls lower to explicit QBE loops: a jump back to the entry
     block with fresh arguments (design doc §7, risk 1)
   - direct calls to known Stdlib builtins (see [Builtins])

   The builder is a tightly owned mutation kernel: emission order is the
   algorithm, so insts/labels accumulate in one local record and are
   exported as an immutable [Qbe_il.module_]. *)

open Qbe_il

exception Unsupported of string

(* ------------------------------------------------------------------ *)
(* Builder                                                             *)
(* ------------------------------------------------------------------ *)

type builder = {
  prefix : string;  (* module prefix for global function names *)
  mutable temp_counter : int;
  mutable label_counter : int;
  mutable data_counter : int;
  mutable open_label : string;
  mutable insts : inst list;   (* reversed *)
  mutable term : term option;  (* terminator of the open block, if closed *)
  mutable blocks : block list; (* reversed, closed blocks *)
  mutable fn_params : (ty * string) list;
  (* One variable table for the whole module: Ident stamps are globally
     unique, and bindings are removed when their scope exits. *)
  vars : (Ident.t, t) Hashtbl.t;
  (* Known module-level functions: ident -> (global name, arity). *)
  funs : (Ident.t, string * int) Hashtbl.t;
  mutable funcs : func list; (* reversed *)
  mutable datas : data list; (* reversed *)
  mutable entry_label : string;
  mutable self : Ident.t option; (* enclosing function, for tail calls *)
  (* Self tail-call sites of the enclosing function, in reverse order of
     emission: (predecessor block label, argument values). *)
  mutable tail_sites : (string * t list) list;
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
    funs = Hashtbl.create 16;
    funcs = [];
    datas = [];
    entry_label = "start";
    self = None;
    tail_sites = [] }

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
  | None ->
      if b.insts <> [] then begin
        (* fallthrough is illegal in QBE; close with a jump. An entirely
           empty open block (the builder's initial state) is re-labelled
           instead. *)
        close_block b (Jmp label)
      end
  | Some _ -> ());
  b.open_label <- label;
  b.term <- None

(* Terminates the current function body unless a tail self-call loop jump
   already closed the final block. *)
let close_ret b value =
  match b.term with
  | Some _ -> ()
  | None -> close_block b (Ret value)

(* ------------------------------------------------------------------ *)
(* Value representation helpers                                        *)
(* ------------------------------------------------------------------ *)

let unit_const = Int 1L

let tag_int n = Int64.logor (Int64.mul (Int64.of_int n) 2L) 1L

(* [a ty b] with the tag-bit trick: tagged x + tagged y - 1 = tagged (x+y). *)
let add_tagged b a b' dst =
  let sum = fresh_temp b "sum" in
  emit b (Binop (Add, Long, sum, a, b'));
  emit b (Binop (Sub, Long, dst, sum, Int 1L))

let sub_tagged b a b' dst =
  let diff = fresh_temp b "sub" in
  emit b (Binop (Sub, Long, diff, a, b'));
  emit b (Binop (Add, Long, dst, diff, Int 1L))

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

(* Emits a data definition for a string literal (NUL-terminated) and returns
   its untagged pointer. *)
let string_data b s =
  let name = Printf.sprintf "str.%d" b.data_counter in
  b.data_counter <- b.data_counter + 1;
  let plain c =
    let c = Char.code c in
    c >= 0x20 && c <= 0x7e && c <> Char.code '"' && c <> Char.code '\\'
  in
  let items =
    let rec go run acc i =
      if i >= String.length s then
        List.rev
          (if run = "" then acc else D_str run :: acc)
      else if plain s.[i] then
        go (String.concat "" [ run; String.make 1 s.[i] ]) acc (i + 1)
      else
        go "" (D_byte (Char.code s.[i]) :: (if run = "" then acc else D_str run :: acc))
          (i + 1)
    in
    go "" [] 0
  in
  b.datas <- { name; items } :: b.datas;
  Global name

(* ------------------------------------------------------------------ *)
(* Unsupported-construct reporting                                     *)
(* ------------------------------------------------------------------ *)

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
  | Lfunction _ -> "function value (closures are not yet supported)"
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

(* ------------------------------------------------------------------ *)
(* Expression compilation                                              *)
(* ------------------------------------------------------------------ *)

let cmp_of_ocaml : Lambda.integer_comparison -> Cmp.t = function
  | Ceq -> Eq
  | Cne -> Ne
  | Clt -> Slt
  | Cle -> Sle
  | Cgt -> Sgt
  | Cge -> Sge

let rec expr b (tail : bool) (lam : Lambda.lambda) : t =
  match lam with
  | Lconst (Const_int n) -> Int (tag_int n)
  | Lconst (Const_immstring s) -> string_data b s
  | Lvar id -> Hashtbl.find b.vars id
  | Llet (_, _, id, Lfunction lf, body) ->
      (* A toplevel (non-recursive) function definition. *)
      let g = compile_function b id lf in
      Hashtbl.replace b.vars id (Global g);
      expr b tail body
  | Llet (_, _, id, arg, body) | Lmutlet (_, id, arg, body) ->
      let v = expr b false arg in
      Hashtbl.replace b.vars id v;
      let result = expr b tail body in
      Hashtbl.remove b.vars id;
      result
  | Lletrec (bindings, body) ->
      (* Register every name first so bodies can call each other, then
         compile the function definitions, then the continuation. *)
      List.iter
        (fun (rb : Lambda.rec_binding) ->
          let g =
            Printf.sprintf "ocamlcc_%s_%s" b.prefix
              (sanitize (Ident.name rb.id))
          in
          Hashtbl.replace b.funs rb.id (g, List.length rb.def.params);
          Hashtbl.replace b.vars rb.id (Global g))
        bindings;
      List.iter (fun (rb : Lambda.rec_binding) -> ignore (compile_function b rb.id rb.def)) bindings;
      expr b tail body
  | Lsequence (a, b') ->
      ignore (expr b false a);
      expr b tail b'
  | Levent (l, _) -> expr b tail l
  | Lifused (_, l) -> expr b tail l
  | Lprim (Pignore, [ arg ], _) ->
      ignore (expr b false arg);
      unit_const
  (* Module initialization envelope: translmod ends the program with a
     setglobal of the module block; the unit value is an empty block, whose
     fields are evaluated for effect. *)
  | Lprim (Psetglobal _, [ body ], _) -> expr b tail body
  | Lprim (Pmakeblock (0, _, _), args, _) ->
      List.iter (fun a -> ignore (expr b false a)) args;
      unit_const
  | Lprim (Paddint, [ a; c ], _) -> arith_binop add_tagged a c b
  | Lprim (Psubint, [ a; c ], _) -> arith_binop sub_tagged a c b
  | Lprim (Pmulint, [ a; c ], _) -> mul_tagged b a c
  | Lprim (Pdivint _, [ a; c ], _) -> div_tagged b a c
  | Lprim (Pnegint, [ a ], _) ->
      let av = expr b false a in
      let dst = fresh_temp b "neg" in
      emit b (Binop (Sub, Long, dst, Int 2L, av));
      dst
  (* In value position a comparison result must be retagged (0/1 -> 1/3);
     condition position uses the raw result via [expr_cond]. *)
  | Lprim (Pintcomp cmp, [ a; c ], _) ->
      let raw = intcomp_raw b cmp a c in
      retag b raw
  | Lapply { ap_func; ap_args; _ } -> apply b tail lam ap_func ap_args
  | Lifthenelse (cond, th, el) -> ifthenelse b tail cond th el
  | _ -> raise (Unsupported (describe lam))

(* [f dst a c] where [f] composes two tagged longs into [dst]. *)
and arith_binop f a c b =
  let av = expr b false a in
  let cv = expr b false c in
  let dst = fresh_temp b "arith" in
  f b av cv dst;
  dst

and mul_tagged b a c =
  let av = expr b false a in
  let cv = expr b false c in
  let ua = untag b av in
  let uc = untag b cv in
  let prod = fresh_temp b "mul" in
  emit b (Binop (Mul, Long, prod, ua, uc));
  retag b prod

and div_tagged b a c =
  let av = expr b false a in
  let cv = expr b false c in
  let ua = untag b av in
  let uc = untag b cv in
  let quot = fresh_temp b "div" in
  emit b (Binop (Div, Long, quot, ua, uc));
  retag b quot

and intcomp_raw b cmp a c =
  let av = expr b false a in
  let cv = expr b false c in
  (* Tagged integers preserve signed order (2x+1 is monotone), so no untag. *)
  let dst = fresh_temp b "cmp" in
  emit b (Cmp (cmp_of_ocaml cmp, Long, dst, av, cv));
  dst

(* Condition position: a direct comparison yields the raw 0/1 that [jnz]
   needs; any other tagged boolean is untagged back to 0/1. *)
and expr_cond b (lam : Lambda.lambda) =
  match lam with
  | Lprim (Pintcomp cmp, [ a; c ], _) -> intcomp_raw b cmp a c
  | _ ->
      let v = expr b false lam in
      untag b v

and expr_builtin b arg_kind symbol arg =
  let v = expr b false arg in
  let raw =
    match arg_kind with
    | Builtins.Int_arg -> untag b v
    | Builtins.String_arg -> v
  in
  emit b (Call_void { fn = Global symbol; args = [ (Long, raw) ] });
  unit_const

and apply b tail (lam : Lambda.lambda) (ap_func : Lambda.lambda) ap_args =
  let is_self id =
    match b.self with
    | Some s -> Ident.same s id
    | None -> false
  in
  match ap_func with
  | Lvar id when tail && is_self id -> (
      (* Self tail-call -> explicit loop: jump back to the loop header; the
         phi nodes there pick up these arguments on the backedge. *)
      match Hashtbl.find_opt b.funs id with
      | Some (_, arity) when List.length ap_args = arity ->
          let args =
            List.map (fun a -> expr b false a) ap_args
          in
          b.tail_sites <- (b.open_label, args) :: b.tail_sites;
          close_block b (Jmp b.entry_label);
          unit_const
      | _ -> raise (Unsupported (describe lam)))
  | Lvar id -> (
      match Hashtbl.find_opt b.funs id with
      | Some (g, arity) when List.length ap_args = arity ->
          let args =
            List.map (fun a -> (Long, expr b false a)) ap_args
          in
          let dst = fresh_temp b "call" in
          emit b (Call (Long, dst, { fn = Global g; args }));
          dst
      | Some (_, _) ->
          raise (Unsupported (Printf.sprintf "partial application of %s" (describe lam)))
      | None -> (
          match Builtins.resolve ap_func with
          | Some { symbol; arg_kind } -> (
              match ap_args with
              | [ arg ] -> expr_builtin b arg_kind symbol arg
              | _ -> raise (Unsupported (describe lam)))
          | None -> raise (Unsupported (describe lam))))
  | _ -> (
      match Builtins.resolve ap_func with
      | Some { symbol; arg_kind } -> (
          match ap_args with
          | [ arg ] -> expr_builtin b arg_kind symbol arg
          | _ -> raise (Unsupported (describe lam)))
      | None -> raise (Unsupported (describe lam)))

and ifthenelse b tail cond th el =
  let cv = expr_cond b cond in
  let lthen = fresh_label b "then" in
  let lelse = fresh_label b "else" in
  close_block b (Br (cv, lthen, lelse));
  if tail then begin
    (* Tail position: each branch either tail-jumps (self call) or jumps to
       a shared epilogue block whose phi carries the result. *)
    let lepi = fresh_label b "ret" in
    let res = fresh_temp b "res" in
    start_block b lthen;
    let tv = expr b true th in
    let preds = ref [] in
    if b.term = None then begin
      preds := (b.open_label, tv) :: !preds;
      close_block b (Jmp lepi)
    end;
    start_block b lelse;
    let ev = expr b true el in
    if b.term = None then begin
      preds := (b.open_label, ev) :: !preds;
      close_block b (Jmp lepi)
    end;
    (match !preds with
    | [] -> (* both branches tail-jumped; no epilogue is reachable *)
        ()
    | _ ->
        start_block b lepi;
        emit b (Phi (Long, res, List.rev !preds)));
    res
  end
  else begin
    let ljoin = fresh_label b "join" in
    let res = fresh_temp b "if" in
    start_block b lthen;
    let tv = expr b false th in
    emit b (Copy (Long, res, tv));
    close_block b (Jmp ljoin);
    start_block b lelse;
    let ev = expr b false el in
    emit b (Copy (Long, res, ev));
    close_block b (Jmp ljoin);
    start_block b ljoin;
    res
  end

(* ------------------------------------------------------------------ *)
(* Function definitions                                                *)
(* ------------------------------------------------------------------ *)

and function_global_name b id =
  Printf.sprintf "ocamlcc_%s_%s" b.prefix (sanitize (Ident.name id))

and compile_function b id (lf : Lambda.lfunction) : string =
  let g = function_global_name b id in
  let arity = List.length lf.params in
  Hashtbl.replace b.funs id (g, arity);
  (* Closures are not supported: the body may only reference its own
     parameters and known module-level functions. *)
  let free =
    Lambda.free_variables lf.body
    |> Ident.Set.filter (fun v ->
           not (List.exists (fun (p, _) -> Ident.same p v) lf.params)
           && not (Hashtbl.mem b.funs v))
  in
  if not (Ident.Set.is_empty free) then
    raise
      (Unsupported
         (Printf.sprintf "closure capturing free variables (function %s)"
            (sanitize (Ident.name id))));
  (* Snapshot the enclosing (module or outer function) block state. *)
  let saved_self = b.self in
  let saved_entry = b.entry_label in
  let saved_insts = b.insts in
  let saved_term = b.term in
  let saved_blocks = b.blocks in
  let saved_open_label = b.open_label in
  let saved_tail_sites = b.tail_sites in
  let param_binders =
    List.map (fun (pid, _) -> (pid, sanitize (Ident.name pid))) lf.params
  in
  (* QBE forbids jumping to a function's start block, so self tail-calls
     target a dedicated loop-header block that @start jumps to. Loop-carried
     parameters flow through phi nodes in the header. *)
  let loop_binders =
    List.map (fun _ -> fresh_name b "loop") lf.params
  in
  b.self <- Some id;
  b.entry_label <- "loop";
  b.open_label <- "start";
  b.insts <- [];
  b.term <- None;
  b.blocks <- [];
  b.tail_sites <- [];
  b.fn_params <- List.map (fun (_, n) -> (Long, n)) param_binders;
  close_block b (Jmp "loop");
  start_block b "loop";
  List.iter2
    (fun (pid, _) loop_name -> Hashtbl.replace b.vars pid (Temp loop_name))
    param_binders loop_binders;
  let result = expr b true lf.body in
  close_ret b (Some result);
  (* Bind the loop header's phis: each loop-carried parameter merges its
     @start value (the formal parameter) with every backedge argument. *)
  if param_binders <> [] then begin
    let phis =
      List.mapi
        (fun i (_, formal) ->
          let args =
            ("start", Temp formal)
            :: List.filter_map
                 (fun (lbl, vs) ->
                   match List.nth_opt vs i with
                   | Some v -> Some (lbl, v)
                   | None -> None)
                 (List.rev b.tail_sites)
          in
          Phi (Long, Temp (List.nth loop_binders i), args))
        param_binders
    in
    b.blocks <-
      List.map
        (fun blk ->
          if blk.label = "loop" then { blk with insts = phis @ blk.insts }
          else blk)
        b.blocks
  end;
  let func =
    { name = g;
      export = true;
      retty = Some Long;
      params = b.fn_params;
      blocks = List.rev b.blocks }
  in
  b.funcs <- func :: b.funcs;
  (* Restore the enclosing scope. *)
  b.self <- saved_self;
  b.entry_label <- saved_entry;
  b.insts <- saved_insts;
  b.term <- saved_term;
  b.blocks <- saved_blocks;
  b.open_label <- saved_open_label;
  b.tail_sites <- saved_tail_sites;
  List.iter (fun (pid, _) -> Hashtbl.remove b.vars pid) param_binders;
  g

(* ------------------------------------------------------------------ *)
(* Program compilation                                                 *)
(* ------------------------------------------------------------------ *)

let compile_program (program : Lambda.program) : Qbe_il.module_ =
  let b = builder (sanitize (Ident.name program.Lambda.module_ident)) in
  start_block b "start";
  ignore (expr b false program.code);
  close_ret b None;
  let init_func =
    { name = "ocamlcc_module_init";
      export = true;
      retty = None;
      params = [];
      blocks = List.rev b.blocks }
  in
  { funcs = List.rev (init_func :: b.funcs); datas = List.rev b.datas }

let compile_program program =
  try Ok (compile_program program) with Unsupported what -> Error what

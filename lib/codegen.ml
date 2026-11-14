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

(* Module-level function registry entry. Members of a mutually
   tail-recursive group share one QBE function (the trampoline) selected by
   [tag]; [group_arity] is the group's uniform arity. *)
type fn_info = {
  global : string;
  arity : int;
  tag : int64 option;
  group_arity : int;
  group_name : string option;
}

(* A static catch handler (pattern-match lowering): raise sites record their
   predecessor block and argument values for the handler's phis. *)
type handler = {
  hlabel : string;
  hbinders : Ident.t list;
  mutable hpreds : (string * t list) list; (* reversed *)
}

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
  (* Known module-level functions. *)
  funs : (Ident.t, fn_info) Hashtbl.t;
  (* Mutually tail-recursive groups waiting to be compiled, keyed by group
     name; [compiled_groups] tracks what has been emitted. *)
  groups : (string, (Ident.t * Lambda.lfunction) list) Hashtbl.t;
  compiled_groups : (string, unit) Hashtbl.t;
  mutable group_counter : int;
  (* Static catch handlers in scope, keyed by raise id. *)
  handlers : (int, handler) Hashtbl.t;
  mutable funcs : func list; (* reversed *)
  mutable datas : data list; (* reversed *)
  mutable entry_label : string;
  mutable self : Ident.t option; (* enclosing function, for tail calls *)
  mutable cur_group : string option; (* group being compiled, if any *)
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
    groups = Hashtbl.create 8;
    compiled_groups = Hashtbl.create 8;
    group_counter = 0;
    handlers = Hashtbl.create 8;
    funcs = [];
    datas = [];
    entry_label = "start";
    self = None;
    cur_group = None;
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

(* Pads argument vectors to a group's uniform arity with unit values. *)
let pad_to n (vs : t list) : t list =
  vs @ List.init (max 0 (n - List.length vs)) (fun _ -> unit_const)

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
      (* A function definition: compile its group (trampoline) or standalone
         form, then bind the name to its global. *)
      define_function b id lf;
      Hashtbl.replace b.vars id
        (Global (Hashtbl.find b.funs id).global);
      expr b tail body
  | Llet (_, _, id, arg, body) | Lmutlet (_, id, arg, body) ->
      let v = expr b false arg in
      Hashtbl.replace b.vars id v;
      let result = expr b tail body in
      Hashtbl.remove b.vars id;
      result
  | Lletrec (bindings, body) ->
      (* Names are pre-registered during analysis; bind them all before
         compiling so bodies can call each other. *)
      List.iter
        (fun (rb : Lambda.rec_binding) ->
          define_function b rb.id rb.def;
          Hashtbl.replace b.vars rb.id
            (Global (Hashtbl.find b.funs rb.id).global))
        bindings;
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
  | Lswitch (scrut, sw, _) -> (
      if sw.Lambda.sw_blocks <> [] then
        raise (Unsupported "match on structured values (block constructors)")
      else expr b tail (desugar_switch scrut sw))
  | Lstaticraise (id, args) -> (
      match Hashtbl.find_opt b.handlers id with
      | Some h ->
          let vs = List.map (fun a -> expr b false a) args in
          h.hpreds <- (b.open_label, vs) :: h.hpreds;
          close_block b (Jmp h.hlabel);
          unit_const
      | None -> raise (Unsupported "uncaught static raise (internal)"))
  | Lstaticcatch (body, (id, binders), handler) ->
      staticcatch b tail id (List.map fst binders) body handler
  | _ -> raise (Unsupported (describe lam))

(* Rewrites an integer switch into a comparison chain reusing the if/else
   machinery. Pattern compilation binds complex scrutinees to variables, but
   we bind defensively anyway so each case compares one evaluation. *)
and desugar_switch (scrut : Lambda.lambda) (sw : Lambda.lambda_switch) :
    Lambda.lambda =
  let scrut :
    Lambda.lambda =
    match scrut with
    | Lconst _ | Lvar _ -> scrut
    | _ ->
        let id = Ident.create_local "switch_scrut" in
        Llet (Strict, Lambda.Pgenval, id, scrut, Lvar id)
  in
  let cmp k : Lambda.lambda =
    Lprim
      ( Pintcomp Ceq,
        [ scrut; Lconst (Const_int k) ],
        Debuginfo.Scoped_location.Loc_unknown )
  in
  let rec build :
    (int * Lambda.lambda) list -> Lambda.lambda option -> Lambda.lambda =
    fun cases default ->
    match (cases, default) with
    | [], Some d -> d
    | [ (_, last_arm) ], None -> last_arm
    | (k, arm) :: rest, d -> Lifthenelse (cmp k, arm, build rest d)
    | [], None -> assert false
  in
  build sw.Lambda.sw_consts sw.Lambda.sw_failaction

and staticcatch b tail id binder_idents body handler =
  let h =
    { hlabel = fresh_label b "catch";
      hbinders = binder_idents;
      hpreds = [] }
  in
  Hashtbl.replace b.handlers id h;
  let v = expr b tail body in
  Hashtbl.remove b.handlers id;
  let ljoin = fresh_label b "catchjoin" in
  let res = fresh_temp b "catch" in
  let preds = ref [] in
  let merge value =
    preds := (b.open_label, value) :: !preds;
    if tail then close_block b (Jmp ljoin)
    else begin
      emit b (Copy (Long, res, value));
      close_block b (Jmp ljoin)
    end
  in
  if b.term = None then merge v;
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
    let hv = expr b tail handler in
    List.iter (fun bid -> Hashtbl.remove b.vars bid) h.hbinders;
    if b.term = None then merge hv
  end;
  match !preds with
  | [] -> unit_const (* both paths dead; only possible in tail position *)
  | _ ->
      start_block b ljoin;
      if tail then emit b (Phi (Long, res, List.rev !preds));
      res

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
  let builtin_or_unsupported () =
    match Builtins.resolve ap_func with
    | Some { symbol; arg_kind } -> (
        match ap_args with
        | [ arg ] -> expr_builtin b arg_kind symbol arg
        | _ -> raise (Unsupported (describe lam)))
    | None -> raise (Unsupported (describe lam))
  in
  let is_self id =
    match b.self with
    | Some s -> Ident.same s id
    | None -> false
  in
  match ap_func with
  | Lvar id -> (
      match Hashtbl.find_opt b.funs id with
      | Some info when List.length ap_args = info.arity -> (
          match (info.tag, tail) with
          | Some tag, true when b.cur_group = info.group_name ->
              (* Tail call within the trampoline group being compiled (self
                 or mutual): jump to its dispatch header; the phi nodes there
                 pick up the backedge values. *)
              let vs =
                pad_to info.group_arity
                  (List.map (fun a -> expr b false a) ap_args)
              in
              b.tail_sites <- (b.open_label, Int tag :: vs) :: b.tail_sites;
              close_block b (Jmp b.entry_label);
              unit_const
          | Some tag, _ ->
              (* Call into a trampoline group: select the member, pad to the
                 group's uniform arity. *)
              let vs =
                pad_to info.group_arity
                  (List.map (fun a -> expr b false a) ap_args)
              in
              let dst = fresh_temp b "call" in
              emit b
                (Call
                   ( Long,
                     dst,
                     { fn = Global info.global;
                       args = (Long, Int tag) :: List.map (fun v -> (Long, v)) vs } ));
              dst
          | None, true when is_self id ->
              (* Standalone self tail-call -> explicit loop: jump back to
                 the loop header; its phis pick up these arguments. *)
              let vs = List.map (fun a -> expr b false a) ap_args in
              b.tail_sites <- (b.open_label, vs) :: b.tail_sites;
              close_block b (Jmp b.entry_label);
              unit_const
          | None, _ ->
              let args =
                List.map (fun a -> (Long, expr b false a)) ap_args
              in
              let dst = fresh_temp b "call" in
              emit b (Call (Long, dst, { fn = Global info.global; args }));
              dst)
      | Some _ ->
          raise
            (Unsupported (Printf.sprintf "partial application: %s" (describe lam)))
      | None -> builtin_or_unsupported ())
  | _ -> builtin_or_unsupported ()

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

(* Inserts phi nodes at the head of [header_label], one per loop-carried
   binder, merging [start_values] (from @start) with every recorded tail
   site's positional argument. *)
and insert_header_phis b header_label binder_names start_values =
  if binder_names <> [] then begin
    let sites = List.rev b.tail_sites in
    let phis =
      List.mapi
        (fun i name ->
          let args =
            ("start", List.nth start_values i)
            :: List.filter_map
                 (fun (lbl, vs) ->
                   match List.nth_opt vs i with
                   | Some v -> Some (lbl, v)
                   | None -> None)
                 sites
          in
          Phi (Long, Temp name, args))
        binder_names
    in
    b.blocks <-
      List.map
        (fun blk ->
          if blk.label = header_label then { blk with insts = phis @ blk.insts }
          else blk)
        b.blocks
  end

(* Emits the QBE code for a function definition encountered during the walk:
   pre-registered toplevel definitions keep their analysis-time entry (and
   their trampoline group, if any); nested definitions are registered as
   standalone here. *)
and define_function b id (lf : Lambda.lfunction) : unit =
  if not (Hashtbl.mem b.funs id) then
    Hashtbl.replace b.funs id
      { global = function_global_name b id;
        arity = List.length lf.params;
        tag = None;
        group_arity = List.length lf.params;
        group_name = None };
  let info = Hashtbl.find b.funs id in
  match info.group_name with
  | Some gname ->
      (* Compile the whole trampoline group on first encounter. *)
      if not (Hashtbl.mem b.compiled_groups gname) then begin
        Hashtbl.replace b.compiled_groups gname ();
        compile_group b gname (Hashtbl.find b.groups gname)
      end
  | None -> ignore (compile_function b id lf)

and compile_function b id (lf : Lambda.lfunction) : string =
  let g = (Hashtbl.find b.funs id).global in
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
  insert_header_phis b "loop" loop_binders
    (List.map (fun (_, formal) -> Temp formal) param_binders);
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

(* Compiles a mutually tail-recursive group as one trampoline: a single QBE
   function whose @dispatch header selects a member by tag and loops on tail
   calls. Design doc §7: mutual tail calls never grow the stack. *)
and compile_group b gname (members : (Ident.t * Lambda.lfunction) list) : unit =
  let max_arity =
    List.fold_left
      (fun acc ((_, lf) : Ident.t * Lambda.lfunction) ->
        max acc (List.length lf.params))
      0 members
  in
  let formal_sel = fresh_name b "grpfn" in
  let formal_slots = List.init max_arity (fun _ -> fresh_name b "grpslot") in
  let phi_sel = fresh_name b "dspsel" in
  let phi_slots = List.init max_arity (fun _ -> fresh_name b "dspslot") in
  (* Snapshot the enclosing state. *)
  let saved_self = b.self in
  let saved_group = b.cur_group in
  let saved_entry = b.entry_label in
  let saved_insts = b.insts in
  let saved_term = b.term in
  let saved_blocks = b.blocks in
  let saved_open_label = b.open_label in
  let saved_tail_sites = b.tail_sites in
  b.self <- None;
  b.cur_group <- Some gname;
  b.entry_label <- "dispatch";
  b.open_label <- "start";
  b.insts <- [];
  b.term <- None;
  b.blocks <- [];
  b.tail_sites <- [];
  b.fn_params <-
    (Long, formal_sel) :: List.map (fun n -> (Long, n)) formal_slots;
  close_block b (Jmp "dispatch");
  start_block b "dispatch";
  (* Dispatch chain: one comparison per member; the last falls through. *)
  let member_entries =
    List.mapi
      (fun i (id, _) ->
        (Int64.of_int (i + 1),
         Printf.sprintf "%s_entry" (sanitize (Ident.name id))))
      members
  in
  let rec dispatch_chain = function
    | [] -> close_block b Hlt (* unreachable: selector is always valid *)
    | [ (_, entry) ] -> close_block b (Jmp entry)
    | (tag, entry) :: rest ->
        let c = fresh_temp b "dspsel" in
        emit b (Cmp (Eq, Long, c, Temp phi_sel, Int tag));
        let lnext = fresh_label b "dspnext" in
        close_block b (Br (c, entry, lnext));
        start_block b lnext;
        dispatch_chain rest
  in
  dispatch_chain member_entries;
  (* Member bodies, each entered through its own block. *)
  let ret_preds = ref [] in
  List.iter2
    (fun (_, entry) ((_, lf) : Ident.t * Lambda.lfunction) ->
      start_block b entry;
      List.iteri
        (fun j (pid, _) ->
          Hashtbl.replace b.vars pid (Temp (List.nth phi_slots j)))
        lf.params;
      let result = expr b true lf.body in
      if b.term = None then begin
        ret_preds := (b.open_label, result) :: !ret_preds;
        close_block b (Jmp "ret")
      end;
      List.iter (fun (pid, _) -> Hashtbl.remove b.vars pid) lf.params)
    member_entries members;
  (* Shared return epilogue. *)
  (match !ret_preds with
  | [] -> start_block b "ret"; close_block b Hlt
  | _ ->
      start_block b "ret";
      let res = fresh_temp b "grpres" in
      emit b (Phi (Long, res, List.rev !ret_preds));
      close_block b (Ret (Some res)));
  (* Dispatch header phis: selector + uniform slots, merging @start with
     every group tail-call site. *)
  insert_header_phis b "dispatch" (phi_sel :: phi_slots)
    (Temp formal_sel :: List.map (fun n -> Temp n) formal_slots);
  let func =
    { name = gname;
      export = true;
      retty = Some Long;
      params = b.fn_params;
      blocks = List.rev b.blocks }
  in
  b.funcs <- func :: b.funcs;
  b.self <- saved_self;
  b.cur_group <- saved_group;
  b.entry_label <- saved_entry;
  b.insts <- saved_insts;
  b.term <- saved_term;
  b.blocks <- saved_blocks;
  b.open_label <- saved_open_label;
  b.tail_sites <- saved_tail_sites

(* ------------------------------------------------------------------ *)
(* Analysis: definitions, tail-call graph, strongly connected components *)
(* ------------------------------------------------------------------ *)

(* Toplevel function definitions, in source order. *)
let collect_defs (lam : Lambda.lambda) : (Ident.t * Lambda.lfunction) list =
  let rec go
    (acc : (Ident.t * Lambda.lfunction) list)
    (lam : Lambda.lambda) : (Ident.t * Lambda.lfunction) list =
    match lam with
    | Llet (_, _, id, Lfunction lf, body) | Lmutlet (_, id, Lfunction lf, body)
      -> go ((id, lf) :: acc) body
    | Lletrec (bindings, body) ->
        go
          (List.fold_left
             (fun acc (rb : Lambda.rec_binding) -> (rb.id, rb.def) :: acc)
             acc bindings)
          body
    | Lsequence (_, b') -> go acc b'
    | Levent (l, _) | Lifused (_, l) -> go acc l
    | Lprim (Psetglobal _, [ body ], _) -> go acc body
    | _ -> acc
  in
  List.rev (go [] lam)

(* Idents applied in tail position within a Lambda tree (self and nested
   function subtrees excluded — the latter compile separately). *)
let tail_callees (body : Lambda.lambda) : Ident.Set.t =
  let rec go (acc : Ident.Set.t) (tail : bool) (lam : Lambda.lambda) : Ident.Set.t =
    match lam with
    | Lapply { ap_func = Lvar id; _ } when tail -> Ident.Set.add id acc
    | Lapply _ -> acc
    | Lifthenelse (_, th, el) ->
        go (go acc tail th) tail el
    | Llet (_, _, _, arg, body) | Lmutlet (_, _, arg, body) ->
        go (go acc false arg) tail body
    | Lsequence (a, b') -> go (go acc false a) tail b'
    | Levent (l, _) | Lifused (_, l) -> go acc tail l
    | Lstaticcatch (body, (_, _), handler) ->
        go (go acc tail body) tail handler
    | Lswitch (_, sw, _) ->
        let acc =
          List.fold_left (fun acc (_, arm) -> go acc tail arm) acc
            sw.Lambda.sw_consts
        in
        (match sw.Lambda.sw_failaction with
        | Some fail -> go acc tail fail
        | None -> acc)
    | Lfunction _ -> acc (* nested definitions compile separately *)
    | Lprim (Psetglobal _, [ body ], _) -> go acc tail body
    | Lprim (_, args, _) when not tail ->
        List.fold_left (fun acc a -> go acc false a) acc args
    | _ -> acc
  in
  go Ident.Set.empty true body

(* Tarjan's strongly connected components over a small graph. *)
let strongly_connected_components nodes edges =
  let index = Hashtbl.create 16 in
  let low = Hashtbl.create 16 in
  let on_stack = Hashtbl.create 16 in
  let stack = ref [] in
  let counter = ref 0 in
  let comps = ref [] in
  let rec strongconnect v =
    Hashtbl.replace index v !counter;
    Hashtbl.replace low v !counter;
    Hashtbl.replace on_stack v true;
    incr counter;
    stack := v :: !stack;
    Ident.Set.iter
      (fun w ->
        if not (Hashtbl.mem index w) then begin
          strongconnect w;
          Hashtbl.replace low v
            (min (Hashtbl.find low v) (Hashtbl.find low w))
        end
        else if Hashtbl.find on_stack w then
          Hashtbl.replace low v
            (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (edges v);
    if Hashtbl.find low v = Hashtbl.find index v then begin
      let rec pop comp =
        match !stack with
        | w :: rest ->
            stack := rest;
            Hashtbl.replace on_stack w false;
            let comp = w :: comp in
            if Ident.same w v then comps := comp :: !comps
            else pop comp
        | [] -> assert false
      in
      pop []
    end
  in
  List.iter
    (fun v -> if not (Hashtbl.mem index v) then strongconnect v)
    nodes;
  List.rev !comps

(* ------------------------------------------------------------------ *)
(* Program compilation                                                 *)
(* ------------------------------------------------------------------ *)

let compile_program (program : Lambda.program) : Qbe_il.module_ =
  let b = builder (sanitize (Ident.name program.Lambda.module_ident)) in
  (* Analysis pass: register every toplevel definition, then find cycles in
     the mutual tail-call graph and trampoline-group them. *)
  let defs = collect_defs program.code in
  List.iter
    (fun ((id, lf) : Ident.t * Lambda.lfunction) ->
      Hashtbl.replace b.funs id
        { global = function_global_name b id;
          arity = List.length lf.params;
          tag = None;
          group_arity = List.length lf.params;
          group_name = None })
    defs;
  let def_idents = List.map fst defs in
  let callee_edges (id : Ident.t) : Ident.Set.t =
    match List.assoc_opt id defs with
    | None -> Ident.Set.empty
    | Some lf -> tail_callees lf.body
    |> Ident.Set.filter (fun callee ->
           not (Ident.same callee id)
           && List.exists (fun (id', _) -> Ident.same id' callee) defs)
  in
  let sccs =
    strongly_connected_components def_idents callee_edges
  in
  List.iter
    (fun comp ->
      if List.length comp >= 2 then begin
        let gname =
          Printf.sprintf "ocamlcc_%s_group%d" b.prefix b.group_counter
        in
        b.group_counter <- b.group_counter + 1;
        let members =
          List.map
            (fun id ->
              match List.assoc_opt id defs with
              | Some lf -> (id, lf)
              | None -> assert false)
            comp
        in
        Hashtbl.replace b.groups gname members;
        let group_arity =
          List.fold_left
            (fun acc ((_, lf) : Ident.t * Lambda.lfunction) ->
              max acc (List.length lf.params))
            0 members
        in
        List.iteri
          (fun i (id, _) ->
            let info = Hashtbl.find b.funs id in
            Hashtbl.replace b.funs id
              { info with
                global = gname;
                tag = Some (Int64.of_int (i + 1));
                group_arity;
                group_name = Some gname })
          members
      end)
    sccs;
  (* Code generation pass. *)
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

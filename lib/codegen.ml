(* Lambda -> QBE IL code generation for the supported subset.

   Value representation (design doc §4.2): the least-significant bit tags
   immediates — [val land 1 = 1] is an unboxed 63-bit integer (OCaml [int],
   bool, constant constructor), even words are pointers to ARC-managed heap
   objects. Only the integer half is generated in this phase.

   The builder is a tightly owned mutation kernel: emission order is the
   algorithm, so insts/labels accumulate in one local record and are exported
   as an immutable [Qbe_il.module_]. *)

open Qbe_il

exception Unsupported of string

(* ------------------------------------------------------------------ *)
(* Builder                                                             *)
(* ------------------------------------------------------------------ *)

type builder = {
  mutable temp_counter : int;
  mutable label_counter : int;
  mutable open_label : string;
  mutable insts : inst list;  (* reversed *)
  mutable term : term option; (* terminator of the open block, if closed *)
  mutable blocks : block list; (* reversed, closed blocks *)
  vars : (Ident.t, t) Hashtbl.t;
}

let builder () =
  {
    temp_counter = 0;
    label_counter = 0;
    open_label = "start";
    insts = [];
    term = None;
    blocks = [];
    vars = Hashtbl.create 16;
  }

let fresh_temp b name =
  let t = Printf.sprintf "%s.%d" name b.temp_counter in
  b.temp_counter <- b.temp_counter + 1;
  Temp t

let fresh_label b base =
  let l = Printf.sprintf "%s.%d" base b.label_counter in
  b.label_counter <- b.label_counter + 1;
  l

let emit b inst = b.insts <- inst :: b.insts

let close_block b term =
  match b.term with
  | Some _ -> invalid_arg "codegen: block already terminated"
  | None ->
      b.blocks <-
        { label = b.open_label; insts = List.rev b.insts; term } :: b.blocks;
      b.insts <- [];
      b.term <- Some term

let start_block b label =
  (match b.term with
  | None ->
      (* fallthrough is illegal in QBE; close with a jump *)
      close_block b (Jmp label)
  | Some _ -> ());
  b.open_label <- label;
  b.term <- None

let finish b =
  (match b.term with
  | None -> b.blocks <- []
  | Some _ -> ());
  List.rev b.blocks

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
  | Lconst _ -> "non-integer constant"
  | Lvar _ | Lmutvar _ -> "variable"
  | Lapply _ -> "function application"
  | Lfunction _ -> "function definition"
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

let rec expr b (lam : Lambda.lambda) : t =
  match lam with
  | Lconst (Const_int n) -> Int (tag_int n)
  | Lvar id -> Hashtbl.find b.vars id
  | Llet (_, _, id, arg, body) | Lmutlet (_, id, arg, body) ->
      let v = expr b arg in
      Hashtbl.replace b.vars id v;
      let result = expr b body in
      Hashtbl.remove b.vars id;
      result
  | Lsequence (a, b') ->
      ignore (expr b a);
      expr b b'
  | Levent (l, _) -> expr b l
  | Lifused (_, l) -> expr b l
  | Lprim (Pignore, [ arg ], _) ->
      ignore (expr b arg);
      unit_const
  (* Module initialization envelope: translmod ends the program with a
     setglobal of the module block; the unit value is an empty block. *)
  | Lprim (Psetglobal _, [ body ], _) -> expr b body
  | Lprim (Pmakeblock (0, _, _), [], _) -> unit_const
  | Lprim (Paddint, [ a; c ], _) -> arith_binop add_tagged a c b
  | Lprim (Psubint, [ a; c ], _) -> arith_binop sub_tagged a c b
  | Lprim (Pmulint, [ a; c ], _) -> mul_tagged b a c
  | Lprim (Pdivint _, [ a; c ], _) -> div_tagged b a c
  | Lprim (Pnegint, [ a ], _) ->
      let av = expr b a in
      let dst = fresh_temp b "neg" in
      emit b (Binop (Sub, Long, dst, Int 2L, av));
      dst
  | Lprim (Pintcomp cmp, [ a; c ], _) -> intcomp b cmp a c
  | Lapply { ap_func; ap_args = [ arg ]; _ } -> (
      (* Known Stdlib builtins lower to direct runtime calls; all other
         applications (closures, partial applications) wait for Phase 1
         closure conversion. *)
      match Builtins.resolve ap_func with
      | Some symbol -> expr_builtin b symbol arg
      | None -> raise (Unsupported (describe lam)))
  | Lifthenelse (cond, th, el) -> ifthenelse b cond th el
  | _ -> raise (Unsupported (describe lam))

(* [f dst a c] where [f] composes two tagged longs into [dst]. *)
and arith_binop f a c b =
  let av = expr b a in
  let cv = expr b c in
  let dst = fresh_temp b "arith" in
  f b av cv dst;
  dst

and mul_tagged b a c =
  let av = expr b a in
  let cv = expr b c in
  let ua = untag b av in
  let uc = untag b cv in
  let prod = fresh_temp b "mul" in
  emit b (Binop (Mul, Long, prod, ua, uc));
  retag b prod

and div_tagged b a c =
  let av = expr b a in
  let cv = expr b c in
  let ua = untag b av in
  let uc = untag b cv in
  let quot = fresh_temp b "div" in
  emit b (Binop (Div, Long, quot, ua, uc));
  retag b quot

and intcomp b cmp a c =
  let av = expr b a in
  let cv = expr b c in
  (* Tagged integers preserve signed order (2x+1 is monotone), so no untag. *)
  let dst = fresh_temp b "cmp" in
  emit b (Cmp (cmp_of_ocaml cmp, Long, dst, av, cv));
  dst

and expr_builtin b builtin arg =
  let av = expr b arg in
  let raw = untag b av in
  emit b (Call_void { fn = Global builtin; args = [ (Long, raw) ] });
  unit_const

and ifthenelse b cond th el =
  let cv = expr b cond in
  let lthen = fresh_label b "then" in
  let lelse = fresh_label b "else" in
  let ljoin = fresh_label b "join" in
  close_block b (Br (cv, lthen, lelse));
  let res = fresh_temp b "if" in
  start_block b lthen;
  let tv = expr b th in
  emit b (Copy (Long, res, tv));
  close_block b (Jmp ljoin);
  start_block b lelse;
  let ev = expr b el in
  emit b (Copy (Long, res, ev));
  close_block b (Jmp ljoin);
  start_block b ljoin;
  res

(* ------------------------------------------------------------------ *)
(* Program compilation                                                 *)
(* ------------------------------------------------------------------ *)

let compile_program (program : Lambda.program) : Qbe_il.module_ =
  let b = builder () in
  (* The module initializer is a void function: QBE only accepts [ret <val>]
     in functions declared with a return class, which we don't emit yet. *)
  ignore (expr b program.code);
  close_block b (Ret None);
  let blocks = finish b in
  { funcs =
      [ { name = "ocamlcc_module_init";
          export = true;
          params = [];
          blocks } ]
  }

let compile_program program =
  try Ok (compile_program program) with Unsupported what -> Error what

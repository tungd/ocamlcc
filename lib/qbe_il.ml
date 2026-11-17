(* QBE IL: data model and pretty-printer. *)

type ty =
  | Word
  | Long
  | Double

type t =
  | Temp of string
  | Global of string
  | Extern of string
  | Int of int64

module Binop = struct
  type t = Add | Sub | Mul | Div | Rem | And | Or | Xor | Shl | Shr | Sar

  let to_string = function
    | Add -> "add"
    | Sub -> "sub"
    | Mul -> "mul"
    | Div -> "div"
    | Rem -> "rem"
    | And -> "and"
    | Or -> "or"
    | Xor -> "xor"
    | Shl -> "shl"
    | Shr -> "shr"
    | Sar -> "sar"
end

module Cmp = struct
  type t = Eq | Ne | Slt | Sle | Sgt | Sge | Ult

  (* QBE comparison opcodes are spelled with a two-letter prefix (ceq, cne,
     cslt, ...) followed by the type letter. *)
  let prefix = function
    | Eq -> "ceq"
    | Ne -> "cne"
    | Slt -> "cslt"
    | Sle -> "csle"
    | Sgt -> "csgt"
    | Sge -> "csge"
    | Ult -> "cult"

  let to_string = function
    | Eq -> "eq"
    | Ne -> "ne"
    | Slt -> "slt"
    | Sle -> "sle"
    | Sgt -> "sgt"
    | Sge -> "sge"
    | Ult -> "ult"
end

module Fcmp = struct
  type t = Feq | Fne | Flt | Fle | Fgt | Fge | Fuo | Fo

  let opcode = function
    | Feq -> "ceqd"
    | Fne -> "cned"
    | Flt -> "cltd"
    | Fle -> "cled"
    | Fgt -> "cgtd"
    | Fge -> "cged"
    | Fuo -> "cuod"
    | Fo -> "cod"
end

let ty_char = function Word -> "w" | Long -> "l" | Double -> "d"

type load_op = Loadl | Loadw | Loaduh | Loadub | Loadsw | Loaduw | Loadd
type store_op = Storel | Storew | Storeh | Storeb | Stored

let string_of_load_op = function
  | Loadl -> "loadl"
  | Loadw -> "loadw"
  | Loaduh -> "loaduh"
  | Loadub -> "loadub"
  | Loadsw -> "loadsw"
  | Loaduw -> "loaduw"
  | Loadd -> "loadd"

let string_of_store_op = function
  | Storel -> "storel"
  | Storew -> "storew"
  | Storeh -> "storeh"
  | Storeb -> "storeb"
  | Stored -> "stored"

type call = { fn : t; args : (ty * t) list }

type inst =
  | Binop of Binop.t * ty * t * t * t
  | Neg of ty * t * t
  | Cmp of Cmp.t * ty * t * t * t
  | Fcmp of Fcmp.t * ty * t * t * t
  | Cast of ty * t * t
  | Extsw of t * t
  | Sltof of ty * t * t
  | Dtosi of ty * t * t
  | Phi of ty * t * (string * t) list
  | Copy of ty * t * t
  | Load of load_op * ty * t * t
  | Store of store_op * t * t
  | Alloc8 of t * t
  | Call of ty * t * call
  | Call_void of call

type term =
  | Ret of t option
  | Jmp of string
  | Br of t * string * string
  | Hlt

type block = { label : string; insts : inst list; term : term }

type func = {
  name : string;
  export : bool;
  retty : ty option;
  params : (ty * string) list;
  blocks : block list;
}

type data_item =
  | D_str of string
  | D_byte of int
  | D_half of int
  | D_word of int32
  | D_long of int64
  | D_ref of string * int64

type data = {
  name : string;
  export : bool;
  align : int option;
  items : data_item list;
}

type module_ = { funcs : func list; datas : data list }

let string_of_t ?(is_local = fun _ -> true) ?(pic = false) = function
  | Temp s -> "%" ^ s
  | Global s ->
      if pic && not (is_local s) then "extern $" ^ s else "$" ^ s
  | Extern s -> if pic then "extern $" ^ s else "$" ^ s
  | Int n -> Int64.to_string n

let string_of_ty = function
  | Word -> "w"
  | Long -> "l"
  | Double -> "d"

let string_of_args ~is_local ~pic args =
  args
  |> List.map (fun (ty, v) ->
         string_of_ty ty ^ " " ^ string_of_t ~is_local ~pic v)
  |> String.concat ", "

(* Binders (block/function parameters) are named, unlike call arguments. *)
let string_of_binders binders =
  binders
  |> List.map (fun (ty, n) -> string_of_ty ty ^ " %" ^ n)
  |> String.concat ", "

let string_of_inst ~is_local ~pic inst =
  let st = string_of_t ~is_local ~pic in
  match inst with
  | Binop (op, ty, dst, a, b) ->
      Printf.sprintf "%s =%s %s %s, %s" (st dst) (ty_char ty)
        (Binop.to_string op) (st a) (st b)
  | Neg (ty, dst, a) ->
      Printf.sprintf "%s =%s neg %s" (st dst) (ty_char ty) (st a)
  | Cmp (c, ty, dst, a, b) ->
      Printf.sprintf "%s =%s %s%s %s, %s" (st dst) (ty_char ty)
        (Cmp.prefix c) (ty_char ty) (st a) (st b)
  | Fcmp (c, ty, dst, a, b) ->
      Printf.sprintf "%s =%s %s %s, %s" (st dst) (ty_char ty)
        (Fcmp.opcode c) (st a) (st b)
  | Cast (ty, dst, a) ->
      Printf.sprintf "%s =%s cast %s" (st dst) (ty_char ty) (st a)
  | Extsw (dst, a) ->
      Printf.sprintf "%s =l extsw %s" (st dst) (st a)
  | Sltof (ty, dst, a) ->
      Printf.sprintf "%s =%s sltof %s" (st dst) (ty_char ty) (st a)
  | Dtosi (ty, dst, a) ->
      Printf.sprintf "%s =%s dtosi %s" (st dst) (ty_char ty) (st a)
  | Phi (ty, dst, args) ->
      Printf.sprintf "%s =%s phi %s" (st dst) (ty_char ty)
        (args
        |> List.map (fun (lbl, v) -> "@" ^ lbl ^ " " ^ st v)
        |> String.concat ", ")
  | Copy (ty, dst, src) ->
      Printf.sprintf "%s =%s copy %s" (st dst) (ty_char ty) (st src)
  | Load (op, ty, dst, addr) ->
      Printf.sprintf "%s =%s %s %s" (st dst) (ty_char ty)
        (string_of_load_op op) (st addr)
  | Store (op, v, addr) ->
      Printf.sprintf "%s %s, %s" (string_of_store_op op) (st v) (st addr)
  | Alloc8 (dst, sz) ->
      Printf.sprintf "%s =l alloc8 %s" (st dst) (st sz)
  | Call (ty, dst, { fn; args }) ->
      Printf.sprintf "%s =%s call %s(%s)" (st dst) (ty_char ty) (st fn)
        (string_of_args ~is_local ~pic args)
  | Call_void { fn; args } ->
      Printf.sprintf "call %s(%s)" (st fn) (string_of_args ~is_local ~pic args)

let string_of_term ~is_local ~pic term =
  let st = string_of_t ~is_local ~pic in
  match term with
  | Ret None -> "ret"
  | Ret (Some v) -> Printf.sprintf "ret %s" (st v)
  | Jmp l -> Printf.sprintf "jmp @%s" l
  | Br (c, t, f) -> Printf.sprintf "jnz %s, @%s, @%s" (st c) t f
  | Hlt -> "hlt"

let string_of_block ~is_local ~pic (b : block) =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "@%s\n" b.label);
  List.iter
    (fun inst -> Buffer.add_string buf (string_of_inst ~is_local ~pic inst ^ "\n"))
    b.insts;
  Buffer.add_string buf (string_of_term ~is_local ~pic b.term ^ "\n");
  Buffer.contents buf

let string_of_func ~is_local ~pic f =
  let params = string_of_binders f.params in
  let export = if f.export then "export " else "" in
  let retty =
    match f.retty with Some ty -> string_of_ty ty ^ " " | None -> ""
  in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf
    (Printf.sprintf "%sfunction %s$%s(%s) {\n" export retty f.name params);
  List.iter
    (fun b -> Buffer.add_string buf (string_of_block ~is_local ~pic b))
    f.blocks;
  Buffer.add_string buf "}\n\n";
  Buffer.contents buf

let string_of_data d =
  let buf = Buffer.create 128 in
  let export = if d.export then "export " else "" in
  let align =
    match d.align with
    | Some a -> Printf.sprintf "align %d " a
    | None -> ""
  in
  Buffer.add_string buf (Printf.sprintf "%sdata $%s = %s{ " export d.name align);
  let emit_item item =
    match item with
    | D_str s -> Printf.sprintf "b \"%s\"" s
    | D_byte n -> Printf.sprintf "b %d" n
    | D_half n -> Printf.sprintf "h %d" n
    | D_word n -> Printf.sprintf "w %ld" n
    | D_long n -> Printf.sprintf "l %Ld" n
    | D_ref (sym, off) ->
        if off = 0L then Printf.sprintf "l $%s" sym
        else Printf.sprintf "l $%s + %Ld" sym off
  in
  Buffer.add_string buf (String.concat ", " (List.map emit_item d.items));
  Buffer.add_string buf " }\n\n";
  Buffer.contents buf

let to_string ?(pic = true) m =
  let locals = Hashtbl.create 32 in
  List.iter
    (fun (d : data) -> if not d.export then Hashtbl.replace locals d.name ())
    m.datas;
  List.iter
    (fun (f : func) -> if not f.export then Hashtbl.replace locals f.name ())
    m.funcs;
  let is_local s = Hashtbl.mem locals s in
  String.concat ""
    (List.map string_of_data m.datas
    @ List.map (string_of_func ~is_local ~pic) m.funcs)

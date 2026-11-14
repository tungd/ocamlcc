(* QBE IL: data model and pretty-printer. *)

type ty =
  | Word
  | Long

type t =
  | Temp of string
  | Global of string
  | Int of int64

module Binop = struct
  type t = Add | Sub | Mul | Div | Rem | And | Or | Xor | Shl | Sar

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
    | Sar -> "sar"
end

module Cmp = struct
  type t = Eq | Ne | Slt | Sle | Sgt | Sge

  (* QBE comparison opcodes are spelled with a two-letter prefix (ceq, cne,
     cslt, ...) followed by the type letter. *)
  let prefix = function
    | Eq -> "ceq"
    | Ne -> "cne"
    | Slt -> "cslt"
    | Sle -> "csle"
    | Sgt -> "csgt"
    | Sge -> "csge"

  let to_string = function
    | Eq -> "eq"
    | Ne -> "ne"
    | Slt -> "slt"
    | Sle -> "sle"
    | Sgt -> "sgt"
    | Sge -> "sge"
end

let ty_char = function Word -> "w" | Long -> "l"

type call = { fn : t; args : (ty * t) list }

type inst =
  | Binop of Binop.t * ty * t * t * t
  | Cmp of Cmp.t * ty * t * t * t
  | Phi of ty * t * (string * t) list
  | Copy of ty * t * t
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

type data = { name : string; items : data_item list }

type module_ = { funcs : func list; datas : data list }

let string_of_t = function
  | Temp s -> "%" ^ s
  | Global s -> "$" ^ s
  | Int n -> Int64.to_string n

let string_of_ty = function
  | Word -> "w"
  | Long -> "l"

let string_of_args args =
  args
  |> List.map (fun (ty, v) -> string_of_ty ty ^ " " ^ string_of_t v)
  |> String.concat ", "

(* Binders (block/function parameters) are named, unlike call arguments. *)
let string_of_binders binders =
  binders
  |> List.map (fun (ty, n) -> string_of_ty ty ^ " %" ^ n)
  |> String.concat ", "

let string_of_inst inst =
  match inst with
  | Binop (op, ty, dst, a, b) ->
      Printf.sprintf "%s =%s %s %s, %s" (string_of_t dst) (ty_char ty)
        (Binop.to_string op) (string_of_t a) (string_of_t b)
  | Cmp (c, ty, dst, a, b) ->
      Printf.sprintf "%s =%s %s%s %s, %s" (string_of_t dst) (ty_char ty)
        (Cmp.prefix c) (ty_char ty) (string_of_t a) (string_of_t b)
  | Phi (ty, dst, args) ->
      Printf.sprintf "%s =%s phi %s" (string_of_t dst) (ty_char ty)
        (args
        |> List.map (fun (lbl, v) -> "@" ^ lbl ^ " " ^ string_of_t v)
        |> String.concat ", ")
  | Copy (ty, dst, src) ->
      Printf.sprintf "%s =%s copy %s" (string_of_t dst) (ty_char ty)
        (string_of_t src)
  | Call (ty, dst, { fn; args }) ->
      Printf.sprintf "%s =%s call %s(%s)" (string_of_t dst) (ty_char ty)
        (string_of_t fn) (string_of_args args)
  | Call_void { fn; args } ->
      Printf.sprintf "call %s(%s)" (string_of_t fn) (string_of_args args)

let string_of_term term =
  match term with
  | Ret None -> "ret"
  | Ret (Some v) -> Printf.sprintf "ret %s" (string_of_t v)
  | Jmp l -> Printf.sprintf "jmp @%s" l
  | Br (c, t, f) ->
      Printf.sprintf "jnz %s, @%s, @%s" (string_of_t c) t f
  | Hlt -> "hlt"

let string_of_block (b : block) =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "@%s\n" b.label);
  List.iter
    (fun inst -> Buffer.add_string buf (string_of_inst inst ^ "\n"))
    b.insts;
  Buffer.add_string buf (string_of_term b.term ^ "\n");
  Buffer.contents buf

let string_of_func f =
  let params = string_of_binders f.params in
  let export = if f.export then "export " else "" in
  let retty =
    match f.retty with Some ty -> string_of_ty ty ^ " " | None -> ""
  in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf
    (Printf.sprintf "%sfunction %s$%s(%s) {\n" export retty f.name params);
  List.iter (fun b -> Buffer.add_string buf (string_of_block b)) f.blocks;
  Buffer.add_string buf "}\n\n";
  Buffer.contents buf

let string_of_data d =
  let buf = Buffer.create 128 in
  Buffer.add_string buf (Printf.sprintf "data $%s = { " d.name);
  let emit_item item =
    match item with
    | D_str s -> Buffer.add_string buf (Printf.sprintf "b \"%s\", " s)
    | D_byte n -> Buffer.add_string buf (Printf.sprintf "b %d, " n)
  in
  List.iter emit_item d.items;
  Buffer.add_string buf "b 0 }\n\n";
  Buffer.contents buf

let to_string m =
  String.concat ""
    (List.map string_of_data m.datas @ List.map string_of_func m.funcs)

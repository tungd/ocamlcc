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
  | Copy of ty * t * t
  | Call of ty * t * call
  | Call_void of call

type term =
  | Ret of t option
  | Jmp of string
  | Br of t * string * string

type block = { label : string; insts : inst list; term : term }

type func = { name : string; export : bool; params : (ty * string) list; blocks : block list }

type module_ = { funcs : func list }

(* One line per instruction; nothing needs layout beyond that. *)
let string_of_t = function
  | Temp s -> "%" ^ s
  | Global s -> "$" ^ s
  | Int n -> Int64.to_string n

let string_of_ty = function
  | Word -> "w"
  | Long -> "l"

let string_of_inst inst =
  match inst with
  | Binop (op, ty, dst, a, b) ->
      Printf.sprintf "%s =%s %s %s, %s" (string_of_t dst) (ty_char ty)
        (Binop.to_string op) (string_of_t a) (string_of_t b)
  | Cmp (c, ty, dst, a, b) ->
      Printf.sprintf "%s =%s %s%s %s, %s" (string_of_t dst) (ty_char ty)
        (Cmp.prefix c) (ty_char ty) (string_of_t a) (string_of_t b)
  | Copy (ty, dst, src) ->
      Printf.sprintf "%s =%s copy %s" (string_of_t dst) (ty_char ty)
        (string_of_t src)
  | Call (ty, dst, { fn; args }) ->
      Printf.sprintf "%s =%s call %s(%s)" (string_of_t dst) (ty_char ty)
        (string_of_t fn)
        (args
        |> List.map (fun (ty, v) -> string_of_ty ty ^ " " ^ string_of_t v)
        |> String.concat ", ")
  | Call_void { fn; args } ->
      Printf.sprintf "call %s(%s)" (string_of_t fn)
        (args
        |> List.map (fun (ty, v) -> string_of_ty ty ^ " " ^ string_of_t v)
        |> String.concat ", ")

let string_of_term term =
  match term with
  | Ret None -> "ret"
  | Ret (Some v) -> Printf.sprintf "ret %s" (string_of_t v)
  | Jmp l -> Printf.sprintf "jmp @%s" l
  | Br (c, t, f) ->
      Printf.sprintf "jnz %s, @%s, @%s" (string_of_t c) t f

let string_of_block b =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "@%s\n" b.label);
  List.iter (fun inst -> Buffer.add_string buf (string_of_inst inst ^ "\n")) b.insts;
  Buffer.add_string buf (string_of_term b.term ^ "\n");
  Buffer.contents buf

let string_of_func f =
  let params =
    f.params
    |> List.map (fun (ty, name) -> string_of_ty ty ^ " %" ^ name)
    |> String.concat ", "
  in
  let export = if f.export then "export " else "" in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Printf.sprintf "%sfunction $%s(%s) {\n" export f.name params);
  List.iter (fun b -> Buffer.add_string buf (string_of_block b)) f.blocks;
  Buffer.add_string buf "}\n\n";
  Buffer.contents buf

let to_string m = List.map string_of_func m.funcs |> String.concat ""

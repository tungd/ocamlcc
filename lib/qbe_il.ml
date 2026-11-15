(* QBE IL: data model and pretty-printer. *)

type ty =
  | Word
  | Long

type t =
  | Temp of string
  | Global of string
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

let ty_char = function Word -> "w" | Long -> "l"

type load_op = Loadl | Loaduh | Loadub | Loadsw | Loaduw
type store_op = Storel | Storew | Storeh | Storeb

let string_of_load_op = function
  | Loadl -> "loadl"
  | Loaduh -> "loaduh"
  | Loadub -> "loadub"
  | Loadsw -> "loadsw"
  | Loaduw -> "loaduw"

let string_of_store_op = function
  | Storel -> "storel"
  | Storew -> "storew"
  | Storeh -> "storeh"
  | Storeb -> "storeb"

type call = { fn : t; args : (ty * t) list }

type inst =
  | Binop of Binop.t * ty * t * t * t
  | Cmp of Cmp.t * ty * t * t * t
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
  | Load (op, ty, dst, addr) ->
      Printf.sprintf "%s =%s %s %s" (string_of_t dst) (ty_char ty)
        (string_of_load_op op) (string_of_t addr)
  | Store (op, v, addr) ->
      Printf.sprintf "%s %s, %s" (string_of_store_op op) (string_of_t v)
        (string_of_t addr)
  | Alloc8 (dst, sz) ->
      Printf.sprintf "%s =l alloc8 %s" (string_of_t dst) (string_of_t sz)
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

let to_string m =
  String.concat ""
    (List.map string_of_data m.datas @ List.map string_of_func m.funcs)

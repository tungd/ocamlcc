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
  | Dbgloc of int * int

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

let string_of_t ~is_local ~pic ~name = function
  | Temp s -> "%" ^ s
  | Global s ->
      if pic && not (is_local s) then "extern $" ^ name s else "$" ^ name s
  | Extern s -> if pic then "extern $" ^ name s else "$" ^ name s
  | Int n -> Int64.to_string n

let string_of_ty = function
  | Word -> "w"
  | Long -> "l"
  | Double -> "d"

let string_of_args st args =
  args
  |> List.map (fun (ty, v) ->
         string_of_ty ty ^ " " ^ st v)
  |> String.concat ", "

(* Binders (block/function parameters) are named, unlike call arguments. *)
let string_of_binders binders =
  binders
  |> List.map (fun (ty, n) -> string_of_ty ty ^ " %" ^ n)
  |> String.concat ", "

let string_of_inst st inst =
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
        (string_of_args st args)
  | Call_void { fn; args } ->
      Printf.sprintf "call %s(%s)" (st fn) (string_of_args st args)
  | Dbgloc (line, col) ->
      if col > 0 then Printf.sprintf "dbgloc %d, %d" line col
      else Printf.sprintf "dbgloc %d" line

let string_of_term st term =
  match term with
  | Ret None -> "ret"
  | Ret (Some v) -> Printf.sprintf "ret %s" (st v)
  | Jmp l -> Printf.sprintf "jmp @%s" l
  | Br (c, t, f) -> Printf.sprintf "jnz %s, @%s, @%s" (st c) t f
  | Hlt -> "hlt"

let string_of_block st (b : block) =
  let buf = Buffer.create 256 in
  Buffer.add_string buf (Printf.sprintf "@%s\n" b.label);
  List.iter
    (fun inst -> Buffer.add_string buf (string_of_inst st inst ^ "\n"))
    b.insts;
  Buffer.add_string buf (string_of_term st b.term ^ "\n");
  Buffer.contents buf

let string_of_func ~name st f =
  let params = string_of_binders f.params in
  let export = if f.export then "export " else "" in
  let retty =
    match f.retty with Some ty -> string_of_ty ty ^ " " | None -> ""
  in
  let buf = Buffer.create 1024 in
  Buffer.add_string buf
    (Printf.sprintf "%sfunction %s$%s(%s) {\n" export retty (name f.name) params);
  List.iter
    (fun b -> Buffer.add_string buf (string_of_block st b))
    f.blocks;
  Buffer.add_string buf "}\n\n";
  Buffer.contents buf

let string_of_data ~name d =
  let buf = Buffer.create 128 in
  let export = if d.export then "export " else "" in
  let align =
    match d.align with
    | Some a -> Printf.sprintf "align %d " a
    | None -> ""
  in
  Buffer.add_string buf (Printf.sprintf "%sdata $%s = %s{ " export (name d.name) align);
  let emit_item item =
    match item with
    | D_str s -> Printf.sprintf "b \"%s\"" s
    | D_byte n -> Printf.sprintf "b %d" n
    | D_half n -> Printf.sprintf "h %d" n
    | D_word n -> Printf.sprintf "w %ld" n
    | D_long n -> Printf.sprintf "l %Ld" n
    | D_ref (sym, off) ->
        if off = 0L then Printf.sprintf "l $%s" (name sym)
        else Printf.sprintf "l $%s + %Ld" (name sym) off
  in
  Buffer.add_string buf (String.concat ", " (List.map emit_item d.items));
  Buffer.add_string buf " }\n\n";
  Buffer.contents buf

let to_string ?(pic = true) ?dbgfile ?(name = Fun.id) m =
  let locals = Hashtbl.create 32 in
  List.iter
    (fun (d : data) -> if not d.export then Hashtbl.replace locals d.name ())
    m.datas;
  List.iter
    (fun (f : func) -> if not f.export then Hashtbl.replace locals f.name ())
    m.funcs;
  let is_local s = Hashtbl.mem locals s in
  let st = string_of_t ~is_local ~pic ~name in
  let header =
    match dbgfile with
    | Some path -> [Printf.sprintf "dbgfile \"%s\"\n\n" (String.escaped path)]
    | None -> []
  in
  String.concat ""
    (header
    @ List.map (string_of_data ~name) m.datas
    @ List.map (string_of_func ~name st) m.funcs)

module Names = struct
  type t = { temp_counter : int; label_counter : int }
end

(* QBE's parser caps phi incoming edges at NPred = 63 (vendor/qbe/parse.c).
   Split any block with wide phis into a balanced tree of trampoline blocks
   of at most [max_phi_preds] predecessors each so arbitrary-width OCaml
   switches compile cleanly under unmodified upstream QBE. *)
let max_phi_preds = 50

let block_has_wide_phi (blk : block) =
  List.exists
    (function
      | Phi (_, _, args) -> List.length args > max_phi_preds
      | _ -> false)
    blk.insts

let chunk_list k xs =
  let rec go cur cur_n acc = function
    | [] ->
        let acc = if cur = [] then acc else List.rev cur :: acc in
        List.rev acc
    | x :: rest ->
        if cur_n = k then go [ x ] 1 (List.rev cur :: acc) rest
        else go (x :: cur) (cur_n + 1) acc rest
  in
  go [] 0 [] xs

let rec split_wide_phis ~fresh_label ~fresh_temp (blocks : block list) : block list =
  match List.find_opt block_has_wide_phi blocks with
  | None -> blocks
  | Some (target : block) ->
      let target_lbl = target.label in
      let phis, non_phis =
        List.partition (function Phi _ -> true | _ -> false) target.insts
      in
      let seen = Hashtbl.create 64 in
      let pred_order = ref [] in
      List.iter
        (function
          | Phi (_, _, args) ->
              List.iter
                (fun (lbl, _) ->
                  if not (Hashtbl.mem seen lbl) then begin
                    Hashtbl.replace seen lbl ();
                    pred_order := lbl :: !pred_order
                  end)
                args
          | _ -> ())
        phis;
      let chunks = chunk_list max_phi_preds (List.rev !pred_order) in
      let pred_to_split = Hashtbl.create 64 in
      let split_specs =
        List.map
          (fun chunk ->
            let slbl = fresh_label "phisplit" in
            let member = Hashtbl.create (List.length chunk) in
            List.iter
              (fun plbl ->
                Hashtbl.replace pred_to_split plbl slbl;
                Hashtbl.replace member plbl ())
              chunk;
            (slbl, member))
          chunks
      in
      let new_phi_args = Array.make (List.length phis) [] in
      let split_blocks =
        List.map
          (fun (slbl, member) ->
            let insts = ref [] in
            List.iteri
              (fun idx inst ->
                match inst with
                | Phi (ty, _, args) -> (
                    let sub_args =
                      List.filter (fun (lbl, _) -> Hashtbl.mem member lbl) args
                    in
                    match sub_args with
                    | [] -> ()
                    | [ (_, v) ] ->
                        let tmp = fresh_temp "phisp" in
                        insts := Copy (ty, tmp, v) :: !insts;
                        new_phi_args.(idx) <- (slbl, tmp) :: new_phi_args.(idx)
                    | _ ->
                        let tmp = fresh_temp "phisp" in
                        insts := Phi (ty, tmp, sub_args) :: !insts;
                        new_phi_args.(idx) <- (slbl, tmp) :: new_phi_args.(idx))
                | _ -> ())
              phis;
            { label = slbl; insts = List.rev !insts; term = Jmp target_lbl })
          split_specs
      in
      let reduced_phis =
        List.mapi
          (fun idx inst ->
            match inst with
            | Phi (ty, dst, _) -> Phi (ty, dst, List.rev new_phi_args.(idx))
            | other -> other)
          phis
      in
      let rewrite_edge from_lbl dst_lbl =
        if String.equal dst_lbl target_lbl then
          match Hashtbl.find_opt pred_to_split from_lbl with
          | Some slbl -> slbl
          | None -> dst_lbl
        else dst_lbl
      in
      let rewrite_term from_lbl = function
        | Jmp l -> Jmp (rewrite_edge from_lbl l)
        | Br (c, t, f) ->
            Br (c, rewrite_edge from_lbl t, rewrite_edge from_lbl f)
        | (Ret _ | Hlt) as term -> term
      in
      let blocks' =
        List.concat_map
          (fun blk ->
            let term = rewrite_term blk.label blk.term in
            if String.equal blk.label target_lbl then
              split_blocks
              @ [ { blk with insts = reduced_phis @ non_phis; term } ]
            else [ { blk with term } ])
          blocks
      in
      split_wide_phis ~fresh_label ~fresh_temp blocks'

let temp_used_once blocks =
  let counts = Hashtbl.create 32 in
  let use = function
    | Temp id ->
        let n = Option.value ~default:0 (Hashtbl.find_opt counts id) in
        Hashtbl.replace counts id (n + 1)
    | Int _ | Global _ | Extern _ -> ()
  in
  let use_inst = function
    | Binop (_, _, _, a, b) | Cmp (_, _, _, a, b)
    | Fcmp (_, _, _, a, b) | Store (_, a, b) -> use a; use b
    | Neg (_, _, a) | Cast (_, _, a) | Extsw (_, a) | Sltof (_, _, a)
    | Dtosi (_, _, a) | Copy (_, _, a) | Load (_, _, _, a)
    | Alloc8 (_, a) -> use a
    | Phi (_, _, edges) -> List.iter (fun (_, arg) -> use arg) edges
    | Call (_, _, call) | Call_void call ->
        use call.fn;
        List.iter (fun (_, arg) -> use arg) call.args
    | Dbgloc _ -> ()
  in
  List.iter (fun (block : block) ->
    List.iter use_inst block.insts;
    match block.term with
    | Br (cond, _, _) -> use cond
    | Ret value -> Option.iter use value
    | Hlt | Jmp _ -> ()) blocks;
  fun id -> Hashtbl.find_opt counts id = Some 1

(* Branch directly from the arms of a short circuit when the joined value
   is used only as a test. Visit the outer joins first so the new tests
   can also be pushed into inner joins. *)
let shortcut_boolean_joins ~fresh_temp blocks =
  let by_label = Hashtbl.create 32 in
  let incoming = Hashtbl.create 32 in
  let phi_sources = Hashtbl.create 32 in
  let count map label = Option.value ~default:0 (Hashtbl.find_opt map label) in
  let change map label n = Hashtbl.replace map label (count map label + n) in
  let edges n = function
    | Jmp label -> change incoming label n
    | Br (_, yes, no) -> change incoming yes n; change incoming no n
    | Ret _ | Hlt -> ()
  in
  List.iter (fun (block : block) ->
    Hashtbl.add by_label block.label block;
    edges 1 block.term;
    List.iter (function
      | Phi (_, _, args) -> List.iter (fun (label, _) -> change phi_sources label 1) args
      | _ -> ()) block.insts) blocks;
  let used_once = lazy (temp_used_once blocks) in
  List.iter (fun (original : block) ->
    let block = Hashtbl.find by_label original.label in
    match block.insts, block.term with
    | [Phi (Long, Temp value, (_ :: _ as args));
       Cmp (Ne, Long, Temp test, Temp tested, Int 1L)],
      Br (Temp condition, yes, no)
      when tested = value && test = condition
        && count phi_sources block.label = 0
        && List.length args = count incoming block.label
        && Lazy.force used_once value
        (* Newly introduced tests are local to their terminator. *)
        && (block != original || Lazy.force used_once test)
        && List.for_all (fun (label, _) ->
          (Hashtbl.find by_label label).term = Jmp block.label) args ->
        edges (-1) block.term;
        List.iter (fun (label, arg) ->
          let pred = Hashtbl.find by_label label in
          let pred = match arg with
            | Int n -> { pred with term = Jmp (if n = 1L then no else yes) }
            | _ ->
                let test = fresh_temp "cond" in
                { pred with insts = pred.insts @ [Cmp (Ne, Long, test, arg, Int 1L)];
                            term = Br (test, yes, no) }
          in
          change phi_sources label (-1);
          edges 1 pred.term;
          Hashtbl.replace by_label label pred) args;
        Hashtbl.remove by_label block.label
    | _ -> ()) (List.rev blocks);
  List.filter_map (fun (block : block) -> Hashtbl.find_opt by_label block.label) blocks

(* Lower a comparison followed by retagging and an immediate branch directly
   to a branch on its 0/1 result. A phi, return, or any other use in a
   successor can still require the tagged value. *)
let fuse_tagged_branches blocks =
  let booleans = Hashtbl.create 32 in
  let rec record = function
    | Cmp (_, _, result, _, _)
      :: Binop (Shl, Long, shifted, raw, Int 1L)
      :: Binop (Add, Long, Temp tag, shift, Int 1L) :: rest
      when raw = result && shift = shifted ->
        Hashtbl.replace booleans tag (raw, shifted);
        record rest
    | _ :: rest -> record rest
    | [] -> ()
  in
  List.iter (fun (block : block) -> record block.insts) blocks;
  let uses = lazy (temp_used_once blocks) in
  let used_once = function
    | Temp id -> Lazy.force uses id
    | _ -> false
  in
  let dead = Hashtbl.create 16 in
  let rewrite (block : block) =
    match block.term with
    | Br (cond, yes, no) ->
        (match List.rev block.insts with
        | Cmp (Ne, Long, test, (Temp tag as tagged), Int 1L) :: earlier
          when test = cond ->
            (match Hashtbl.find_opt booleans tag with
            | Some (raw, (Temp shift as shifted)) when used_once test ->
                if used_once tagged && used_once shifted then begin
                  Hashtbl.replace dead tag ();
                  Hashtbl.replace dead shift ()
                end;
                { block with insts = List.rev earlier; term = Br (raw, yes, no) }
            | _ -> block)
        | _ -> block)
    | _ -> block
  in
  if Hashtbl.length booleans = 0 then blocks
  else
    let blocks = List.map rewrite blocks in
    let live_inst = function
      | Binop (_, _, Temp dst, _, _) -> not (Hashtbl.mem dead dst)
      | _ -> true
    in
    List.map (fun (block : block) ->
      { block with insts = List.filter live_inst block.insts }) blocks

let optimize_blocks ?(optimize = true) (names : Names.t) blocks =
  let temps = ref names.temp_counter and labels = ref names.label_counter in
  let fresh counter base =
    let name = Printf.sprintf "%s.%d" base !counter in
    incr counter;
    name
  in
  let fresh_label = fresh labels in
  let fresh_temp base = Temp (fresh temps base) in
  let blocks =
    if optimize then
      blocks |> shortcut_boolean_joins ~fresh_temp |> fuse_tagged_branches
      |> split_wide_phis ~fresh_label ~fresh_temp
    else
      split_wide_phis ~fresh_label ~fresh_temp blocks
  in
  blocks, { Names.temp_counter = !temps; label_counter = !labels }

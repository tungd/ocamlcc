open Lambda

let node_limit = 24
let hinted_branch_limit = 50
let byte_limit = 2048

exception Unsupported

(* This wire vocabulary contains only closed local expressions. The caller
   lowers the reconstructed Lambda through its ordinary ownership and bounds
   passes. The format carries no identifiers, globals or arbitrary calls. *)
let primitives =
  [ "neg", (Pnegint, 1); "add", (Paddint, 2); "sub", (Psubint, 2);
    "mul", (Pmulint, 2); "and", (Pandint, 2); "or", (Porint, 2);
    "xor", (Pxorint, 2); "shl", (Plslint, 2); "shr", (Plsrint, 2);
    "sar", (Pasrint, 2); "eq", (Pintcomp Ceq, 2); "ne", (Pintcomp Cne, 2);
    "lt", (Pintcomp Clt, 2); "le", (Pintcomp Cle, 2);
    "gt", (Pintcomp Cgt, 2); "ge", (Pintcomp Cge, 2);
    "both", (Psequand, 2); "either", (Psequor, 2); "not", (Pnot, 1);
    "isint", (Pisint, 1); "str-length", (Pstringlength, 1);
    "bytes-length", (Pbyteslength, 1);
    "int-length", (Parraylength Pintarray, 1);
    "int-get", (Parrayrefs Pintarray, 2);
    "int-get-unsafe", (Parrayrefu Pintarray, 2);
    "ptr-get", (Parrayrefs Paddrarray, 2);
    "ptr-get-unsafe", (Parrayrefu Paddrarray, 2);
    "int-set", (Parraysets Pintarray, 3);
    "int-set-unsafe", (Parraysetu Pintarray, 3) ]

let value_kind = function Pintval -> "i" | Pgenval -> "v" | _ -> raise Unsupported
let parse_kind = function "i" -> Pintval | "v" -> Pgenval | _ -> raise Unsupported
let let_kind = function Strict -> "strict" | Alias -> "alias" | StrictOpt -> "opt"
let parse_let = function
  | "strict" -> Strict | "alias" -> Alias | "opt" -> StrictOpt | _ -> raise Unsupported

let encode (def : lfunction) =
  if def.kind <> Curried || def.attr.inline = Never_inline || def.attr.is_a_functor
     || List.compare_length_with def.params node_limit > 0 then None
  else
    let limit = match def.attr.inline with
      | Always_inline | Hint_inline -> hinted_branch_limit
      | _ -> node_limit in
    let budget = ref limit in
    let contains_branch = ref false in
    let tokens = ref [] in
    let token name = tokens := name :: !tokens in
    let number n = token (string_of_int n) in
    let rec index id offset = function
      | binder :: _ when Ident.same id binder -> offset
      | _ :: rest -> index id (offset + 1) rest
      | [] -> raise Unsupported
    in
    let rec term env expr =
      decr budget;
      if !budget < 0 then raise Unsupported;
      match expr with
      | Lvar id -> token "var"; number (index id 0 env)
      | Lconst (Const_int n) -> token "int"; number n
      | Lconst (Const_char c) -> token "char"; number (Char.code c)
      | Llet (mode, kind, id, rhs, body) ->
          token "let"; token (let_kind mode); token (value_kind kind);
          term env rhs; term (id :: env) body
      | Lifthenelse (cond, yes, no) ->
          contains_branch := true;
          token "if"; term env cond; term env yes; term env no
      | Lsequence (first, next) -> token "seq"; term env first; term env next
      | Lprim (Pfield (i, kind, mutability), [owner], _) ->
          token "field"; number i;
          token (match kind with Immediate -> "i" | Pointer -> "p");
          token (match mutability with Immutable -> "fixed" | Mutable -> "mut");
          term env owner
      | Lprim (Psetfield (i, Immediate, Assignment), [owner; value], _) ->
          token "set-field"; number i; term env owner; term env value
      | Lprim (Poffsetint n, [value], _) ->
          token "offset"; number n; term env value
      | Lprim (operation, args, _) ->
          (match List.find_opt (fun (_, (p, _)) -> p = operation) primitives with
          | Some (name, (_, arity)) when List.compare_length_with args arity = 0 ->
              token name; List.iter (term env) args
          | _ -> raise Unsupported)
      | _ -> raise Unsupported
    in
    try
      token (value_kind def.return);
      List.iter (fun (_, kind) -> token (value_kind kind)) def.params;
      term (List.map fst def.params) def.body;
      let payload = String.concat "," (List.rev !tokens) in
      if String.length payload <= byte_limit &&
         (!contains_branch || limit - !budget <= node_limit)
      then Some payload else None
    with Unsupported -> None

let decode ~arity payload =
  if arity <= 0 || arity > node_limit || String.length payload > byte_limit then None
  else
    let tokens = ref (String.split_on_char ',' payload) in
    let budget = ref hinted_branch_limit in
    let contains_branch = ref false in
    let loc = Debuginfo.Scoped_location.Loc_unknown in
    let token () =
      match !tokens with
      | first :: rest -> tokens := rest; first
      | [] -> raise Unsupported
    in
    let number () =
      match int_of_string_opt (token ()) with Some n -> n | None -> raise Unsupported
    in
    let nonnegative () =
      let n = number () in
      if n < 0 || n > max_int / 8 then raise Unsupported;
      n
    in
    let rec term env =
      decr budget;
      if !budget < 0 then raise Unsupported;
      match token () with
      | "var" ->
          (match List.nth_opt env (nonnegative ()) with
           | Some id -> Lvar id
           | None -> raise Unsupported)
      | "int" -> Lconst (Const_int (number ()))
      | "char" -> Lconst (Const_char (Char.chr (number ())))
      | "let" ->
          let mode = parse_let (token ()) in
          let kind = parse_kind (token ()) in
          let id = Ident.create_local "leaf" in
          let rhs = term env in
          let body = term (id :: env) in
          Llet (mode, kind, id, rhs, body)
      | "if" ->
          contains_branch := true;
          let condition = term env in
          let yes = term env in
          let no = term env in
          Lifthenelse (condition, yes, no)
      | "seq" ->
          let first = term env in
          let next = term env in
          Lsequence (first, next)
      | "field" ->
          let i = nonnegative () in
          let kind = match token () with
            | "i" -> Immediate | "p" -> Pointer | _ -> raise Unsupported in
          let mutability : Asttypes.mutable_flag = match token () with
            | "fixed" -> Immutable | "mut" -> Mutable | _ -> raise Unsupported in
          Lprim (Pfield (i, kind, mutability), [term env], loc)
      | "set-field" ->
          let i = nonnegative () in
          let owner = term env in
          let value = term env in
          Lprim (Psetfield (i, Immediate, Assignment), [owner; value], loc)
      | "offset" ->
          let n = number () in
          Lprim (Poffsetint n, [term env], loc)
      | name ->
          (match List.assoc_opt name primitives with
          | Some (operation, count) ->
              let args = List.init count (fun _ -> term env) in
              Lprim (operation, args, loc)
          | None -> raise Unsupported)
    in
    try
      let return = parse_kind (token ()) in
      let params = List.init arity (fun _ -> Ident.create_local "arg", parse_kind (token ())) in
      let body = term (List.map fst params) in
      if !tokens <> [] ||
         (not !contains_branch && hinted_branch_limit - !budget > node_limit)
      then raise Unsupported;
      Some (lfunction' ~kind:Curried ~params ~return ~body ~attr:default_function_attribute ~loc)
    with Unsupported | Invalid_argument _ -> None

open Lambda

type path = Local of Ident.t | Field of path * int
type kind = Array | Bytes

type value =
  | Path of path
  | Integer of int
  | Length of kind * path

type fact = Nonnegative of path | Below of path * kind * path

type binding = {
  value : value option;
  on_true : fact list;
  on_false : fact list;
}

let rec value bindings = function
  | Lvar id ->
      (match Ident.Map.find_opt id bindings with
       | Some { value = Some v; _ } -> Some v
       | _ -> Some (Path (Local id)))
  | Lconst (Const_int n) -> Some (Integer n)
  | Lprim (Pfield (index, Pointer, Immutable), [owner], _) ->
      (match value bindings owner with
       | Some (Path path) -> Some (Path (Field (path, index)))
       | _ -> None)
  | Lprim ((Parraylength _ | Pstringlength | Pbyteslength as op), [arg], _) ->
      let kind = match op with Parraylength _ -> Array | _ -> Bytes in
      (match value bindings arg with
       | Some (Path path) -> Some (Length (kind, path))
       | _ -> None)
  | _ -> None

let intersection a b = List.filter (fun fact -> List.mem fact b) a

let less_than strict lhs rhs = match lhs, rhs with
  | Some (Integer n), Some (Path path) when n >= (if strict then -1 else 0) ->
      [Nonnegative path]
  | Some (Path index), Some (Length (kind, receiver)) when strict ->
      [Below (index, kind, receiver)]
  | _ -> []

let comparison bindings cmp lhs rhs =
  let lhs = value bindings lhs and rhs = value bindings rhs in
  let less = less_than true and le = less_than false in
  match cmp with
  | Clt -> less lhs rhs, le rhs lhs
  | Cle -> le lhs rhs, less rhs lhs
  | Cgt -> less rhs lhs, le lhs rhs
  | Cge -> le rhs lhs, less lhs rhs
  | Ceq -> le lhs rhs @ le rhs lhs, []
  | Cne -> [], le lhs rhs @ le rhs lhs

let rec edges bindings = function
  | Lvar id ->
      (match Ident.Map.find_opt id bindings with
       | Some { on_true; on_false; _ } -> on_true, on_false
       | None -> [], [])
  | Lprim (Pintcomp cmp, [lhs; rhs], _) -> comparison bindings cmp lhs rhs
  | Lprim (Pnot, [cond], _) ->
      let yes, no = edges bindings cond in no, yes
  | Lprim (Psequand, [lhs; rhs], _) ->
      let ly, ln = edges bindings lhs and ry, rn = edges bindings rhs in
      ly @ ry, intersection ln (ly @ rn)
  | Lprim (Psequor, [lhs; rhs], _) ->
      let ly, ln = edges bindings lhs and ry, rn = edges bindings rhs in
      intersection ly (ln @ ry), ln @ rn
  | _ -> [], []

let proves_index bindings facts kind receiver index =
  match value bindings receiver, value bindings index with
  | Some (Path receiver), Some (Path index) ->
      List.mem (Nonnegative index) facts && List.mem (Below (index, kind, receiver)) facts
  | _ -> false

let remove_redundant_checks code =
  let rec visit bindings facts = function
    | Llet (mode, kind, id, rhs, body) ->
        let on_true, on_false = edges bindings rhs in
        let binding = { value = value bindings rhs; on_true; on_false } in
        Llet (mode, kind, id, visit bindings facts rhs,
              visit (Ident.Map.add id binding bindings) facts body)
    | Lifthenelse (cond, yes, no) ->
        let on_true, on_false = edges bindings cond in
        Lifthenelse (visit bindings facts cond,
                     visit bindings (on_true @ facts) yes,
                     visit bindings (on_false @ facts) no)
    | Lprim ((Psequand | Psequor as op), [lhs; rhs], loc) ->
        let on_true, on_false = edges bindings lhs in
        let next = match op with Psequand -> on_true | _ -> on_false in
        Lprim (op, [visit bindings facts lhs; visit bindings (next @ facts) rhs], loc)
    | Lprim (op, (receiver :: index :: _ as args), loc) ->
        let op =
          match op with
          | Parrayrefs rep when proves_index bindings facts Array receiver index -> Parrayrefu rep
          | Parraysets rep when proves_index bindings facts Array receiver index -> Parraysetu rep
          | Pstringrefs when proves_index bindings facts Bytes receiver index -> Pstringrefu
          | Pbytesrefs when proves_index bindings facts Bytes receiver index -> Pbytesrefu
          | Pbytessets when proves_index bindings facts Bytes receiver index -> Pbytessetu
          | _ -> op
        in
        Lprim (op, List.map (visit bindings facts) args, loc)
    | Lfunction lf -> Lfunction (map_lfunction (visit Ident.Map.empty []) lf)
    | Lletrec (defs, body) ->
        let defs = List.map (fun rb ->
          { rb with def = map_lfunction (visit Ident.Map.empty []) rb.def }) defs in
        Lletrec (defs, visit bindings facts body)
    | expr -> Lambda.shallow_map (visit bindings facts) expr
  in
  visit Ident.Map.empty [] code

(* Builtins: resolves Lambda expressions denoting known Stdlib entry points
   to ocamlcc runtime symbols.

   In Lambda, Stdlib entry points surface as field loads from the Stdlib
   module block, e.g. [(field_imm 43 (global Stdlib!))]. Instead of compiling
   probe snippets against the host switch's Stdlib, we locate the active
   [stdlib.cmi] along [include_dirs] (falling back to
   [Config.standard_library]) and compute each entry point's runtime block
   slot directly from [Cmi_format.read_cmi]. *)

type arg_kind =
  | Int_arg    (* tagged 63-bit integer; codegen untags before the call *)
  | String_arg (* raw pointer to a NUL-terminated byte sequence *)

type builtin = { symbol : string; arg_kind : arg_kind }

type table = (int * builtin) list

let known_builtins : (string * builtin) list =
  [ ("print_int", { symbol = "ocamlcc_print_int"; arg_kind = Int_arg });
    ("print_string", { symbol = "ocamlcc_print_string"; arg_kind = String_arg });
    ("print_endline", { symbol = "ocamlcc_print_endline"; arg_kind = String_arg });
    ("exit", { symbol = "ocamlcc_exit"; arg_kind = Int_arg }) ]

let slots_of_cmi (path : string) : table =
  let cmi = Cmi_format.read_cmi path in
  let rec go idx acc = function
    | [] -> List.rev acc
    | item :: rest -> (
        match item with
        | Types.Sig_value (id, vd, _) ->
            let is_prim =
              match vd.Types.val_kind with
              | Types.Val_prim _ -> true
              | _ -> false
            in
            if is_prim then go idx acc rest
            else
              let acc =
                match List.assoc_opt (Ident.name id) known_builtins with
                | Some b -> (idx, b) :: acc
                | None -> acc
              in
              go (idx + 1) acc rest
        | Types.Sig_module (_, _, md, _, _) ->
            let has_runtime =
              match md.Types.md_type with
              | Types.Mty_alias _ -> false
              | _ -> true
            in
            go (if has_runtime then idx + 1 else idx) acc rest
        | Types.Sig_typext _ | Types.Sig_class _ -> go (idx + 1) acc rest
        | Types.Sig_type _ | Types.Sig_modtype _ | Types.Sig_class_type _ ->
            go idx acc rest)
  in
  go 0 [] cmi.Cmi_format.cmi_sign

let find_stdlib_cmi (include_dirs : string list) : string option =
  let dirs = include_dirs @ [ Config.standard_library ] in
  let candidates = [ "stdlib.cmi"; "Stdlib.cmi" ] in
  List.find_map
    (fun dir ->
      List.find_map
        (fun base ->
          let p = Filename.concat dir base in
          if Sys.file_exists p then Some p else None)
        candidates)
    dirs

let default_table : table Lazy.t =
  lazy
    (match find_stdlib_cmi [] with
    | Some path -> slots_of_cmi path
    | None -> [])

let load ?(include_dirs = []) () : table =
  match include_dirs with
  | [] -> Lazy.force default_table
  | dirs -> (
      match find_stdlib_cmi dirs with
      | Some path -> slots_of_cmi path
      | None -> [])

let resolve ?table (func : Lambda.lambda) : builtin option =
  let tbl = match table with Some t -> t | None -> Lazy.force default_table in
  match func with
  | Lambda.Lprim
      ( Lambda.Pfield (pos, _, _),
        [ Lambda.Lprim (Lambda.Pgetglobal id, [], _) ],
        _ )
    when Ident.global id && String.equal (Ident.name id) "Stdlib" ->
      List.assoc_opt pos tbl
  | _ -> None

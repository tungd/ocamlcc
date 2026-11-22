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

let value_slots lookup signature =
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
                match lookup (Ident.name id) with
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
  go 0 [] signature

let slots_of_cmi path : table =
  let cmi = Cmi_format.read_cmi path in
  value_slots (fun name -> List.assoc_opt name known_builtins) cmi.cmi_sign

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

let slot_of_callee module_name = function
  | Lambda.Lprim
      ( Lambda.Pfield (pos, _, _),
        [ Lambda.Lprim (Lambda.Pgetglobal id, [], _) ],
        _ )
    when Ident.global id && String.equal (Ident.name id) module_name ->
      Some pos
  | _ -> None

let resolve ?table (func : Lambda.lambda) : builtin option =
  let tbl = match table with Some t -> t | None -> Lazy.force default_table in
  Option.bind (slot_of_callee "Stdlib" func) (fun pos -> List.assoc_opt pos tbl)

type int_selection = Min | Max
type int_selection_table = (int * int_selection) list

let stdlib_value_slots ~unit_name ~include_dirs ~stdlib_dir lookup =
  let cmi_in dir =
    List.find_map
      (fun name ->
        let path = Filename.concat dir (name ^ ".cmi") in
        if Sys.file_exists path then Some path else None)
      [String.uncapitalize_ascii unit_name; String.lowercase_ascii unit_name; unit_name]
  in
  (* A competing persistent unit with the same name can have different
     semantics. Only trust the interface from the selected stdlib. *)
  let dirs = "" :: List.map (Misc.expand_directory Config.standard_library) include_dirs in
  let competing =
    List.exists (fun dir -> dir <> stdlib_dir && Option.is_some (cmi_in dir)) dirs
  in
  match cmi_in stdlib_dir with
  | Some path when not competing -> (
      try
        let cmi = Cmi_format.read_cmi path in
        if cmi.cmi_name = unit_name then value_slots lookup cmi.cmi_sign else []
      with Cmi_format.Error _ | Sys_error _ | End_of_file -> [])
  | _ -> []

let load_int_selection ~include_dirs ~stdlib_dir =
  stdlib_value_slots ~unit_name:"Stdlib__Int" ~include_dirs ~stdlib_dir
    (function "min" -> Some Min | "max" -> Some Max | _ -> None)

let resolve_int_selection table func =
  Option.bind (slot_of_callee "Stdlib__Int" func) (fun pos ->
      List.assoc_opt pos (Lazy.force table))


let array_initializer ~include_dirs ~stdlib_dir =
  let slots =
    lazy (stdlib_value_slots ~unit_name:"Stdlib__Array" ~include_dirs ~stdlib_dir
            (function "init" -> Some () | _ -> None))
  in
  fun callee ->
    match slot_of_callee "Stdlib__Array" callee with
    | Some index -> List.mem_assoc index (Lazy.force slots)
    | None -> false

type byte_store = Word32 | Word64

let byte_store ~include_dirs ~stdlib_dir =
  let slots = lazy (
    stdlib_value_slots ~unit_name:"Stdlib__Bytes" ~include_dirs ~stdlib_dir
      (function
        | "set_int32_ne" -> Some Word32
        | "set_int64_ne" -> Some Word64
        | "set_int32_le" when not Sys.big_endian -> Some Word32
        | "set_int64_le" when not Sys.big_endian -> Some Word64
        | _ -> None))
  in
  fun callee ->
    Option.bind (slot_of_callee "Stdlib__Bytes" callee) (fun index ->
      List.assoc_opt index (Lazy.force slots))

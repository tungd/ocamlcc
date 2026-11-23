let archive_format = "ocamlcc-opt"
let object_format = "ocamlcc-exports"
let suspension_version = 7
let current_version = suspension_version
let versions = List.init current_version (fun i -> current_version - i)

let versioned format version = format ^ "-v" ^ string_of_int version
let digest path = Digest.to_hex (Digest.file path)

let read = Sys_util.read_file
let write = Sys_util.write_atomic

let header_version format ~digest header =
  let suffix = " " ^ digest in
  List.find_opt (fun version -> header = versioned format version ^ suffix) versions

let inline_payload (fn : Anf.imported_function) =
  if fn.yields then None else Option.bind fn.inline_lambda Lambda_leaf.encode

let init_name unit_name = "ocamlcc_init_" ^ unit_name

let stamped_initializer unit_name symbol =
  let first = String.length symbol - 34 in
  if first < 0 || String.sub symbol first 2 <> "__" then None
  else
    let hash = String.sub symbol (first + 2) 32 in
    if String.for_all (function 'a'..'f' | '0'..'9' -> true | _ -> false) hash
    then Some (init_name unit_name ^ "__" ^ hash)
    else None

module Rows = struct
  type suspension = May_suspend | Proven_non_suspending | Legacy_non_suspending

  let leaf_prefix = "leaf="
  let unicode_test = "unicode-test"
  let unicode_check = "unicode-check"

  let encode ~cmi_digest exports =
    let buffer = Buffer.create 256 in
    List.iter (fun (path, (fn : Anf.imported_function)) ->
      let path = String.concat "." (List.map string_of_int path) in
      let raises = match fn.raises with
        | No_raise -> "false"
        | Finalizer_raise -> "finalizer"
        | May_raise -> "true" in
      let suspension = if fn.yields then "suspend=may" else "suspend=no" in
      Printf.bprintf buffer "%s %s %s %s %d %s %b %s"
        fn.unit_name cmi_digest path fn.symbol fn.arity suspension fn.returns_immediate raises;
      Option.iter (fun (symbol, flags) ->
        Printf.bprintf buffer " %s " symbol;
        List.iter (fun flag -> Buffer.add_char buffer (if flag then '1' else '0')) flags)
        fn.borrowed_entry;
      Option.iter (function
        | Anf.Unicode_test -> Buffer.add_string buffer (" " ^ unicode_test)
        | Unicode_check -> Buffer.add_string buffer (" " ^ unicode_check)) fn.unicode_validation;
      Option.iter (fun payload -> Printf.bprintf buffer " %s%s" leaf_prefix payload)
        (inline_payload fn);
      Buffer.add_char buffer '\n')
      exports;
    Buffer.contents buffer

  let identifier_char = function
    | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true
    | _ -> false

  let unit_name_valid s = s <> "" && String.for_all identifier_char s
  let entry_valid s =
    s <> "" && String.for_all (function '.' | '$' -> true | c -> identifier_char c) s

  let nonnegative s =
    let n = int_of_string s in
    if n < 0 then invalid_arg "negative export index or arity";
    n

  let parse_suspension ~version = function
    | "suspend=no" when version >= suspension_version -> Proven_non_suspending
    | "suspend=no" | "false" -> Legacy_non_suspending
    | "suspend=may" | "true" -> May_suspend
    | _ -> invalid_arg "invalid suspension effect"

  let decode ~version lines =
    let units = Hashtbl.create 32 in
    let add row =
      let fields = String.split_on_char ' ' row in
      let fields, leaf = match List.rev fields with
        | token :: rest when String.starts_with ~prefix:leaf_prefix token ->
            let len = String.length leaf_prefix in
            List.rev rest, Some (String.sub token len (String.length token - len))
        | _ -> fields, None in
      let fields, unicode_validation = match List.rev fields with
        | tag :: rest when tag = unicode_test -> List.rev rest, Some Anf.Unicode_test
        | tag :: rest when tag = unicode_check -> List.rev rest, Some Anf.Unicode_check
        | _ -> fields, None in
      let fields, worker = match fields with
        | [unit_name; digest; path; entry; arity; yields; immediate; raises; worker; mask] ->
            [unit_name; digest; path; entry; arity; yields; immediate; raises], Some (worker, mask)
        | fields when List.compare_length_with fields 7 = 0 -> fields @ ["true"], None
        | fields -> fields, None in
      match fields with
      | [""] -> ()
      | [unit_name; cmi_digest; path; entry; arity; yields; immediate; raises]
        when unit_name_valid unit_name && entry_valid entry ->
          let path = List.map nonnegative (String.split_on_char '.' path) in
          let arity = nonnegative arity in
          (* Archive and object writers can reseal raw rows from older tools.
             The row itself must carry the new suspension proof. *)
          let suspension = parse_suspension ~version yields in
          let yields = suspension <> Proven_non_suspending in
          let returns_immediate = bool_of_string immediate in
          if Option.is_some unicode_validation &&
             (unit_name <> "Stdlib__Uchar" || arity <> 1 || not returns_immediate) then
            invalid_arg "invalid Unicode validation summary";
          let borrowed_entry = Option.map (fun (symbol, mask) ->
            if suspension = May_suspend || not (entry_valid symbol) || symbol = entry
               || String.length mask <> arity || not (String.contains mask '1')
            then invalid_arg "invalid borrowed entry";
            let flags = List.init arity (fun i -> match mask.[i] with
              | '0' -> false | '1' -> true | _ -> invalid_arg "invalid borrow mask") in
            symbol, flags) worker in
          let borrowed_entry = if yields then None else borrowed_entry in
          let inline_lambda, inline_init =
            match leaf, stamped_initializer unit_name entry with
            | Some payload, Some init when suspension <> May_suspend ->
                (match Lambda_leaf.decode ~arity payload with
                 | Some body -> Some body, Some init
                 | None -> None, None)
            | _ -> None, None in
          let fn : Anf.imported_function =
            { unit_name; symbol = entry; arity; yields; borrowed_entry;
              raises = (match raises with
                | "false" -> No_raise | "finalizer" -> Finalizer_raise | "true" -> May_raise
                | _ -> invalid_arg "invalid exception effect");
              returns_immediate; unicode_validation; inline_leaf = None; inline_lambda; inline_init }
          in
          let exports = match Hashtbl.find_opt units unit_name with
            | None -> []
            | Some (known_digest, exports) ->
                if known_digest <> cmi_digest || List.mem_assoc path exports then
                  invalid_arg "inconsistent export summary";
                exports in
          Hashtbl.replace units unit_name (cmi_digest, (path, fn) :: exports)
      | _ -> invalid_arg "invalid export summary"
    in
    List.iter add lines;
    units
end

(* A CMI describes layout, not callee behavior. An older caller that imported
   direct-call facts must fail to link against a different implementation. *)
let seal il exports =
  let ssa = Qbe_il.to_string il in
  match exports with
  | [] -> ssa, []
  | _ ->
      let stamp = Digest.to_hex (Digest.string (ssa ^ Rows.encode ~cmi_digest:"-" exports)) in
      let names = Hashtbl.create (List.length exports) in
      let rename symbol =
        let stamped = symbol ^ "__" ^ stamp in
        Hashtbl.replace names symbol stamped;
        stamped in
      let exports = List.map (fun (path, (fn : Anf.imported_function)) ->
        let symbol = rename fn.symbol in
        let borrowed_entry = Option.map (fun (worker, flags) -> rename worker, flags) fn.borrowed_entry in
        let inline_init =
          if Option.is_some (inline_payload fn) then stamped_initializer fn.unit_name symbol
          else None in
        path, { fn with symbol; borrowed_entry; inline_init }) exports in
      let aliases =
        List.filter_map (fun (_, (fn : Anf.imported_function)) ->
          Option.map (fun alias -> alias, init_name fn.unit_name) fn.inline_init) exports
        |> List.sort_uniq compare
        |> List.map (fun (alias, init) ->
          let open Qbe_il in
          { name = alias; export = true; retty = None; params = [];
            blocks = [{ label = "start"; term = Ret None;
                        insts = [Call_void { fn = Global init; args = [] }] }] }) in
      let name symbol = Option.value ~default:symbol (Hashtbl.find_opt names symbol) in
      Qbe_il.to_string ~name { il with funcs = il.funcs @ aliases }, exports

let write_unit ~prefix exports =
  write (prefix ^ ".opt") (Rows.encode ~cmi_digest:(digest (prefix ^ ".cmi")) exports)

let write_object ~prefix ~obj body =
  let header = Printf.sprintf "%s %s\n%s\n" (versioned object_format current_version) (digest obj) (Filename.basename obj) in
  write (prefix ^ ".exports") (header ^ body)

let publish_object ~unit_name ~cmi ~obj exports =
  let prefix = Filename.concat (Filename.dirname obj) (String.uncapitalize_ascii unit_name) in
  let interface = read cmi in
  let body = Rows.encode ~cmi_digest:(Digest.to_hex (Digest.string interface)) exports in
  write (prefix ^ ".cmi") interface;
  write_object ~prefix ~obj body

let read_unit unit = Filename.chop_suffix unit ".opt", read unit

let write_unit_object unit =
  let prefix, body = read_unit unit in
  write_object ~prefix ~obj:(prefix ^ ".o") body

let write_archive ~archive ~units =
  let body = List.map (fun unit ->
    let prefix, body = read_unit unit in
    let obj = prefix ^ ".o" in
    if Sys.file_exists obj then write_object ~prefix ~obj body;
    body) units in
  write (archive ^ ".opt")
    (Printf.sprintf "%s %s\n%s" (versioned archive_format current_version) (digest archive) (String.concat "" body))

let find_archive dir =
  ["libocamlstdlib.a"; "libocamlstdlib_compat.a"]
  |> List.map (Filename.concat dir)
  |> List.find_opt Sys.file_exists

let read_archive archive =
  match String.split_on_char '\n' (read (archive ^ ".opt")) with
  | header :: lines ->
      header_version archive_format ~digest:(digest archive) header
      |> Option.map (fun version -> Rows.decode ~version lines)
  | _ -> None

let read_object cmi =
  let sidecar = Filename.chop_suffix cmi ".cmi" ^ ".exports" in
  match String.split_on_char '\n' (read sidecar) with
  | header :: obj :: lines
    when obj <> "" && obj <> "." && obj <> ".." && Filename.basename obj = obj ->
      let obj = Filename.concat (Filename.dirname cmi) obj in
      header_version object_format ~digest:(digest obj) header
      |> Option.map (fun version -> Rows.decode ~version lines)
  | _ -> None

let optional f =
  try f () with Sys_error _ | Invalid_argument _ | Failure _ -> None

module Loader = struct
  type t = unit_name:string -> cmi:string -> Anf.exports option

  let create ?archive ?(archives = []) ?(exclude_units = []) () =
    let archived =
      Option.to_list archive @ archives
      |> List.map (fun file -> Filename.dirname file, lazy (optional (fun () -> read_archive file)))
    in
    let cache = Hashtbl.create 32 in
    let lookup ~unit_name ~cmi =
      let key = unit_name, cmi in
      match Hashtbl.find_opt cache key with
      | Some result -> result
      | None ->
          let result = optional (fun () ->
            let matching units =
              match Hashtbl.find_opt units unit_name with
              | Some (cmi_digest, exports) when digest cmi = cmi_digest -> Some exports
              | _ -> None
            in
            match List.assoc_opt (Filename.dirname cmi) archived with
            | Some archive -> Option.bind (Lazy.force archive) matching
            | None -> Option.bind (read_object cmi) matching) in
          Hashtbl.add cache key result;
          result
    in
    fun ~unit_name ~cmi ->
      if List.mem unit_name exclude_units then None else lookup ~unit_name ~cmi

  let lookup load = load
end

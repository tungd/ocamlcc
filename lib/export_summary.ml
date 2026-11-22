let archive_format = "ocamlcc-opt"
let object_format = "ocamlcc-exports"
let current_version = 5

let versioned format version = format ^ "-v" ^ string_of_int version
let digest path = Digest.to_hex (Digest.file path)

let read = Sys_util.read_file
let write = Sys_util.write_atomic

let has_header format ~digest header =
  let suffix = " " ^ digest in
  List.exists (fun version -> header = versioned format version ^ suffix)
    [current_version; 4; 3; 2; 1]

module Rows = struct
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
      Printf.bprintf buffer "%s %s %s %s %d %b %b %s"
        fn.unit_name cmi_digest path fn.symbol fn.arity fn.yields fn.returns_immediate raises;
      Option.iter (fun (symbol, flags) ->
        Printf.bprintf buffer " %s " symbol;
        List.iter (fun flag -> Buffer.add_char buffer (if flag then '1' else '0')) flags)
        fn.borrowed_entry;
      Option.iter (function
        | Anf.Unicode_test -> Buffer.add_string buffer (" " ^ unicode_test)
        | Unicode_check -> Buffer.add_string buffer (" " ^ unicode_check)) fn.unicode_validation;
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

  let decode lines =
    let units = Hashtbl.create 32 in
    let add row =
      let fields = String.split_on_char ' ' row in
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
          let arity = nonnegative arity and yields = bool_of_string yields in
          let returns_immediate = bool_of_string immediate in
          if Option.is_some unicode_validation &&
             (unit_name <> "Stdlib__Uchar" || arity <> 1 || not returns_immediate) then
            invalid_arg "invalid Unicode validation summary";
          let borrowed_entry = Option.map (fun (symbol, mask) ->
            if yields || not (entry_valid symbol) || symbol = entry
               || String.length mask <> arity || not (String.contains mask '1')
            then invalid_arg "invalid borrowed entry";
            let flags = List.init arity (fun i -> match mask.[i] with
              | '0' -> false | '1' -> true | _ -> invalid_arg "invalid borrow mask") in
            symbol, flags) worker in
          let fn : Anf.imported_function =
            { unit_name; symbol = entry; arity; yields; borrowed_entry;
              raises = (match raises with
                | "false" -> No_raise | "finalizer" -> Finalizer_raise | "true" -> May_raise
                | _ -> invalid_arg "invalid exception effect");
              returns_immediate; unicode_validation; inline_leaf = None; inline_lambda = None }
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
        path, { fn with symbol; borrowed_entry }) exports in
      let name symbol = Option.value ~default:symbol (Hashtbl.find_opt names symbol) in
      Qbe_il.to_string ~name il, exports

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
  | header :: lines when has_header archive_format ~digest:(digest archive) header ->
      Some (Rows.decode lines)
  | _ -> None

let read_object cmi =
  let sidecar = Filename.chop_suffix cmi ".cmi" ^ ".exports" in
  match String.split_on_char '\n' (read sidecar) with
  | header :: obj :: lines
    when obj <> "" && obj <> "." && obj <> ".." && Filename.basename obj = obj
      && has_header object_format ~digest:(digest (Filename.concat (Filename.dirname cmi) obj)) header ->
      Some (Rows.decode lines)
  | _ -> None

let optional f =
  try f () with Sys_error _ | Invalid_argument _ | Failure _ -> None

module Loader = struct
  type t = unit_name:string -> cmi:string -> Anf.exports option

  let create ?archive ?(exclude_units = []) () =
    let archived = lazy (Option.bind archive (fun file -> optional (fun () -> read_archive file))) in
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
            if Option.exists (fun file -> Filename.dirname file = Filename.dirname cmi) archive
            then Option.bind (Lazy.force archived) matching
            else Option.bind (read_object cmi) matching) in
          Hashtbl.add cache key result;
          result
    in
    fun ~unit_name ~cmi ->
      if List.mem unit_name exclude_units then None else lookup ~unit_name ~cmi

  let lookup load = load
end

let archive_version = "ocamlcc-opt-v2"
let object_version = "ocamlcc-exports-v2"
let digest path = Digest.to_hex (Digest.file path)

let read path = In_channel.with_open_bin path In_channel.input_all

let write path data =
  let tmp, out = Filename.open_temp_file ~temp_dir:(Filename.dirname path) ~perms:0o666 "exports-" ".tmp" in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr out;
      if Sys.file_exists tmp then Sys.remove tmp)
    (fun () ->
      output_string out data;
      close_out out;
      Sys.rename tmp path)

let rows ~cmi_digest exports =
  let buffer = Buffer.create 256 in
  List.iter (fun (path, (fn : Anf.imported_function)) ->
    let path = String.concat "." (List.map string_of_int path) in
    Printf.bprintf buffer "%s %s %s %s %d %b %b %b\n"
      fn.unit_name cmi_digest path fn.symbol fn.arity fn.yields fn.returns_immediate fn.raises)
    exports;
  Buffer.contents buffer

(* A CMI describes layout, not callee behavior. An older caller that imported
   direct-call facts must fail to link against a different implementation. *)
let seal il exports =
  let ssa = Qbe_il.to_string il in
  match exports with
  | [] -> ssa, []
  | _ ->
      let stamp = Digest.to_hex (Digest.string (ssa ^ rows ~cmi_digest:"-" exports)) in
      let names = Hashtbl.create (List.length exports) in
      let exports = List.map (fun (path, (fn : Anf.imported_function)) ->
        let symbol = fn.symbol ^ "__" ^ stamp in
        Hashtbl.replace names fn.symbol symbol;
        path, { fn with symbol }) exports in
      let name symbol = Option.value ~default:symbol (Hashtbl.find_opt names symbol) in
      Qbe_il.to_string ~name il, exports

let write_unit ~prefix exports =
  write (prefix ^ ".opt") (rows ~cmi_digest:(digest (prefix ^ ".cmi")) exports)

let write_object ~prefix ~obj body =
  let header = Printf.sprintf "%s %s\n%s\n" object_version (digest obj) (Filename.basename obj) in
  write (prefix ^ ".exports") (header ^ body)

let publish_object ~unit_name ~cmi ~obj exports =
  let prefix = Filename.concat (Filename.dirname obj) (String.uncapitalize_ascii unit_name) in
  let interface = read cmi in
  let body = rows ~cmi_digest:(Digest.to_hex (Digest.string interface)) exports in
  write (prefix ^ ".cmi") interface;
  write_object ~prefix ~obj body

let write_archive ~archive ~units =
  let body = List.map (fun unit ->
    let body = read unit in
    let prefix = Filename.chop_suffix unit ".opt" in
    let obj = prefix ^ ".o" in
    if Sys.file_exists obj then write_object ~prefix ~obj body;
    body) units in
  write (archive ^ ".opt")
    (Printf.sprintf "%s %s\n%s" archive_version (digest archive) (String.concat "" body))

let find_archive dir =
  ["libocamlstdlib.a"; "libocamlstdlib_compat.a"]
  |> List.map (Filename.concat dir)
  |> List.find_opt Sys.file_exists

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

let parse_rows lines =
  let units = Hashtbl.create 32 in
  let add row =
    let fields = String.split_on_char ' ' row in
    let fields = if List.compare_length_with fields 7 = 0 then fields @ ["true"] else fields in
    match fields with
    | [""] -> ()
    | [unit_name; cmi_digest; path; entry; arity; yields; immediate; raises]
      when unit_name_valid unit_name && entry_valid entry ->
        let path = List.map nonnegative (String.split_on_char '.' path) in
        let fn : Anf.imported_function =
          { unit_name; symbol = entry; arity = nonnegative arity;
            yields = bool_of_string yields;
            raises = bool_of_string raises;
            returns_immediate = bool_of_string immediate;
            inline_leaf = None; inline_lambda = None }
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

let read_archive archive =
  match String.split_on_char '\n' (read (archive ^ ".opt")) with
  | header :: lines
    when let suffix = " " ^ digest archive in
         header = archive_version ^ suffix || header = "ocamlcc-opt-v1" ^ suffix ->
      Some (parse_rows lines)
  | _ -> None

let read_object cmi =
  let sidecar = Filename.chop_suffix cmi ".cmi" ^ ".exports" in
  match String.split_on_char '\n' (read sidecar) with
  | header :: obj :: lines
    when obj <> "" && obj <> "." && obj <> ".." && Filename.basename obj = obj
      && (let suffix = " " ^ digest (Filename.concat (Filename.dirname cmi) obj) in
          header = object_version ^ suffix || header = "ocamlcc-exports-v1" ^ suffix) ->
      Some (parse_rows lines)
  | _ -> None

let optional f =
  try f () with Sys_error _ | Invalid_argument _ | Failure _ -> None

let loader ?archive () =
  let archived = lazy (Option.bind archive (fun file -> optional (fun () -> read_archive file))) in
  let cache = Hashtbl.create 32 in
  fun ~unit_name ~cmi ->
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

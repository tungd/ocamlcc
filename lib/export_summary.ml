let version = "ocamlcc-opt-v1"
let digest path = Digest.to_hex (Digest.file path)

let read path = In_channel.with_open_bin path In_channel.input_all
let write path data = Out_channel.with_open_bin path (fun out -> output_string out data)

let write_unit ~prefix exports =
  let cmi_digest = digest (prefix ^ ".cmi") in
  let buffer = Buffer.create 256 in
  List.iter (fun (path, (fn : Anf.imported_function)) ->
    let path = String.concat "." (List.map string_of_int path) in
    Printf.bprintf buffer "%s %s %s %s %d %b %b\n"
      fn.unit_name cmi_digest path fn.symbol fn.arity fn.yields fn.returns_immediate)
    exports;
  write (prefix ^ ".opt") (Buffer.contents buffer)

let write_archive ~archive ~units =
  let body = String.concat "" (List.map read units) in
  write (archive ^ ".opt") (Printf.sprintf "%s %s\n%s" version (digest archive) body)

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

let read_archive ~include_dirs archive =
  try
    match String.split_on_char '\n' (read (archive ^ ".opt")) with
    | header :: rows when header = version ^ " " ^ digest archive ->
        let units = Hashtbl.create 32 in
        let valid_cmi unit_name cmi_digest =
          let cmi_file dir =
            [String.uncapitalize_ascii unit_name; unit_name]
            |> List.map (fun name -> Filename.concat dir (name ^ ".cmi"))
            |> List.find_opt Sys.file_exists
          in
          match List.find_map cmi_file include_dirs with
          | None -> false
          | Some cmi -> digest cmi = cmi_digest
        in
        let add row =
          match String.split_on_char ' ' row with
          | [""] -> ()
          | [unit_name; cmi_digest; path; entry; arity; yields; immediate]
            when unit_name_valid unit_name && entry_valid entry ->
              let path = List.map nonnegative (String.split_on_char '.' path) in
              let fn : Anf.imported_function =
                { unit_name; symbol = entry; arity = nonnegative arity;
                  yields = bool_of_string yields;
                  returns_immediate = bool_of_string immediate; inline_leaf = None }
              in
              let valid, exports = match Hashtbl.find_opt units unit_name with
                | None -> valid_cmi unit_name cmi_digest, []
                | Some (known_digest, valid, exports) ->
                    if known_digest <> cmi_digest || List.mem_assoc path exports then
                      invalid_arg "inconsistent export summary";
                    valid, exports in
              Hashtbl.replace units unit_name
                (cmi_digest, valid, (path, fn) :: exports)
          | _ -> invalid_arg "invalid export summary"
        in
        List.iter add rows;
        Hashtbl.fold (fun name (_, valid, exports) result ->
          if valid then (name, exports) :: result else result) units []
    | _ -> []
  with Sys_error _ | Invalid_argument _ | Failure _ -> []

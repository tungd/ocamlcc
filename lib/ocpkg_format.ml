let alphanumeric = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | _ -> false

let initial = function 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false
let identifier = function '_' -> true | c -> alphanumeric c

module Package_name = struct
  type t = string
  let of_string text =
    if text <> "" && String.for_all (function '_' | '-' -> true | c -> alphanumeric c) text
    then Ok text else Error ("invalid package name: " ^ text)
  let to_string name = name
  let compare = String.compare
end

module Rel_path = struct
  type t = string
  let of_string text =
    let unsafe = text = "" || text.[0] = '/'
      || (String.length text >= 2 && text.[1] = ':')
      || String.exists (function '\000' | '\r' | '\n' | '\\' -> true | _ -> false) text
    in
    let components = String.split_on_char '/' text in
    if unsafe || List.mem ".." components then Error ("invalid relative path: " ^ text)
    else match List.filter (fun part -> part <> "" && part <> ".") components with
      | [] -> Ok "."
      | parts -> Ok (String.concat "/" parts)
  let to_string path = path
  let resolve ~root path = Filename.concat root path
end

module Comp_input = struct
  open Sys_util.Result_syntax

  type t = { name : string; source : Rel_path.t }

  let create ~name ~source =
    let base = Filename.remove_extension name in
    let valid_basename =
      match Filename.extension name with
      | ".ml" | ".mli" -> String.for_all identifier base
      | ".c" | ".h" -> String.for_all (function '-' -> true | c -> identifier c) base
      | _ -> false
    in
    if base = "" || not (initial base.[0]) || not valid_basename
    then Error ("invalid compilation input name: " ^ name)
    else
      let* source = Rel_path.of_string source in
      if Rel_path.to_string source = "." then Error "compilation input requires a source file"
      else Ok {name; source}
  let name input = input.name
  let source input = input.source
end

type requirement = { name : Package_name.t; version : string }
type kind = Exe | Shared | Static
type test = { name : Package_name.t; entry : Rel_path.t; source_dir : Rel_path.t }
type manifest = {
  project : Package_name.t;
  kind : kind;
  entry : Rel_path.t option;
  source_dirs : Rel_path.t list;
  snapshot : Rel_path.t;
  requirements : requirement list;
  c_sources : Rel_path.t list;
  cflags : string list;
  ldflags : string list;
  public_mli : Rel_path.t list;
  single_thread_rc : bool;
  replacements : (Package_name.t * string) list;
  tests : test list;
}
let project project =
  { project; kind = Exe; entry = None; source_dirs = []; snapshot = "default";
    requirements = []; c_sources = []; cflags = []; ldflags = []; public_mli = [];
    single_thread_rc = false; replacements = []; tests = [] }

type archive = { url : string; digest : Sha256.t; root : Rel_path.t }
type source = Archive of archive | Local of Rel_path.t | Replacement of string
type wrapping = Flat | Wrapped of string
type recipe = {
  package : requirement;
  dependencies : Package_name.t list;
  source : source;
  tree : Sha256.t;
  wrapping : wrapping;
  files : Comp_input.t list;
  exports : string list;
  executable : Package_name.t option;
  cflags : string list;
  ldflags : string list;
  license : string option;
}
type lock = { catalog : Rel_path.t; digest : Sha256.t; packages : recipe list }

exception Invalid of string

let invalid line msg =
  raise (Invalid (if line = 0 then msg else Printf.sprintf "line %d: %s" line msg))

let checked line = function Ok value -> value | Error msg -> invalid line msg
let name line input = checked line (Package_name.of_string input)
let path line input = checked line (Rel_path.of_string input)
let hash line input = checked line (Sha256.of_hex input)

let blank = function ' ' | '\t' | '\r' -> true | _ -> false

let tokenize line input =
  let size = String.length input in
  let rec quoted start i =
    if i >= size then invalid line "unterminated quoted token"
    else match input.[i] with
      | '\\' -> quoted start (i + 2)
      | '"' ->
          if i + 1 < size && not (blank input.[i + 1]) && input.[i + 1] <> '#' then
            invalid line "expected space after quoted token";
          let raw = String.sub input start (i - start) in
          let value =
            try Scanf.unescaped raw with Scanf.Scan_failure _ | End_of_file ->
              invalid line "invalid escape sequence"
          in
          (value, i + 1)
      | _ -> quoted start (i + 1)
  in
  let rec bare i =
    if i = size || blank input.[i] || input.[i] = '#' then i else bare (i + 1)
  in
  let rec scan at acc =
    if at = size || input.[at] = '#' then List.rev acc
    else if blank input.[at] then scan (at + 1) acc
    else if input.[at] = '"' then
      let value, next = quoted (at + 1) (at + 1) in
      scan next (value :: acc)
    else
      let next = bare at in
      scan next (String.sub input at (next - at) :: acc)
  in
  scan 0 []

let parse text read =
  try
    String.split_on_char '\n' text
    |> List.mapi (fun index raw -> let line = index + 1 in line, tokenize line raw)
    |> List.filter (fun (_, tokens) -> tokens <> [])
    |> read |> Result.ok
  with Invalid msg -> Error msg

let requirement line package version =
  if version = "" || String.exists (fun c -> blank c || c = '\000' || c = '\n') version then
    invalid line ("invalid package version: " ^ version);
  { name = name line package; version }

let compare_requirement (a : requirement) (b : requirement) = Package_name.compare a.name b.name
let compare_recipe a b = compare_requirement a.package b.package

let unique label key values =
  let seen = Hashtbl.create (List.length values) in
  List.iter (fun value ->
    let item = key value in
    if Hashtbl.mem seen item then invalid 0 ("duplicate " ^ label ^ ": " ^ item);
    Hashtbl.add seen item ()) values

let sorted_requirements requirements =
  unique "requirement" (fun (value : requirement) -> Package_name.to_string value.name) requirements;
  List.sort compare_requirement requirements

let replacement line directory =
  if directory = "" || String.exists (function '\000' | '\n' | '\r' -> true | _ -> false) directory then
    invalid line "invalid local replacement path";
  directory

let bool line = function
  | "true" -> true
  | "false" -> false
  | input -> invalid line ("expected true or false, found " ^ input)

let kind line = function
  | "exe" -> Exe
  | "shared" -> Shared
  | "static" -> Static
  | input -> invalid line ("invalid project kind: " ^ input)

let read_manifest rows =
  let fields = Hashtbl.create 8 in
  let scalar line field =
    if Hashtbl.mem fields field then invalid line ("duplicate field: " ^ field);
    Hashtbl.add fields field ()
  in
  let rec fields_of inside state = function
    | [] ->
        if inside then invalid 0 "unterminated require block";
        if not (Hashtbl.mem fields "module") then invalid 0 "missing module directive";
        unique "replacement" (fun (package, _) -> Package_name.to_string package) state.replacements;
        unique "test" (fun (test : test) -> Package_name.to_string test.name) state.tests;
        { state with requirements = sorted_requirements state.requirements;
          source_dirs = List.rev state.source_dirs; c_sources = List.rev state.c_sources;
          cflags = List.rev state.cflags; ldflags = List.rev state.ldflags;
          public_mli = List.rev state.public_mli; replacements = List.rev state.replacements;
          tests = List.rev state.tests }
    | (line, tokens) :: rest ->
        match inside, tokens with
        | true, [")"] -> fields_of false state rest
        | true, [package; version] | false, ["require"; package; version] ->
            let required = requirement line package version in
            fields_of inside {state with requirements = required :: state.requirements} rest
        | false, ["require"; "("] -> fields_of true state rest
        | _ ->
            let state = match inside, tokens with
              | false, ["module"; value] ->
                  scalar line "module"; {state with project = name line value}
              | false, ["kind"; value] ->
                  scalar line "kind"; {state with kind = kind line value}
              | false, ["entry"; value] ->
                  scalar line "entry"; {state with entry = Some (path line value)}
              | false, ["snapshot"; value] ->
                  scalar line "snapshot"; {state with snapshot = path line value}
              | false, ["source"; value] ->
                  {state with source_dirs = path line value :: state.source_dirs}
              | false, ["c_source"; value] ->
                  {state with c_sources = path line value :: state.c_sources}
              | false, ["cflag"; value] -> {state with cflags = value :: state.cflags}
              | false, ["ldflag"; value] -> {state with ldflags = value :: state.ldflags}
              | false, ["public_mli"; value] ->
                  {state with public_mli = path line value :: state.public_mli}
              | false, ["single_thread_rc"; value] ->
                  scalar line "single_thread_rc"; {state with single_thread_rc = bool line value}
              | false, ["replace"; package; "=>"; directory] ->
                  {state with replacements = (name line package, replacement line directory)
                      :: state.replacements}
              | false, ["test"; test; entry; source] ->
                  let test = {name = name line test; entry = path line entry; source_dir = path line source} in
                  {state with tests = test :: state.tests}
              | _ -> invalid line ("invalid manifest directive: " ^ String.concat " " tokens)
            in
            fields_of inside state rest
  in
  fields_of false (project "app") rows

let parse_manifest text = parse text read_manifest

let plain_atom value =
  value <> "" && String.for_all (function
    | '\000' .. ' ' | '\127' | '"' | '#' -> false
    | _ -> true) value

let atom value = if plain_atom value then value else Printf.sprintf "%S" value

let row buffer ~indent fields =
  if indent then Buffer.add_string buffer "  ";
  Buffer.add_string buffer (String.concat " " (List.map atom fields));
  Buffer.add_char buffer '\n'

let print_manifest manifest =
  let buffer = Buffer.create 128 in
  let line = row buffer ~indent:false in
  let rel directive value = line [directive; Rel_path.to_string value] in
  line ["module"; Package_name.to_string manifest.project];
  line ["kind"; (match manifest.kind with Exe -> "exe" | Shared -> "shared" | Static -> "static")];
  Option.iter (rel "entry") manifest.entry;
  List.iter (rel "source") manifest.source_dirs;
  rel "snapshot" manifest.snapshot;
  if manifest.requirements <> [] then begin
    Buffer.add_char buffer '\n';
    line ["require"; "("];
    List.sort compare_requirement manifest.requirements
    |> List.iter (fun (r : requirement) ->
        row buffer ~indent:true [Package_name.to_string r.name; r.version]);
    line [")"]
  end;
  List.iter (rel "c_source") manifest.c_sources;
  List.iter (fun flag -> line ["cflag"; flag]) manifest.cflags;
  List.iter (fun flag -> line ["ldflag"; flag]) manifest.ldflags;
  List.iter (rel "public_mli") manifest.public_mli;
  if manifest.single_thread_rc then line ["single_thread_rc"; "true"];
  List.sort (fun (a, _) (b, _) -> Package_name.compare a b) manifest.replacements
  |> List.iter (fun (key, source) -> line ["replace"; Package_name.to_string key; "=>"; source]);
  List.iter (fun (test : test) ->
      line ["test"; Package_name.to_string test.name; Rel_path.to_string test.entry;
            Rel_path.to_string test.source_dir]) manifest.tests;
  Buffer.contents buffer

let module_name line value =
  if value = "" || not (match value.[0] with 'A' .. 'Z' -> true | _ -> false)
     || not (String.for_all identifier value)
  then invalid line ("invalid OCaml module name: " ^ value);
  value

let read_recipe ~allow_replacement line package fields =
  let fields = List.map (fun (line, tokens) -> line, List.hd tokens, List.tl tokens) fields in
  let valid = ["dep"; "url"; "sha256"; "root"; "local"; "replacement"; "tree"; "wrapped";
               "file"; "export"; "executable"; "license"; "cflag"; "ldflag"] in
  List.iter (fun (line, key, _) -> if not (List.mem key valid) then
      invalid line ("invalid package directive: " ^ key)) fields;
  let values key read =
    List.filter_map (fun (line, field, args) ->
        if field = key then Some (read line args) else None) fields
  in
  let one_token key read line = function
    | [value] -> read line value
    | _ -> invalid line ("expected one value for " ^ key)
  in
  let many key read = values key (one_token key read) in
  let optional key read =
    match many key read with
    | [value] -> Some value
    | [] -> None
    | _ -> invalid line ("duplicate field: " ^ key)
  in
  let required key read = match optional key read with
    | Some value -> value
    | None -> invalid line ("missing package field: " ^ key)
  in
  let as_text _ value = value in
  let https line url =
    if not (String.starts_with ~prefix:"https://" url) || String.length url <= 8
       || String.exists (fun c -> Char.code c <= 32 || c = '\127') url
    then invalid line "source archives require HTTPS";
    url
  in
  let source =
    match optional "local" path, optional "replacement" replacement with
    | _, Some _ when not allow_replacement -> invalid line "replacement is a lock-only field"
    | Some _, Some _ -> invalid line "package has both a local source and replacement"
    | Some directory, None ->
        if List.exists (fun (_, key, _) -> List.mem key ["url"; "sha256"; "root"]) fields then
          invalid line "package has both an archive and local source";
        Local directory
    | None, Some directory ->
        if List.exists (fun (_, key, _) -> List.mem key ["url"; "sha256"; "root"]) fields then
          invalid line "package has both an archive and local replacement";
        Replacement directory
    | None, None ->
        let url = required "url" https in
        let digest = required "sha256" hash in
        let root = required "root" path in
        if root = "." || String.contains (Rel_path.to_string root) '/' then
          invalid line "archive root must be one directory";
        Archive {url; digest; root}
  in
  let tree = required "tree" hash in
  let wrapping = optional "wrapped" (fun line -> function
      | "false" -> Flat
      | value -> Wrapped (module_name line value)) |> Option.value ~default:Flat in
  let files = values "file" (fun line -> function
    | [name; "<="; source] -> checked line (Comp_input.create ~name ~source)
    | _ -> invalid line "expected file name <= source") in
  unique "compilation input" Comp_input.name files;
  let dependencies = many "dep" name in
  unique "package dependency" Package_name.to_string dependencies;
  let exports = many "export" module_name |> List.sort_uniq String.compare in
  let executable = optional "executable" name in
  let license = optional "license" as_text in
  { package; dependencies = List.sort Package_name.compare dependencies; source; tree;
    wrapping; files = List.sort (fun a b -> String.compare (Comp_input.name a) (Comp_input.name b)) files;
    exports; executable; license; cflags = many "cflag" as_text; ldflags = many "ldflag" as_text }

let read_packages ~allow_replacement rows =
  let rec read acc = function
    | [] ->
        unique "package" (fun recipe -> Package_name.to_string recipe.package.name) acc;
        List.sort compare_recipe acc
    | (line, ["pkg"; package; version]) :: rest ->
        let rec group grouped = function
          | ((_, "pkg" :: _) :: _ | []) as rest -> List.rev grouped, rest
          | next :: rest -> group (next :: grouped) rest
        in
        let fields, rest = group [] rest in
        let recipe = read_recipe ~allow_replacement line (requirement line package version) fields in
        read (recipe :: acc) rest
    | (line, _) :: _ -> invalid line "expected pkg name version"
  in
  read [] rows

let schema = function
  | (_, ["schema"; "1"]) :: rest -> rest
  | (line, _) :: _ -> invalid line "expected schema 1"
  | [] -> invalid 0 "missing schema 1"

let parse_snapshot text = parse text (fun rows -> schema rows |> read_packages ~allow_replacement:false)
let parse_lock text =
  parse text (fun rows ->
    match schema rows with
    | (line, ["snapshot"; catalog; digest]) :: rest when String.starts_with ~prefix:"sha256:" digest ->
        { catalog = path line catalog;
          digest = hash line (String.sub digest 7 (String.length digest - 7));
          packages = read_packages ~allow_replacement:true rest }
    | (line, _) :: _ -> invalid line "expected snapshot path sha256:<digest>"
    | [] -> invalid 0 "missing snapshot directive")

let print_recipe buffer recipe =
  Buffer.add_char buffer '\n';
  row buffer ~indent:false ["pkg"; Package_name.to_string recipe.package.name; recipe.package.version];
  let line = row buffer ~indent:true in
  let text key value = line [key; value] in
  List.sort Package_name.compare recipe.dependencies
  |> List.iter (fun key -> text "dep" (Package_name.to_string key));
  (match recipe.source with
  | Local directory -> text "local" (Rel_path.to_string directory)
  | Replacement directory -> text "replacement" directory
  | Archive {url; digest; root} ->
      text "url" url;
      text "sha256" (Sha256.to_hex digest);
      text "root" (Rel_path.to_string root));
  text "tree" (Sha256.to_hex recipe.tree);
  text "wrapped" (match recipe.wrapping with Flat -> "false" | Wrapped name -> name);
  Option.iter (fun name -> text "executable" (Package_name.to_string name)) recipe.executable;
  Option.iter (text "license") recipe.license;
  List.iter (text "cflag") recipe.cflags;
  List.iter (text "ldflag") recipe.ldflags;
  List.sort String.compare recipe.exports |> List.iter (text "export");
  List.sort (fun a b -> String.compare (Comp_input.name a) (Comp_input.name b)) recipe.files
  |> List.iter (fun file ->
      line ["file"; Comp_input.name file; "<="; Rel_path.to_string (Comp_input.source file)])

let print_packages buffer packages =
  List.sort compare_recipe packages |> List.iter (print_recipe buffer);
  Buffer.contents buffer

let print_snapshot packages =
  let buffer = Buffer.create 256 in
  row buffer ~indent:false ["schema"; "1"];
  print_packages buffer packages

let print_lock lock =
  let buffer = Buffer.create 256 in
  Buffer.add_string buffer "# Generated by ocpkg; do not edit manually.\n";
  row buffer ~indent:false ["schema"; "1"];
  row buffer ~indent:false ["snapshot"; Rel_path.to_string lock.catalog; "sha256:" ^ Sha256.to_hex lock.digest];
  print_packages buffer lock.packages

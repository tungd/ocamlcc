open Ocpkg_format
open Sys_util.Result_syntax

let maximum_size = 256 * 1024 * 1024

exception Invalid of string

let invalid msg = raise (Invalid msg)

let check_io f =
  try Ok (f ()) with
  | End_of_file -> Error "truncated tar archive"
  | Sys_error msg | Invalid msg -> Error msg
  | Unix.Unix_error (code, op, path) ->
      Error (Printf.sprintf "%s %s: %s" op path (Unix.error_message code))

let with_tar path read =
  let* compression = check_io (fun () ->
    In_channel.with_open_bin path (fun channel ->
      let lead = Bytes.create 6 in
      let available = input channel lead 0 6 in
      let lead = Bytes.sub_string lead 0 available in
      if String.starts_with ~prefix:"\x1f\x8b" lead then Some "gzip"
      else if String.starts_with ~prefix:"BZh" lead then Some "bzip2"
      else if lead = "\xfd7zXZ\000" then Some "xz"
      else None)) in
  match compression with
  | None -> check_io (fun () -> In_channel.with_open_bin path read)
  | Some program ->
      let* channel =
        check_io (fun () -> Unix.open_process_args_in program [|program; "-dc"; "--"; path|]) in
      let result = check_io (fun () -> read channel) in
      let* status = check_io (fun () -> Unix.close_process_in channel) in
      match result, status with
      | Ok value, Unix.WEXITED 0 -> Ok value
      | Error msg, _ -> Error msg
      | Ok _, _ -> Error ("could not decompress archive with " ^ program)

module Reader = struct
  type t = { channel : in_channel; mutable byte_count : int }

  let reserve reader size =
    if size > maximum_size - reader.byte_count then
      invalid "archive exceeds the 256 MiB extraction limit";
    reader.byte_count <- reader.byte_count + size

  let read reader size =
    reserve reader size;
    really_input_string reader.channel size

  let transfer reader size receive =
    reserve reader size;
    let buffer = Bytes.create (min size (64 * 1024)) in
    let rec chunks remaining =
      if remaining > 0 then begin
        let length = min remaining (Bytes.length buffer) in
        really_input reader.channel buffer 0 length;
        receive buffer length;
        chunks (remaining - length)
      end
    in
    chunks size

  let discard reader size = transfer reader size (fun _ _ -> ())

  let verify_padding reader =
    let buffer = Bytes.create 4096 in
    let rec scan () =
      let used = input reader.channel buffer 0 (Bytes.length buffer) in
      reserve reader used;
      for i = 0 to used - 1 do
        if Bytes.get buffer i <> '\000' then invalid "unexpected data after the tar terminator"
      done;
      if used <> 0 then scan ()
    in
    scan ()
end

let padding size = (512 - size mod 512) mod 512
let zero_block = String.make 512 '\000'

let field block offset length =
  let rec end_of_value i =
    if i = offset + length || block.[i] = '\000' then i else end_of_value (i + 1)
  in
  String.sub block offset (end_of_value offset - offset)

let octal block offset length =
  let raw = field block offset length |> String.trim in
  let read current ch =
    if ch < '0' || ch > '7' then invalid "invalid octal field in tar header";
    let digit = Char.code ch - Char.code '0' in
    if current > (maximum_size - digit) / 8 then
      invalid "archive exceeds the 256 MiB extraction limit";
    current * 8 + digit
  in
  String.fold_left read 0 raw

let check_header block =
  let expected = octal block 148 8 in
  let sum = ref 0 in
  String.iteri (fun index byte ->
    sum := !sum + if 148 <= index && index < 156 then 32 else Char.code byte) block;
  if expected <> !sum then invalid "invalid tar header checksum"

let header_path block =
  let name = field block 0 100 in
  let prefix = if field block 257 6 = "ustar" then field block 345 155 else "" in
  if prefix = "" then name else prefix ^ "/" ^ name

module Pax = struct
  type t = { path : string option; size : int option }
  let empty = {path = None; size = None}

  let parse ~global data =
    let size = String.length data in
    let parse_num raw =
      if raw = "" || not (String.for_all (function '0' .. '9' -> true | _ -> false) raw)
      then invalid "invalid decimal field in PAX header";
      match int_of_string_opt raw with
      | Some value -> value
      | _ -> invalid "invalid decimal field in PAX header"
    in
    let rec read at attrs =
      if at = size then attrs
      else
        let after_num = match String.index_from_opt data at ' ' with
          | Some index -> index
          | None -> invalid "invalid PAX header"
        in
        let record_length = parse_num (String.sub data at (after_num - at)) in
        if record_length <= after_num - at + 2 || record_length > size - at then
          invalid "invalid PAX record length";
        let stop = at + record_length in
        if data.[stop - 1] <> '\n' then invalid "unterminated PAX record";
        let start = after_num + 1 in
        let raw = String.sub data start (stop - start - 1) in
        let split = match String.index_opt raw '=' with
          | Some index when index > 0 -> index
          | _ -> invalid "invalid PAX record"
        in
        let key = String.sub raw 0 split in
        let value = String.sub raw (split + 1) (String.length raw - split - 1) in
        let attrs =
          match key with
          | "path" when not global && attrs.path = None -> {attrs with path = Some value}
          | "size" when not global && attrs.size = None ->
              {attrs with size = Some (parse_num value)}
          | "path" | "size" | "linkpath" ->
              invalid ("unsupported PAX field: " ^ key)
          | key when String.starts_with ~prefix:"GNU.sparse" key ->
              invalid "sparse tar entries are unsupported"
          | _ -> attrs
        in
        read stop attrs
    in
    read 0 empty
end

type kind = Directory | Regular of bool
type member = { path : Rel_path.t; kind : kind; size : int }

let inspect ~root ~receive channel =
  let root = Rel_path.to_string root in
  let reader = {Reader.channel; byte_count = 0} in
  let entries = Hashtbl.create 128 in
  let implied_dirs = Hashtbl.create 32 in
  let rec parents name =
    let parent = Filename.dirname name in
    if parent <> "." then begin
      (match Hashtbl.find_opt entries parent with
      | Some (Regular _) -> invalid ("tar parent is a file: " ^ parent)
      | Some Directory -> ()
      | None -> Hashtbl.replace implied_dirs parent ());
      parents parent
    end
  in
  let validate path kind =
    let raw = Rel_path.to_string path in
    if raw <> root && not (String.starts_with ~prefix:(root ^ "/") raw) then
      invalid ("unexpected archive root: " ^ raw);
    if Hashtbl.mem entries raw then invalid ("duplicate archive entry: " ^ raw);
    (match kind with
    | Regular _ when raw = root || Hashtbl.mem implied_dirs raw ->
        invalid ("tar member replaces a directory: " ^ raw)
    | _ -> ());
    parents raw;
    Hashtbl.add entries raw kind
  in
  let rec members pending =
    let block = Reader.read reader 512 in
    if block = zero_block then begin
      if pending <> None || Reader.read reader 512 <> zero_block then
        invalid "invalid tar terminator";
      if Hashtbl.length entries = 0 then invalid "archive contains no source entries";
      Reader.verify_padding reader
    end else begin
      check_header block;
      let kind = block.[156] in
      let header_size = octal block 124 12 in
      let size =
        match pending with
        | Some attrs -> Option.value ~default:header_size attrs.Pax.size
        | None -> header_size
      in
      match kind with
      | 'x' | 'g' | 'L' ->
          if pending <> None then invalid "multiple tar extensions for one entry";
          let data = Reader.read reader header_size in
          Reader.discard reader (padding header_size);
          let attrs = match kind with
            | 'L' -> Some {Pax.empty with path = Some (field data 0 (String.length data))}
            | 'x' -> Some (Pax.parse ~global:false data)
            | _ -> ignore (Pax.parse ~global:true data); None
          in
          members attrs
      | '0' | '\000' | '5' ->
          let name = match pending with
            | Some {Pax.path = Some name; _} -> name
            | _ -> header_path block
          in
          let path = match Rel_path.of_string name with
            | Ok path -> path
            | Error msg -> invalid msg
          in
          let kind =
            if kind = '5' then begin
              if size <> 0 then invalid ("tar directory contains data: " ^ name);
              Directory
            end else Regular (octal block 100 8 land 0o111 <> 0)
          in
          validate path kind;
          receive reader {path; kind; size};
          Reader.discard reader (padding size);
          members None
      | _ -> invalid ("unsupported archive entry: " ^ header_path block)
    end
  in
  members None

let unpack ~archive ~root ~into =
  let skip reader member = Reader.discard reader member.size in
  let* () = with_tar archive (inspect ~root ~receive:skip) in
  let* directory = check_io (fun () ->
    let root_dir = Rel_path.resolve ~root:into root in
    Unix.mkdir root_dir 0o755;
    root_dir) in
  let receive reader member =
    let path = Rel_path.resolve ~root:into member.path in
    match member.kind with
    | Directory -> Sys_util.mkdir_p path
    | Regular executable ->
        Sys_util.mkdir_p (Filename.dirname path);
        let flags = [Open_wronly; Open_creat; Open_excl; Open_binary] in
        let file = open_out_gen flags 0o600 path in
        Fun.protect ~finally:(fun () -> close_out_noerr file) (fun () ->
          Reader.transfer reader member.size (fun buffer length -> output file buffer 0 length);
          close_out file);
        Unix.chmod path (if executable then 0o755 else 0o644)
  in
  let+ () = with_tar archive (inspect ~root ~receive) in
  directory

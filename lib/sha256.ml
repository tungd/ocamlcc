type t = string

let of_hex text =
  if String.length text = 64
     && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) text
  then Ok text
  else Error ("invalid SHA-256 digest: " ^ text)

let to_hex x = x
let equal = String.equal

module Hash = struct
  type t = {
    words : int32 array;
    schedule : int32 array;
    buffer : bytes;
    mutable length : int64;
    mutable pending : int;
  }

  let constants = [|
    0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l; 0x3956c25bl; 0x59f111f1l; 0x923f82a4l; 0xab1c5ed5l;
    0xd807aa98l; 0x12835b01l; 0x243185bel; 0x550c7dc3l; 0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l; 0xc19bf174l;
    0xe49b69c1l; 0xefbe4786l; 0x0fc19dc6l; 0x240ca1ccl; 0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal;
    0x983e5152l; 0xa831c66dl; 0xb00327c8l; 0xbf597fc7l; 0xc6e00bf3l; 0xd5a79147l; 0x06ca6351l; 0x14292967l;
    0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl; 0x53380d13l; 0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l;
    0xa2bfe8a1l; 0xa81a664bl; 0xc24b8b70l; 0xc76c51a3l; 0xd192e819l; 0xd6990624l; 0xf40e3585l; 0x106aa070l;
    0x19a4c116l; 0x1e376c08l; 0x2748774cl; 0x34b0bcb5l; 0x391c0cb3l; 0x4ed8aa4al; 0x5b9cca4fl; 0x682e6ff3l;
    0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l; 0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l;
  |]

  let create () =
    { words = [|0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al;
                0x510e527fl; 0x9b05688cl; 0x1f83d9abl; 0x5be0cd19l|];
      schedule = Array.make 64 0l; buffer = Bytes.create 64; length = 0L; pending = 0 }

  let ( +! ) = Int32.add
  let ( ^! ) = Int32.logxor
  let ( &! ) = Int32.logand
  let shift = Int32.shift_right_logical
  let rotate x n = Int32.logor (shift x n) (Int32.shift_left x (32 - n))
  let choose x y z = (x &! y) ^! (Int32.lognot x &! z)
  let majority x y z = (x &! y) ^! (x &! z) ^! (y &! z)
  let sigma0 x = rotate x 7 ^! rotate x 18 ^! shift x 3
  let sigma1 x = rotate x 17 ^! rotate x 19 ^! shift x 10
  let sum0 x = rotate x 2 ^! rotate x 13 ^! rotate x 22
  let sum1 x = rotate x 6 ^! rotate x 11 ^! rotate x 25

  let compress state input position =
    let w = state.schedule in
    for i = 0 to 15 do
      w.(i) <- Bytes.get_int32_be input (position + 4 * i)
    done;
    for i = 16 to 63 do
      w.(i) <- sigma1 w.(i - 2) +! w.(i - 7) +! sigma0 w.(i - 15) +! w.(i - 16)
    done;
    let h = state.words in
    let rec round i a b c d e f g carry =
      if i = 64 then begin
        h.(0) <- h.(0) +! a; h.(1) <- h.(1) +! b;
        h.(2) <- h.(2) +! c; h.(3) <- h.(3) +! d;
        h.(4) <- h.(4) +! e; h.(5) <- h.(5) +! f;
        h.(6) <- h.(6) +! g; h.(7) <- h.(7) +! carry
      end else
        let first = carry +! sum1 e +! choose e f g +! constants.(i) +! w.(i) in
        let second = sum0 a +! majority a b c in
        round (i + 1) (first +! second) a b c (d +! first) e f g
    in
    round 0 h.(0) h.(1) h.(2) h.(3) h.(4) h.(5) h.(6) h.(7)

  let append state input length =
    state.length <- Int64.add state.length (Int64.of_int length);
    let rec blocks position =
      let remaining = length - position in
      if state.pending = 0 && remaining >= 64 then begin
        compress state input position;
        blocks (position + 64)
      end else if remaining > 0 then begin
        let copied = min remaining (64 - state.pending) in
        Bytes.blit input position state.buffer state.pending copied;
        state.pending <- state.pending + copied;
        if state.pending = 64 then begin
          compress state state.buffer 0;
          state.pending <- 0;
          blocks (position + copied)
        end
      end
    in
    blocks 0

  let append_string state text = append state (Bytes.unsafe_of_string text) (String.length text)

  let finish state =
    let size = if state.pending < 56 then 64 - state.pending else 128 - state.pending in
    let padding = Bytes.make size '\000' in
    Bytes.set padding 0 '\128';
    Bytes.set_int64_be padding (size - 8) (Int64.shift_left state.length 3);
    append state padding size;
    Array.to_list state.words |> List.map (Printf.sprintf "%08lx") |> String.concat ""
end

let string input =
  let hash = Hash.create () in
  Hash.append_string hash input;
  Hash.finish hash

let digest_file path =
  In_channel.with_open_bin path (fun channel ->
    let hash = Hash.create () in
    let buffer = Bytes.create (64 * 1024) in
    let rec read () =
      let count = input channel buffer 0 (Bytes.length buffer) in
      if count = 0 then Hash.finish hash
      else (Hash.append hash buffer count; read ())
    in
    read ())

let protect_io f =
  try Ok (f ()) with
  | Sys_error msg | Failure msg -> Error msg
  | Unix.Unix_error (error, operation, path) ->
      Error (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error))

let file path = protect_io (fun () -> digest_file path)

let decode_filename path index =
  let decoded = String.get_utf_8_uchar path index in
  if Uchar.utf_decode_is_valid decoded then
    Uchar.to_int (Uchar.utf_decode_uchar decoded), Uchar.utf_decode_length decoded
  else
    (* Match Python's filesystem surrogate escapes for invalid UTF-8 bytes. *)
    0xdc00 + Char.code path.[index], 1

let compare_names left right =
  let rec compare_at i j =
    if i = String.length left then
      if j = String.length right then 0 else -1
    else if j = String.length right then 1
    else
      let a, width_a = decode_filename left i in
      let b, width_b = decode_filename right j in
      if a = b then compare_at (i + width_a) (j + width_b)
      else Int.compare a b
  in
  compare_at 0 0

let add_json_path buffer path =
  let rec encode i =
    if i < String.length path then begin
      let code, width = decode_filename path i in
      (match code with
      | 0x22 -> Buffer.add_string buffer "\\\""
      | 0x5c -> Buffer.add_string buffer "\\\\"
      | 8 -> Buffer.add_string buffer "\\b"
      | 9 -> Buffer.add_string buffer "\\t"
      | 10 -> Buffer.add_string buffer "\\n"
      | 12 -> Buffer.add_string buffer "\\f"
      | 13 -> Buffer.add_string buffer "\\r"
      | code when code >= 32 && code < 127 -> Buffer.add_char buffer (Char.chr code)
      | code when code <= 0xffff -> Printf.bprintf buffer "\\u%04x" code
      | code ->
          let supplementary = code - 0x10000 in
          Printf.bprintf buffer "\\u%04x\\u%04x" (0xd800 + (supplementary lsr 10))
            (0xdc00 + (supplementary land 0x3ff)));
      encode (i + width)
    end
  in
  Buffer.add_char buffer '"';
  encode 0;
  Buffer.add_char buffer '"'

let tree_hash ?(file = file) root =
  protect_io (fun () ->
    if (Unix.lstat root).st_kind <> Unix.S_DIR then failwith ("not a source directory: " ^ root);
    let hash = Hash.create () in
    let row = Buffer.create 192 in
    Hash.append_string hash "[";
    let first = ref true in
    let rec walk prefix path =
      let entries = Sys.readdir path in
      Array.sort compare_names entries;
      Array.iter (fun name ->
        let relative = prefix ^ name in
        let full_path = Filename.concat path name in
        let stat = Unix.lstat full_path in
        match stat.st_kind with
        | Unix.S_DIR -> walk (relative ^ "/") full_path
        | Unix.S_REG ->
            Buffer.clear row;
            if !first then first := false else Buffer.add_char row ',';
            Buffer.add_char row '[';
            add_json_path row relative;
            let digest = match file full_path with
              | Ok digest -> digest
              | Error message -> failwith message in
            Printf.bprintf row ",%b,\"%s\"]" (stat.st_perm land 0o111 <> 0) digest;
            Hash.append_string hash (Buffer.contents row)
        | _ -> failwith ("unsupported source entry: " ^ full_path)
      ) entries
    in
    walk "" root;
    Hash.append_string hash "]";
    Hash.finish hash)

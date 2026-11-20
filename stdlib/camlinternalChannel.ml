(**************************************************************************)
(*                                                                        *)
(*   Pure OCaml buffered channels (in_channel / out_channel).             *)
(*   Compiled with --nopervasives right after CamlinternalBulkOps.        *)
(*                                                                        *)
(**************************************************************************)

external raise : exn -> 'a = "%raise"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external not : bool -> bool = "%boolnot"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external ( ~- ) : int -> int = "%negint"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( land ) : int -> int -> int = "%andint"
external ( lor ) : int -> int -> int = "%orint"
external ( lxor ) : int -> int -> int = "%xorint"
external ( lsl ) : int -> int -> int = "%lslint"
external ( lsr ) : int -> int -> int = "%lsrint"

external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"
external unsafe_bytes_of_string : string -> bytes = "%identity"

external bytes_create : int -> bytes = "caml_create_bytes"
external bytes_unsafe_get : bytes -> int -> char = "%bytes_unsafe_get"
external bytes_unsafe_set : bytes -> int -> char -> unit = "%bytes_unsafe_set"

external i64_of_int : int -> int64 = "%int64_of_int"
external i64_to_int : int64 -> int = "%int64_to_int"
external i64_add : int64 -> int64 -> int64 = "%int64_add"
external i64_sub : int64 -> int64 -> int64 = "%int64_sub"

type mutex_t
external mutex_new : unit -> mutex_t = "caml_ml_mutex_new"
external mutex_lock : mutex_t -> unit = "caml_ml_mutex_lock"
external mutex_unlock : mutex_t -> unit = "caml_ml_mutex_unlock"

type 'a weak_t
external weak_create : int -> 'a weak_t = "ocamlcc_weak_create"
external weak_length : 'a weak_t -> int = "ocamlcc_weak_length"
external weak_get : 'a weak_t -> int -> 'a option = "ocamlcc_weak_get"
external weak_set : 'a weak_t -> int -> 'a option -> unit = "ocamlcc_weak_set"

external raw_fd_read : int -> bytes -> int -> int -> int = "ocamlcc_raw_fd_read"
external raw_fd_write : int -> bytes -> int -> int -> unit = "ocamlcc_raw_fd_write"
external raw_fd_lseek : int -> int64 -> int -> int64 = "ocamlcc_raw_fd_lseek"
external raw_fd_size : int -> int64 = "ocamlcc_raw_fd_size"
external raw_fd_close : int -> unit = "ocamlcc_raw_fd_close"
external raw_fd_isatty : int -> bool = "ocamlcc_raw_fd_isatty"
external stdio_flush : int -> unit = "ocamlcc_stdio_flush"

external ba_to_bytes : 'a -> int -> bytes -> int -> int -> unit = "ocamlcc_ba_to_bytes"
external ba_of_bytes_slice : 'a -> int -> bytes -> int -> int -> unit = "ocamlcc_ba_of_bytes_slice"

let bufsz = 4096

type channel = {
  fd : int;
  is_out : bool;
  is_std : bool;
  mutable unbuffered : bool;
  mutable closed : bool;
  mutable binary : bool;
  mutable cur : int;
  mutable max : int;
  buf : bytes;
}

type in_channel = channel
type out_channel = channel

type 'a mref = { mutable contents : 'a }

let out_lock = mutex_new ()
let out_slots : channel weak_t mref = { contents = weak_create 16 }
let out_len : int mref = { contents = 0 }

let register_out ch =
  mutex_lock out_lock;
  let slots = out_slots.contents in
  let len = out_len.contents in
  let cap = weak_length slots in
  let rec find_free i =
    if i >= len then -1
    else
      match weak_get slots i with
      | None -> i
      | Some c ->
          if c.closed then begin weak_set slots i None; i end
          else find_free (i + 1)
  in
  let idx = find_free 0 in
  if idx >= 0 then
    weak_set slots idx (Some ch)
  else if len < cap then begin
    weak_set slots len (Some ch);
    out_len.contents <- len + 1
  end else begin
    let next = weak_create (cap * 2) in
    let rec copy i dst =
      if i >= len then dst
      else
        match weak_get slots i with
        | Some c when not c.closed ->
            weak_set next dst (Some c);
            copy (i + 1) (dst + 1)
        | _ -> copy (i + 1) dst
    in
    let nlen = copy 0 0 in
    weak_set next nlen (Some ch);
    out_slots.contents <- next;
    out_len.contents <- nlen + 1
  end;
  mutex_unlock out_lock

let out_channels_list () =
  mutex_lock out_lock;
  let slots = out_slots.contents in
  let rec collect i acc =
    if i < 0 then acc
    else
      match weak_get slots i with
      | None -> collect (i - 1) acc
      | Some c ->
          if c.closed then begin
            weak_set slots i None;
            collect (i - 1) acc
          end else
            collect (i - 1) (c :: acc)
  in
  let lst = collect (out_len.contents - 1) [] in
  mutex_unlock out_lock;
  lst

let make_channel fd is_out =
  {
    fd;
    is_out;
    is_std = fd >= 0 && fd <= 2;
    unbuffered = false;
    closed = false;
    binary = true;
    cur = 0;
    max = 0;
    buf = bytes_create bufsz;
  }

let open_descriptor_in fd = make_channel fd false

let open_descriptor_out fd =
  let ch = make_channel fd true in
  register_out ch;
  ch

let set_channel_name (_ch : channel) (_name : string) = ()

let flush_internal ch =
  if ch.is_out && not ch.closed then begin
    let n = ch.cur in
    if n > 0 then begin
      raw_fd_write ch.fd ch.buf 0 n;
      ch.cur <- 0
    end;
    if ch.is_std then stdio_flush ch.fd
  end

let flush ch =
  if not ch.closed then flush_internal ch

let write_bytes ch src ofs len =
  if ch.closed then raise (Sys_error "Closed channel");
  if len > 0 then begin
    if ch.cur + len <= bufsz && not ch.unbuffered then begin
      CamlinternalBulkOps.blit_bytes src ofs ch.buf ch.cur len;
      ch.cur <- ch.cur + len
    end else begin
      flush_internal ch;
      if len >= bufsz || ch.unbuffered then begin
        raw_fd_write ch.fd src ofs len;
        if ch.is_std then stdio_flush ch.fd
      end else begin
        CamlinternalBulkOps.blit_bytes src ofs ch.buf 0 len;
        ch.cur <- len
      end
    end
  end

let output_char ch c =
  if ch.closed then raise (Sys_error "Closed channel");
  if not ch.unbuffered && ch.cur < bufsz then begin
    bytes_unsafe_set ch.buf ch.cur c;
    ch.cur <- ch.cur + 1
  end else begin
    flush_internal ch;
    bytes_unsafe_set ch.buf 0 c;
    ch.cur <- 1;
    if ch.unbuffered then flush_internal ch
  end

let output_byte ch b = output_char ch (char_of_int (b land 0xff))

let unsafe_output ch src ofs len = write_bytes ch src ofs len

let unsafe_output_string ch src ofs len =
  write_bytes ch (unsafe_bytes_of_string src) ofs len

let output_int ch n =
  if ch.closed then raise (Sys_error "Closed channel");
  if ch.cur + 4 > bufsz then flush_internal ch;
  let pos = ch.cur in
  bytes_unsafe_set ch.buf pos (char_of_int ((n lsr 24) land 0xff));
  bytes_unsafe_set ch.buf (pos + 1) (char_of_int ((n lsr 16) land 0xff));
  bytes_unsafe_set ch.buf (pos + 2) (char_of_int ((n lsr 8) land 0xff));
  bytes_unsafe_set ch.buf (pos + 3) (char_of_int (n land 0xff));
  ch.cur <- pos + 4;
  if ch.unbuffered then flush_internal ch

let refill ch =
  if ch.closed then raise (Sys_error "Closed channel");
  ch.cur <- 0;
  ch.max <- 0;
  let r = raw_fd_read ch.fd ch.buf 0 bufsz in
  ch.max <- r;
  r

let input_char ch =
  if ch.closed then raise (Sys_error "Closed channel");
  if ch.cur >= ch.max then begin
    if refill ch = 0 then raise End_of_file
  end;
  let c = bytes_unsafe_get ch.buf ch.cur in
  ch.cur <- ch.cur + 1;
  c

let input_byte ch = int_of_char (input_char ch)

let unsafe_input ch dst ofs len =
  if ch.closed then raise (Sys_error "Closed channel");
  if len = 0 then 0
  else
    let avail = ch.max - ch.cur in
    if avail > 0 then begin
      let take = if len < avail then len else avail in
      CamlinternalBulkOps.blit_bytes ch.buf ch.cur dst ofs take;
      ch.cur <- ch.cur + take;
      take
    end else if len >= bufsz then
      raw_fd_read ch.fd dst ofs len
    else
      let r = refill ch in
      if r = 0 then 0
      else begin
        let take = if len < r then len else r in
        CamlinternalBulkOps.blit_bytes ch.buf 0 dst ofs take;
        ch.cur <- take;
        take
      end

let input_int ch =
  let b0 = input_byte ch in
  let b1 = input_byte ch in
  let b2 = input_byte ch in
  let b3 = input_byte ch in
  let w = (b0 lsl 24) lor (b1 lsl 16) lor (b2 lsl 8) lor b3 in
  let sign = 1 lsl 31 in
  (w lxor sign) - sign

let input_scan_line ch =
  if ch.closed then raise (Sys_error "Closed channel");
  let avail = ch.max - ch.cur in
  let avail = if avail = 0 then refill ch else avail in
  if avail = 0 then 0
  else
    let rec find i =
      if i >= ch.max then -(ch.max - ch.cur)
      else if bytes_unsafe_get ch.buf i = '\n' then i - ch.cur + 1
      else find (i + 1)
    in
    find ch.cur

let seek_out_64 ch pos =
  if ch.closed then raise (Sys_error "Closed channel");
  flush_internal ch;
  let _ = raw_fd_lseek ch.fd pos 0 in
  ()

let seek_out ch pos = seek_out_64 ch (i64_of_int pos)

let pos_out_64 ch =
  if ch.closed then raise (Sys_error "Closed channel");
  i64_add (raw_fd_lseek ch.fd 0L 1) (i64_of_int ch.cur)

let pos_out ch = i64_to_int (pos_out_64 ch)

let seek_in_64 ch pos =
  if ch.closed then raise (Sys_error "Closed channel");
  let _ = raw_fd_lseek ch.fd pos 0 in
  ch.cur <- 0;
  ch.max <- 0

let seek_in ch pos = seek_in_64 ch (i64_of_int pos)

let pos_in_64 ch =
  if ch.closed then raise (Sys_error "Closed channel");
  i64_sub (raw_fd_lseek ch.fd 0L 1) (i64_of_int (ch.max - ch.cur))

let pos_in ch = i64_to_int (pos_in_64 ch)

let channel_size_64 ch =
  if ch.closed then raise (Sys_error "Closed channel");
  if ch.is_out then flush_internal ch;
  raw_fd_size ch.fd

let channel_size ch = i64_to_int (channel_size_64 ch)

let close_channel ch =
  if not ch.closed then begin
    let flush_err =
      if ch.is_out then
        try flush_internal ch; None
        with e -> Some e
      else None
    in
    let close_err =
      if not ch.is_std then
        try raw_fd_close ch.fd; None
        with e -> Some e
      else None
    in
    ch.closed <- true;
    match flush_err, close_err with
    | Some e, _ -> raise e
    | None, Some e -> raise e
    | None, None -> ()
  end

let set_binary_mode ch mode =
  ch.binary <- mode

let is_binary_mode ch = ch.binary

let set_buffered ch mode =
  ch.unbuffered <- not mode;
  if not mode && ch.is_out && not ch.closed then flush_internal ch

let is_buffered ch = not ch.unbuffered

let isatty ch =
  if ch.closed then false else raw_fd_isatty ch.fd

let unsafe_input_bigarray ch ba bofs len =
  if ch.closed then raise (Sys_error "Closed channel");
  if len = 0 then begin
    ba_of_bytes_slice ba bofs ch.buf 0 0;
    0
  end else begin
    let avail = ch.max - ch.cur in
    if avail > 0 then begin
      let take = if len < avail then len else avail in
      ba_of_bytes_slice ba bofs ch.buf ch.cur take;
      ch.cur <- ch.cur + take;
      take
    end else begin
      let r = refill ch in
      if r = 0 then 0
      else begin
        let take = if len < r then len else r in
        ba_of_bytes_slice ba bofs ch.buf 0 take;
        ch.cur <- take;
        take
      end
    end
  end

let unsafe_output_bigarray ch ba bofs len =
  if ch.closed then raise (Sys_error "Closed channel");
  let rec loop ofs rem =
    if rem <= 0 then begin
      if ch.unbuffered then flush_internal ch
    end else if not ch.unbuffered && ch.cur + rem <= bufsz then begin
      ba_to_bytes ba ofs ch.buf ch.cur rem;
      ch.cur <- ch.cur + rem
    end else begin
      flush_internal ch;
      let chunk = if rem < bufsz then rem else bufsz in
      ba_to_bytes ba ofs ch.buf 0 chunk;
      ch.cur <- chunk;
      if ch.unbuffered then flush_internal ch;
      loop (ofs + chunk) (rem - chunk)
    end
  in
  loop bofs len

type mode = Disabled | Plain | Tty

type scope = {
  owner : t;
  prefix : string;
  total : int;
  start_time : float;
  mutable completed : int;
  mutable compiled : int;
  mutable active : (int * string) list;
}

and t = {
  mode : mode;
  mutable current_line : bool;
  mutable active_scope : scope option;
  mutable last_tty_draw : float;
}

let create ~enabled ~verbose =
  let tty = Unix.isatty Unix.stderr && Sys.getenv_opt "TERM" <> Some "dumb" in
  let mode =
    if not enabled then Disabled
    else if not verbose && tty then Tty
    else Plain
  in
  { mode; current_line = false; active_scope = None; last_tty_draw = 0.0 }

let is_tty t = t.mode = Tty

let format_duration secs =
  if secs < 1.0 then Printf.sprintf "%.2fs" secs
  else Printf.sprintf "%.1fs" secs

let clear_line t =
  if t.current_line then begin
    output_string stderr "\r\027[K";
    flush stderr;
    t.current_line <- false
  end

let format_active active =
  let rec collect acc count = function
    | [] -> List.rev acc, 0
    | (_, name) :: rest ->
        if count >= 3 then List.rev acc, 1 + List.length rest
        else collect (name :: acc) (count + 1) rest
  in
  let names, extra = collect [] 0 active in
  let text = String.concat ", " names in
  if extra > 0 then Printf.sprintf "%s (+%d)" text extra else text

let truncate max_len text =
  if String.length text <= max_len then text
  else if max_len <= 3 then String.sub text 0 max_len
  else String.sub text 0 (max_len - 3) ^ "..."

let render_scope ?(force = false) s =
  let t = s.owner in
  if t.mode = Tty then
    let now = Unix.gettimeofday () in
    if force || now -. t.last_tty_draw >= 0.05 then begin
      t.last_tty_draw <- now;
      let active_text = format_active s.active in
      let line =
        if active_text = "" then
          Printf.sprintf "[%s %d/%d]" s.prefix s.completed s.total
        else
          Printf.sprintf "[%s %d/%d] %s" s.prefix s.completed s.total active_text
      in
      let line = truncate 96 line in
      output_string stderr "\r\027[K";
      output_string stderr line;
      flush stderr;
      t.current_line <- true
    end

let milestone t msg =
  match t.mode with
  | Disabled -> ()
  | Plain -> Printf.eprintf "%s\n%!" msg
  | Tty ->
      clear_line t;
      Printf.eprintf "%s\n%!" msg;
      Option.iter (render_scope ~force:true) t.active_scope

let finish t =
  clear_line t;
  t.active_scope <- None

let start_scope t ~prefix ~total =
  let now = Unix.gettimeofday () in
  let s =
    { owner = t; prefix; total; start_time = now;
      completed = 0; compiled = 0; active = [] }
  in
  if t.mode = Tty then begin
    t.active_scope <- Some s;
    t.last_tty_draw <- now
  end;
  s

let task_started s ~id ~name =
  s.active <- (id, name) :: List.remove_assoc id s.active;
  render_scope ~force:true s

let task_detail s ~id name =
  if List.mem_assoc id s.active then begin
    s.active <- List.map (fun (k, v) -> if k = id then (k, name) else (k, v)) s.active;
    render_scope s
  end

let task_finished ?milestone:msg ~id ~cached s =
  s.completed <- s.completed + 1;
  if not cached then s.compiled <- s.compiled + 1;
  let was_active = List.mem_assoc id s.active in
  s.active <- List.remove_assoc id s.active;
  match msg with
  | Some text when not cached -> milestone s.owner text
  | _ ->
      if s.owner.mode = Tty && (s.completed < s.total || s.active <> []) then
        render_scope ~force:was_active s

let end_scope ?summary s =
  clear_line s.owner;
  (match s.owner.active_scope with
   | Some cur when cur == s -> s.owner.active_scope <- None
   | _ -> ());
  if s.compiled > 0 then
    Option.iter (milestone s.owner) summary

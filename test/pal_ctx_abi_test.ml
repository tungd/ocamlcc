(* ABI contract between runtime/pal.h's PalContext and runtime/pal_ctx.S.

   Each per-architecture pal_ctx_swap frame (max store extent, stack-pointer
   and return-address slots, callee-saved FP registers) must be exactly
   covered by the PalContext definition, and pal_ctx_make must initialize the
   matching slots for every architecture the assembly implements. The struct
   side is verified per ABI by compiling forced-branch probes of the arch
   macros, so every ABI is checked on any host. *)

let has_substr ~sub s =
  let sl = String.length sub in
  let n = String.length s in
  let rec go i =
    if i > n - sl then false
    else if String.sub s i sl = sub then true
    else go (i + 1)
  in
  if sl = 0 then true else go 0

let index_of s sub =
  let sl = String.length sub in
  let n = String.length s in
  let rec go i =
    if i + sl > n then None
    else if String.sub s i sl = sub then Some i
    else go (i + 1)
  in
  if sl = 0 then Some 0 else go 0

let count_substr s sub =
  let n = String.length sub in
  let rec go i acc =
    if i + n > String.length s then acc
    else if String.sub s i n = sub then go (i + 1) (acc + 1)
    else go (i + 1) acc
  in
  go 0 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      Sys.rmdir path
    end
    else Sys.remove path

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base (Printf.sprintf "ocamlcc_pal_abi_%d" (Unix.getpid ()))
  in
  if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let find_repo_root () =
  let rec up dir =
    if
      Sys.file_exists (Filename.concat dir "build.ninja")
      && Sys.file_exists (Filename.concat dir "runtime/arc.c")
    then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then failwith "cannot find repo root" else up parent
  in
  up (Sys.getcwd ())

(* Architecture sections of pal_ctx.S / the pal.h register ladder, keyed by
   the guard substring that selects them. sp_off/pc_off are the ABI positions
   of the saved stack pointer and return address inside the frame. *)
type arch = {
  key : string;
  guard : string;
  from_marker : string; (* memory-operand marker for the first context arg *)
  to_marker : string;   (* memory-operand marker for the second context arg *)
  sp_off : int;
  pc_off : int;
  fp_regs : string list; (* callee-saved FP registers for this ABI *)
  defines : string list; (* -D flags forcing this branch in probes *)
  undefs : string list;  (* -U flags clearing foreign-arch macros *)
}

let arches =
  [
    { key = "aarch64";
      guard = "__aarch64__";
      from_marker = "[x0";
      to_marker = "[x1";
      sp_off = 96;
      pc_off = 88;
      fp_regs = List.init 8 (fun i -> "d" ^ string_of_int (i + 8));
      defines = [ "-D__aarch64__=1" ];
      undefs =
        [ "-U__aarch64__"; "-U__x86_64__"; "-U__x86_64"; "-U__riscv"; "-U_WIN32" ] };
    { key = "win64";
      guard = "__x86_64__) && defined(_WIN32";
      from_marker = "(%rcx)";
      to_marker = "(%rdx)";
      sp_off = 64;
      pc_off = 72;
      fp_regs = List.init 10 (fun i -> "xmm" ^ string_of_int (i + 6));
      defines = [ "-D__x86_64__=1"; "-D__x86_64=1"; "-D_WIN32=1" ];
      undefs =
        [ "-U__aarch64__"; "-U__x86_64__"; "-U__x86_64"; "-U__riscv"; "-U_WIN32" ] };
    { key = "x86_64";
      guard = "__x86_64__";
      from_marker = "(%rdi)";
      to_marker = "(%rsi)";
      sp_off = 48;
      pc_off = 56;
      fp_regs = [];
      defines = [ "-D__x86_64__=1"; "-D__x86_64=1" ];
      undefs =
        [ "-U__aarch64__"; "-U__x86_64__"; "-U__x86_64"; "-U__riscv"; "-U_WIN32" ] };
    { key = "riscv64";
      guard = "__riscv";
      from_marker = "(a0)";
      to_marker = "(a1)";
      sp_off = 104;
      pc_off = 96;
      fp_regs = List.init 12 (fun i -> "fs" ^ string_of_int i);
      defines = [ "-D__riscv=1"; "-D__riscv_xlen=64" ];
      undefs =
        [ "-U__aarch64__"; "-U__x86_64__"; "-U__x86_64"; "-U__riscv"; "-U_WIN32" ] };
  ]

(* Extract the displacement of the memory operand whose marker occurs in the
   line: aarch64 uses "[x0, #96]", riscv/x86 use "96(a0)" / "96(%rcx)". *)
let operand_offset line marker =
  match index_of line marker with
  | None -> None
  | Some i ->
      let digits_from () =
        let n = String.length line in
        let rec back k =
          if k >= 0 && line.[k] >= '0' && line.[k] <= '9' then back (k - 1)
          else k + 1
        in
        let rec fwd k acc =
          if k < n && line.[k] >= '0' && line.[k] <= '9' then
            fwd (k + 1) ((acc * 10) + (Char.code line.[k] - Char.code '0'))
          else acc
        in
        let first = back (i - 1) in
        if i = 0 || first > i - 1 then None else Some (fwd first 0)
      in
      let digits_after_hash () =
        let n = String.length line in
        let rec skip k =
          if k < n && line.[k] <> '#' then skip (k + 1) else k
        in
        let h = skip i in
        if h >= n then None
        else
          let rec fwd k acc =
            if k < n && line.[k] >= '0' && line.[k] <= '9' then
              fwd (k + 1) ((acc * 10) + (Char.code line.[k] - Char.code '0'))
            else if k = h + 1 then None
            else Some acc
          in
          fwd (h + 1) 0
      in
      if has_substr ~sub:"#" line then digits_after_hash () else digits_from ()

let instr_width = function
  | "stp" | "ldp" | "movdqu" | "movaps" -> 16
  | _ -> 8

let is_store = function
  | "stp" | "str" | "sd" | "fsd" | "movq" | "movdqu" | "movaps" -> true
  | _ -> false

let is_load = function
  | "ldp" | "ldr" | "ld" | "fld" | "movq" | "movdqu" | "movaps" -> true
  | _ -> false

let first_word line =
  match String.index_opt line ' ' with
  | None -> line
  | Some i -> String.sub line 0 i

(* Frame geometry of one pal_ctx_swap section: max store extent, saved/loaded
   FP registers, and which offsets are stored/loaded. *)
type frame = {
  extent : int;
  saved_fp : string list;
  loaded_fp : string list;
  store_offsets : int list;
  load_offsets : int list;
}

let parse_frame lines a =
  let store_lines =
    List.filter
      (fun l ->
        let t = String.trim l in
        is_store (first_word t) && has_substr ~sub:a.from_marker t)
      lines
  in
  let load_lines =
    List.filter
      (fun l ->
        let t = String.trim l in
        is_load (first_word t) && has_substr ~sub:a.to_marker t)
      lines
  in
  let offsets_of lines_list marker =
    List.concat
      (List.filter_map
         (fun l ->
           let t = String.trim l in
           match operand_offset t marker with
           | Some off ->
               (* Pair stores/loads cover two consecutive slots. *)
               if instr_width (first_word t) = 16 then Some [ off; off + 8 ]
               else Some [ off ]
           | None -> None)
         lines_list)
  in
  let store_offsets = offsets_of store_lines a.from_marker in
  let load_offsets = offsets_of load_lines a.to_marker in
  let extent =
    List.fold_left
      (fun acc l ->
        let t = String.trim l in
        match operand_offset t a.from_marker with
        | Some off -> max acc (off + instr_width (first_word t))
        | None -> acc)
      0 store_lines
  in
  let fp_of lines_list =
    List.filter_map
      (fun r ->
        if List.exists (fun l -> has_substr ~sub:r l) lines_list then Some r
        else None)
      a.fp_regs
  in
  { extent;
    saved_fp = fp_of store_lines;
    loaded_fp = fp_of load_lines;
    store_offsets;
    load_offsets }

(* Split a source file into per-arch sections following #if/#elif guards.
   #else and #endif end the current branch. *)
let split_sections guard_map text =
  let lines = String.split_on_char '\n' text in
  let sections = Hashtbl.create 8 in
  let current = ref None in
  List.iter
    (fun raw ->
      let line = String.trim raw in
      if
        has_substr ~sub:"#endif" line || has_substr ~sub:"#else" line
      then current := None
      else if has_substr ~sub:"#if" line || has_substr ~sub:"#elif" line then
        let candidates =
          List.filter (fun (guard, _) -> has_substr ~sub:guard line) guard_map
        in
        let by_specificity (g1, _) (g2, _) = String.length g2 - String.length g1 in
        current :=
          (match List.sort by_specificity candidates with
          | (_, key) :: _ -> Some key
          | [] -> None);
        (match !current with
        | Some key -> if not (Hashtbl.mem sections key) then Hashtbl.replace sections key []
        | None -> ())
      else
        match !current with
        | Some key ->
            let prev = Hashtbl.find sections key in
            Hashtbl.replace sections key (prev @ [ raw ])
        | None -> ())
    lines;
  sections

(* Per-ABI PAL_CTX_REGS / PAL_CTX_SP / PAL_CTX_PC from pal.h's ladder. *)
type ctx_defines = { regs : int; sp : int; pc : int }

let pal_h_defines pal_h =
  let guard_map = List.map (fun a -> (a.guard, a.key)) arches in
  let sections = split_sections guard_map pal_h in
  let table = Hashtbl.create 8 in
  Hashtbl.iter
    (fun key lines ->
      let get name =
        List.find_map
          (fun raw ->
            let words =
              String.split_on_char ' ' (String.trim raw)
              |> List.filter (fun w -> w <> "")
            in
            match words with
            | "#define" :: def :: value :: _ when def = name ->
                (try Some (int_of_string value) with _ -> None)
            | _ -> None)
          lines
      in
      match (get "PAL_CTX_REGS", get "PAL_CTX_SP", get "PAL_CTX_PC") with
      | Some regs, Some sp, Some pc -> Hashtbl.replace table key { regs; sp; pc }
      | _ -> ())
    sections;
  table

let run_capture prog args =
  let r_fd, w_fd = Unix.pipe () in
  let pid =
    Unix.create_process prog (Array.of_list (prog :: args)) Unix.stdin w_fd
      Unix.stderr
  in
  Unix.close w_fd;
  let ic = Unix.in_channel_of_descr r_fd in
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_string buf (input_line ic);
       Buffer.add_char buf '\n'
     done
   with End_of_file -> ());
  close_in_noerr ic;
  let _, status = Unix.waitpid [] pid in
  let code = match status with Unix.WEXITED c -> c | _ -> 1 in
  (code, Buffer.contents buf)

let () =
  let failures = ref 0 in
  let check name ok =
    Printf.printf "%s: %s\n" name (if ok then "PASS" else "FAIL");
    if not ok then incr failures
  in
  let root = find_repo_root () in
  let asm = read_file (Filename.concat root "runtime/pal_ctx.S") in
  let pal_h = read_file (Filename.concat root "runtime/pal.h") in
  let pal_c = read_file (Filename.concat root "runtime/pal.c") in
  let guard_map = List.map (fun a -> (a.guard, a.key)) arches in
  let sections = split_sections guard_map asm in
  let defines = pal_h_defines pal_h in

  List.iter
    (fun a ->
      let ok =
        match
          (Hashtbl.find_opt sections a.key, Hashtbl.find_opt defines a.key)
        with
        | Some section_lines, Some d ->
            let f = parse_frame section_lines a in
            let regs_ok = d.regs * 8 = f.extent in
            let slots_ok =
              d.sp * 8 = a.sp_off
              && d.pc * 8 = a.pc_off
              && List.mem a.sp_off f.store_offsets
              && List.mem a.pc_off f.store_offsets
              && List.mem a.sp_off f.load_offsets
              && List.mem a.pc_off f.load_offsets
            in
            let fp_ok =
              List.for_all
                (fun r ->
                  List.mem r f.saved_fp && List.mem r f.loaded_fp)
                a.fp_regs
            in
            regs_ok && slots_ok && fp_ok
        | _ -> false
      in
      check ("pal_ctx_abi " ^ a.key) ok)
    arches;

  (* pal_ctx_make must initialize the same slots for every implemented ABI. *)
  let make_body =
    match index_of pal_c "void pal_ctx_make" with
    | Some start -> (
        match index_of (String.sub pal_c start (String.length pal_c - start)) "{" with
        | Some rel_open ->
            let open_brace = start + rel_open in
            let len = String.length pal_c in
            let rec till_close i depth =
              if i >= len then len
              else
                let depth =
                  match pal_c.[i] with
                  | '{' -> depth + 1
                  | '}' -> depth - 1
                  | _ -> depth
                in
                if depth = 0 && i > open_brace then i else till_close (i + 1) depth
            in
            String.sub pal_c start ((till_close open_brace 0) - start)
        | None -> "")
    | None -> ""
  in
  let make_guards_ok =
    List.for_all (fun a -> has_substr ~sub:a.guard make_body) arches
  in
  let make_slots_ok =
    count_substr make_body "regs[PAL_CTX_SP]" >= List.length arches
    && count_substr make_body "regs[PAL_CTX_PC]" >= List.length arches
  in
  let make_fallback_only_abort = count_substr make_body "pal_abort" = 1 in
  check "pal_ctx_make"
    (make_guards_ok && make_slots_ok && make_fallback_only_abort);

  (* Forced-branch probes: every ABI's PalContext must match the assembly
     frame when compiled with that ABI's macros forced, on any host. *)
  with_temp_dir (fun tmp ->
      let probe_src = Filename.concat tmp "probe.c" in
      let probe_obj = Filename.concat tmp "probe.o" in
      let probes_ok = ref true in
      List.iter
        (fun a ->
          let section_lines =
            match Hashtbl.find_opt sections a.key with
            | Some lines -> lines
            | None -> []
          in
          let f = parse_frame section_lines a in
          let body =
            Printf.sprintf
              {|#include "pal.h"
_Static_assert(sizeof(PalContext) == %d, "PalContext must cover the pal_ctx.S frame");
_Static_assert(PAL_CTX_SP * 8 == %d, "PAL_CTX_SP must match the pal_ctx.S sp slot");
_Static_assert(PAL_CTX_PC * 8 == %d, "PAL_CTX_PC must match the pal_ctx.S pc slot");
int probe_unused;
|}
              f.extent a.sp_off a.pc_off
          in
          let oc = open_out probe_src in
          output_string oc body;
          close_out oc;
          let code, out =
            run_capture "cc"
              (a.undefs @ a.defines
              @ [ "-I"; Filename.concat root "runtime"; "-c"; probe_src; "-o";
                  probe_obj ])
          in
          if code <> 0 then begin
            Printf.printf "probe %s: cc rejected the ABI probe\n%s" a.key out;
            probes_ok := false
          end)
        arches;
      check "pal_ctx_abi probes" !probes_ok);

  if !failures > 0 then Printf.printf "pal_ctx_abi_test: %d FAILURES\n" !failures

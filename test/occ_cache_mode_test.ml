let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc content)

let has_substr ~sub s =
  let sl = String.length sub and n = String.length s in
  if sl = 0 then true
  else if sl > n then false
  else
    let rec go i =
      if i > n - sl then false
      else if String.sub s i sl = sub then true
      else go (i + 1)
    in
    go 0

let count_substr ~sub s =
  let sl = String.length sub and n = String.length s in
  if sl = 0 then 0
  else
    let rec go i acc =
      if i > n - sl then acc
      else if String.sub s i sl = sub then go (i + sl) (acc + 1)
      else go (i + 1) acc
    in
    go 0 0

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      Sys.rmdir path
    end else Sys.remove path

let run_capture ?(env = Unix.environment ()) prog args =
  let out_r, out_w = Unix.pipe () in
  let err_r, err_w = Unix.pipe () in
  let pid =
    Unix.create_process_env prog (Array.of_list (prog :: args)) env
      Unix.stdin out_w err_w
  in
  Unix.close out_w;
  Unix.close err_w;
  let drain fd =
    let buf = Buffer.create 256 in
    let chunk = Bytes.create 4096 in
    (try
       while true do
         let n = Unix.read fd chunk 0 (Bytes.length chunk) in
         if n = 0 then raise Exit;
         Buffer.add_subbytes buf chunk 0 n
       done
     with Exit -> ());
    Unix.close fd;
    Buffer.contents buf
  in
  let stdout_s = drain out_r in
  let stderr_s = drain err_r in
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED s | Unix.WSTOPPED s -> 128 + s
  in
  (code, stdout_s, stderr_s)

let env_with ~cache_var ~cache_dir =
  let base =
    Array.to_list (Unix.environment ())
    |> List.filter (fun kv ->
         not (String.starts_with ~prefix:"OCC_CACHE=" kv)
         && not (String.starts_with ~prefix:"OCPKG_CACHE=" kv))
  in
  Array.of_list ((cache_var ^ "=" ^ cache_dir) :: base)

let () =
  let occ = Sys.argv.(1) in
  let qbe = Sys.argv.(2) in
  let _stdlib_sources = Sys.argv.(3) in
  let tmp = Filename.temp_dir "occ-cache-mode-" "" in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    let src_dir = Filename.concat tmp "src" in
    Sys.mkdir src_dir 0o755;

    (* 1. Pipeline / occ compile: Release vs Debug vs Release+g *)
    let dbg_ml = Filename.concat src_dir "dbg_sample.ml" in
    write_file dbg_ml
      {|let[@inline] helper x = x + 1
let f arr i =
  let a = helper i in
  if i >= 0 && i < Array.length arr then arr.(i) + a else a
let () = Printf.printf "%d\n" (f [| 10; 20 |] 1)
|};
    let ssa_rel = Filename.concat tmp "rel.ssa" in
    let c1, _, e1 = run_capture occ [ "compile"; dbg_ml; "-o"; ssa_rel ] in
    assert (c1 = 0 && e1 = "");
    let rel_text = read_file ssa_rel in
    assert (not (has_substr ~sub:"dbgfile" rel_text));
    assert (not (has_substr ~sub:"dbgloc" rel_text));
    assert (count_substr ~sub:"call extern $ocamlcc_Dbg_sample.helper(" rel_text = 1);
    assert (not (has_substr ~sub:"ocamlcc_raise_invalid_arg_oob" rel_text));

    let ssa_dbg = Filename.concat tmp "dbg.ssa" in
    let c2, _, e2 = run_capture occ [ "compile"; "--debug"; dbg_ml; "-o"; ssa_dbg ] in
    assert (c2 = 0 && e2 = "");
    let dbg_text = read_file ssa_dbg in
    assert (has_substr ~sub:("dbgfile \"" ^ String.escaped dbg_ml ^ "\"") dbg_text);
    assert (has_substr ~sub:"dbgloc " dbg_text);
    (* Debug skips inlining helper and bounds elimination *)
    assert (count_substr ~sub:"call extern $ocamlcc_Dbg_sample.helper(" dbg_text = 2);
    assert (has_substr ~sub:"ocamlcc_raise_invalid_arg_oob" dbg_text);

    let ssa_rel_g = Filename.concat tmp "rel_g.ssa" in
    let c3, _, e3 = run_capture occ [ "compile"; "--release"; "-g"; dbg_ml; "-o"; ssa_rel_g ] in
    assert (c3 = 0 && e3 = "");
    let rel_g_text = read_file ssa_rel_g in
    assert (has_substr ~sub:"dbgfile " rel_g_text);
    assert (has_substr ~sub:"dbgloc " rel_g_text);

    (* 2. occ build -S --debug emits .file and .loc in native assembly *)
    let asm_dbg = Filename.concat tmp "dbg.s" in
    let c_asm, _, e_asm =
      run_capture occ [ "build"; "-S"; "--debug"; "--qbe"; qbe; dbg_ml; "-o"; asm_dbg ]
    in
    assert (c_asm = 0 && e_asm = "");
    let asm_text = read_file asm_dbg in
    assert (has_substr ~sub:".file " asm_text);
    assert (has_substr ~sub:".loc " asm_text);

    (* 3. occ build caching, header invalidation, --no-cache, and debug/release isolation *)
    let hdr = Filename.concat src_dir "val.h" in
    let c_src = Filename.concat src_dir "native_val.c" in
    let lib_mli = Filename.concat src_dir "mylib.mli" in
    let lib_ml = Filename.concat src_dir "mylib.ml" in
    let app_ml = Filename.concat src_dir "app.ml" in
    write_file hdr "#define C_CONST 10\n";
    write_file c_src
      {|#include <stdint.h>
#include "val.h"
int64_t get_c_val(int64_t u) { (void)u; return (int64_t)((C_CONST << 1) | 1); }
|};
    write_file lib_mli "val get : unit -> int\n";
    write_file lib_ml
      {|external c_val : unit -> int = "get_c_val"
let get () = c_val () + 5
|};
    write_file app_ml "let () = Printf.printf \"res=%d\\n\" (Mylib.get ())\n";

    let cache = Filename.concat tmp "shared_cache" in
    let exe_rel1 = Filename.concat tmp "app_rel1" in
    let env = env_with ~cache_var:"OCPKG_CACHE" ~cache_dir:cache in
    let base_args = [ "build"; "--qbe"; qbe; "-v"; app_ml; lib_ml; lib_mli; c_src ] in

    (* Cold Release build: 3 OCaml steps + 1 entry = 4 compiled, 0 cached *)
    let rc, _, err1 = run_capture ~env occ (base_args @ [ "-o"; exe_rel1 ]) in
    assert (rc = 0);
    assert (has_substr ~sub:"occ: 4 compiled, 0 cached" err1);
    let rc_run, out_run, _ = run_capture exe_rel1 [] in
    assert (rc_run = 0 && out_run = "res=15\n");
    assert (Sys.file_exists (Filename.concat cache "occ-unit"));
    assert (Sys.file_exists (Filename.concat cache "occ-obj"));
    assert (Sys.file_exists (Filename.concat cache "occ-c"));

    (* Warm Release build: 0 compiled, 4 cached *)
    let exe_rel2 = Filename.concat tmp "app_rel2" in
    let rc2, _, err2 = run_capture ~env occ (base_args @ [ "-o"; exe_rel2 ]) in
    assert (rc2 = 0);
    assert (has_substr ~sub:"occ: 0 compiled, 4 cached" err2);
    let rc_run2, out_run2, _ = run_capture exe_rel2 [] in
    assert (rc_run2 = 0 && out_run2 = "res=15\n");

    (* Debug build uses separate cache entries and does not clobber Release *)
    let exe_dbg1 = Filename.concat tmp "app_dbg1" in
    let rcd1, _, err_d1 =
      run_capture ~env occ (base_args @ [ "--debug"; "-o"; exe_dbg1 ])
    in
    assert (rcd1 = 0);
    assert (has_substr ~sub:"occ: 4 compiled, 0 cached" err_d1);
    let rc_rd1, out_rd1, _ = run_capture exe_dbg1 [] in
    assert (rc_rd1 = 0 && out_rd1 = "res=15\n");
    assert (Sys.file_exists (Filename.concat cache "stdlib"));
    assert (Sys.file_exists (Filename.concat cache "runtime"));

    let exe_dbg2 = Filename.concat tmp "app_dbg2" in
    let rcd2, _, err_d2 =
      run_capture ~env occ (base_args @ [ "--debug"; "-o"; exe_dbg2 ])
    in
    assert (rcd2 = 0);
    assert (has_substr ~sub:"occ: 0 compiled, 4 cached" err_d2);

    (* Release still hits cache cleanly! *)
    let exe_rel3 = Filename.concat tmp "app_rel3" in
    let rcr3, _, err_r3 = run_capture ~env occ (base_args @ [ "-o"; exe_rel3 ]) in
    assert (rcr3 = 0);
    assert (has_substr ~sub:"occ: 0 compiled, 4 cached" err_r3);

    (* Header edit invalidates C compilation *)
    write_file hdr "#define C_CONST 20\n";
    let exe_hdr = Filename.concat tmp "app_hdr" in
    let rch, _, _ = run_capture ~env occ (base_args @ [ "-o"; exe_hdr ]) in
    assert (rch = 0);
    let rc_rh, out_rh, _ = run_capture exe_hdr [] in
    assert (rc_rh = 0 && out_rh = "res=25\n");

    (* OCaml edit invalidates mylib.ml and app.ml cleanly *)
    write_file lib_ml
      {|external c_val : unit -> int = "get_c_val"
let get () = c_val () + 7
|};
    let exe_ml = Filename.concat tmp "app_ml" in
    let rcm, _, err_m = run_capture ~env occ (base_args @ [ "-o"; exe_ml ]) in
    assert (rcm = 0);
    assert (has_substr ~sub:"occ: 1 compiled, 3 cached" err_m);
    let rc_rm, out_rm, _ = run_capture exe_ml [] in
    assert (rc_rm = 0 && out_rm = "res=27\n");

    (* --no-cache bypasses reading/writing *)
    let exe_nc = Filename.concat tmp "app_nc" in
    let rcn, _, err_nc =
      run_capture ~env occ (base_args @ [ "--no-cache"; "-o"; exe_nc ])
    in
    assert (rcn = 0);
    assert (has_substr ~sub:"occ: 4 compiled, 0 cached" err_nc);
    let rc_rn, out_rn, _ = run_capture exe_nc [] in
    assert (rc_rn = 0 && out_rn = "res=27\n"));
  print_endline "occ cache and debug/release mode: PASS"

(* Tests for single-binary Driver (dependency sorting, targets, exe/lib builds,
   cross-target QBE asm, and main_entry.o exclusion on library targets). *)

let has_substr ~sub s =
  let sl = String.length sub in
  let n = String.length s in
  if sl = 0 then true
  else if sl > n then false
  else
    let rec go i =
      if i > n - sl then false
      else if String.sub s i sl = sub then true
      else go (i + 1)
    in
    go 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

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
  let code =
    match status with Unix.WEXITED c -> c | Unix.WSIGNALED s -> 128 + s | Unix.WSTOPPED s -> 128 + s
  in
  (code, Buffer.contents buf)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter
        (fun e -> rm_rf (Filename.concat path e))
        (Sys.readdir path);
      Sys.rmdir path
    end
    else Sys.remove path

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base (Printf.sprintf "ocamlcc_driver_%d" (Unix.getpid ()))
  in
  if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let find_repo_root () =
  let rec up dir =
    if
      Sys.file_exists (Filename.concat dir "dune-project")
      && Sys.file_exists (Filename.concat dir "runtime/arc.c")
    then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then failwith "cannot find repo root" else up parent
  in
  up (Sys.getcwd ())

let () =
  let failures = ref 0 in
  let check name ok =
    Printf.printf "%s: %s\n" name (if ok then "PASS" else "FAIL");
    if not ok then incr failures
  in
  let root = find_repo_root () in
  let qbe =
    if Array.length Sys.argv > 1 then Unix.realpath Sys.argv.(1)
    else Filename.concat root "build/qbe/qbe"
  in
  let runtime_dir = Filename.concat root "runtime" in
  let stdlib_src_dir = Filename.concat root "stdlib" in
  let stdlib_build_dir = Filename.concat root "build/stdlib" in
  let rt_build_dir = Filename.concat root "build/rt" in

  (* 1. Target parsing *)
  let targets_ok =
    List.for_all
      (fun t ->
        match Driver.resolve_target t with Ok _ -> true | Error _ -> false)
      [ "host"; "arm64_apple"; "arm64"; "amd64_sysv"; "rv64"; "ios-arm64";
        "ios-sim-arm64"; "android-arm64" ]
    &&
    match Driver.resolve_target "bogus-arch" with
    | Error _ -> true
    | Ok _ -> false
  in
  check "target resolution" targets_ok;

  (* 2. Out-of-order dependency resolution *)
  let mod_main_ml = Filename.concat root "examples/mod_main.ml" in
  let mod_lib_ml = Filename.concat root "examples/mod_lib.ml" in
  let mod_lib_mli = Filename.concat root "examples/mod_lib.mli" in
  (match Driver.plan_build_order [ mod_main_ml; mod_lib_ml; mod_lib_mli ] with
  | Error msg ->
      Printf.printf "dep order error: %s\n" msg;
      check "dependency ordering" false
  | Ok steps ->
      let names =
        List.map
          (fun (s : Driver.build_step) ->
            let ext = match s.kind with `Mli -> ".mli" | `Ml -> ".ml" in
            s.modname ^ ext)
          steps
      in
      check "dependency ordering"
        (names = [ "Mod_lib.mli"; "Mod_lib.ml"; "Mod_main.ml" ]));

  (* 3. Full driver builds inside temp dir *)
  with_temp_dir (fun tmp ->
      let write_tmp name content =
        let p = Filename.concat tmp name in
        let oc = open_out_bin p in
        output_string oc content;
        close_out oc;
        p
      in
      (* 3a. Multi-module executable (inputs reversed) *)
      let exe_out = Filename.concat tmp "mod_app" in
      let base_cfg =
        { (Driver.default_config ()) with
          qbe_path = Some qbe;
          runtime_dir = Some runtime_dir;
          prebuilt_rt_dir = Some rt_build_dir;
          stdlib_src_dir = Some stdlib_src_dir;
          prebuilt_stdlib_dir = Some stdlib_build_dir }
      in
      (match
         Driver.build
           { base_cfg with
             inputs = [ mod_main_ml; mod_lib_ml; mod_lib_mli ];
             output = Some exe_out;
             work_dir = Some (Filename.concat tmp "work_exe") }
       with
      | Error msg ->
          Printf.printf "exe build error: %s\n" msg;
          check "exe build" false
      | Ok _ ->
          let code, out = run_capture exe_out [] in
          let expected =
            read_file (Filename.concat root "tests/mod_main.expected")
          in
          check "exe build" (code = 0 && out = expected));

      let registry = write_tmp "registry.ml" "let count = ref 0" in
      let plugin = write_tmp "plugin.ml" "let () = incr Registry.count" in
      let entry = write_tmp "entry.ml" "let () = print_int !Registry.count" in
      let registration = Filename.concat tmp "registration" in
      (match Driver.build
               { base_cfg with inputs = [registry; plugin; entry];
                 output = Some registration }
       with
       | Error msg -> failwith msg
       | Ok exe ->
           check "linked registration runs once" (run_capture exe [] = (0, "1\n")));

      (* 3a'. Default nostdlib=false uses ocamlcc stdlib.cmi (List/Array/Option/Printf) *)
      let std_app_ml =
        write_tmp "std_app.ml"
          {|
let () =
  let xs = List.map (fun x -> x * 2) [ 1; 2; 3 ] in
  let arr = [| 10; 20; 30; 40 |] in
  let o = Option.value ~default:0 (Some 7) in
  let s = Printf.sprintf "sum=%d arr=%d opt=%d"
    (List.fold_left ( + ) 0 xs) (Array.length arr) o in
  print_endline s
|}
      in
      let std_app_out = Filename.concat tmp "std_app" in
      (match
         Driver.build
           { base_cfg with
             inputs = [ std_app_ml ];
             output = Some std_app_out;
             work_dir = Some (Filename.concat tmp "work_std_app") }
       with
      | Error msg ->
          Printf.printf "default stdlib cmi error: %s\n" msg;
          check "default stdlib cmi" false
      | Ok _ ->
          let code, out = run_capture std_app_out [] in
          check "default stdlib cmi"
            (code = 0 && out = "sum=12 arr=4 opt=7\n"));

      (* 3a''. Fallback without prebuilt stdlib dir compiles stdlib.cmi before user *)
      let fb_app_ml =
        write_tmp "fb_app.ml"
          {|
let () =
  let tot = List.fold_left ( + ) 0 [ 4; 5; 6 ] in
  let v = Option.value ~default:0 (Option.map (fun x -> x + 1) (Some 9)) in
  print_endline (Printf.sprintf "tot=%d v=%d" tot v)
|}
      in
      let fb_app_out = Filename.concat tmp "fb_app" in
      (match
         Driver.build
           { base_cfg with
             prebuilt_stdlib_dir = Some (Filename.concat tmp "no_prebuilt_stdlib");
             inputs = [ fb_app_ml ];
             output = Some fb_app_out;
             work_dir = Some (Filename.concat tmp "work_fb_app") }
       with
      | Error msg ->
          Printf.printf "stdlib fallback cmi error: %s\n" msg;
          check "stdlib fallback cmi" false
      | Ok _ ->
          let code, out = run_capture fb_app_out [] in
          check "stdlib fallback cmi" (code = 0 && out = "tot=15 v=10\n"));

      (* 3b. Shared library + --emit-header + C host (verifying no main_entry.o & hidden runtime) *)
      let bindgen_mli = Filename.concat root "examples/bindgen_lib.mli" in
      let bindgen_ml = Filename.concat root "examples/bindgen_lib.ml" in
      let is_darwin =
        let _, u = run_capture "uname" [ "-s" ] in
        String.trim u = "Darwin"
      in
      let shared_ext = if is_darwin then ".dylib" else ".so" in
      let shared_out = Filename.concat tmp ("libbindgen" ^ shared_ext) in
      let hdr_out = Filename.concat tmp "bindgen_lib.h" in
      let shared_host_c =
        write_tmp "shared_host.c"
          {|
#include "bindgen_lib.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    bindgen_lib_init();
    ocamlcc_error_t err = {0};
    bindgen_lib_t_t h = bindgen_lib_create(42, &err);
    int64_t hv1 = bindgen_lib_get(h, &err);
    int64_t hv2 = bindgen_lib_get(h, &err);
    bindgen_lib_t_t_release(h);
    bindgen_lib_point_t p3 = bindgen_lib_add_pt(
        (bindgen_lib_point_t){ 1.5, 2.25 },
        (bindgen_lib_point_t){ 3.0, 4.75 }, &err);
    char *g = bindgen_lib_greet((bindgen_lib_user_t){ "Alice", 25 }, &err);
    ocamlcc_opt_int64_t o1 = bindgen_lib_opt_inc((ocamlcc_opt_int64_t){ true, 9 }, &err);
    ocamlcc_opt_int64_t o2 = bindgen_lib_opt_inc((ocamlcc_opt_int64_t){ false, 0 }, &err);
    bool b1 = bindgen_lib_flip(false, &err);
    int64_t s64 = bindgen_lib_sum_i32_i64(100, 20000000000LL, &err);
    int64_t psum = bindgen_lib_pair_sum((ocamlcc_tuple_int64_t_int64_t){ 7, 8 }, &err);
    int64_t ok_v = bindgen_lib_check_pos(5, &err);
    int err0 = err.code;
    int64_t bad_v = bindgen_lib_check_pos(-13, &err);
    int err1 = err.code;
    int err_msg_ok = (strstr(err.message, "Bad_arg(13)") != NULL) ? 1 : 0;
    printf("h=%lld,%lld pt=%.1f,%.1f greet=%s opt=%d:%lld,%d b=%d i64=%lld pair=%lld exn=%d:%lld,%d:%lld:%d\n",
           (long long)hv1, (long long)hv2, p3.x, p3.y, g,
           o1.is_some ? 1 : 0, (long long)o1.value, o2.is_some ? 1 : 0,
           b1 ? 1 : 0, (long long)s64, (long long)psum,
           err0, (long long)ok_v, err1, (long long)bad_v, err_msg_ok);
    ocamlcc_free_string(g);
    return 0;
}
|}
      in
      let nm_exported path =
        if is_darwin then run_capture "nm" [ "-gU"; path ]
        else run_capture "nm" [ "-D"; "--defined-only"; path ]
      in
      (match
         Driver.build
           { base_cfg with
             inputs = [ bindgen_ml; bindgen_mli ];
             kind = Some Driver.Kind_shared;
             emit_header = Some hdr_out;
             output = Some shared_out;
             work_dir = Some (Filename.concat tmp "work_shared") }
       with
      | Error msg ->
          Printf.printf "shared build error: %s\n" msg;
          check "shared library + header" false
      | Ok _ ->
          let _nm_code, nm_out = nm_exported shared_out in
          let no_main =
            not
              (has_substr ~sub:" _main\n" nm_out
              || has_substr ~sub:" T main\n" nm_out
              || has_substr ~sub:" T _main\n" nm_out)
          in
          let rt_hidden =
            (not (has_substr ~sub:"arc_alloc" nm_out))
            && (not (has_substr ~sub:"ocamlcc_init_Stdlib" nm_out))
            && (not (has_substr ~sub:"ocamlcc_global_Stdlib" nm_out))
            && has_substr ~sub:"bindgen_lib_init" nm_out
            && has_substr ~sub:"bindgen_lib_create" nm_out
          in
          let host_bin = Filename.concat tmp "host_app" in
          let cc_code, cc_out =
            run_capture "cc"
              [ "-std=c99"; "-Wall"; "-Wextra"; "-Werror"; "-I" ^ tmp;
                shared_host_c; shared_out; "-Wl,-rpath," ^ tmp; "-lm"; "-o";
                host_bin ]
          in
          if cc_code <> 0 then begin
            Printf.printf "host link failed: %s\n" cc_out;
            check "shared library + header" false
          end
          else
            let rcode, rout = run_capture host_bin [] in
            check "shared library + header"
              (no_main && rt_hidden && rcode = 0
              && rout
                 = "h=42,42 pt=4.5,7.0 greet=Hello, Alice opt=1:10,0 b=1 i64=20000000100 pair=15 exn=0:50,1:0:1\n"));

      (* 3c. Static library (verifying no main_entry.o) *)
      let static_out = Filename.concat tmp "libmod_lib.a" in
      (match
         Driver.build
           { base_cfg with
             inputs = [ mod_lib_mli; mod_lib_ml ];
             kind = Some Driver.Kind_static;
             output = Some static_out;
             work_dir = Some (Filename.concat tmp "work_static") }
       with
      | Error msg ->
          Printf.printf "static build error: %s\n" msg;
          check "static library no main" false
      | Ok _ ->
          let _nm_code, nm_out = run_capture "nm" [ static_out ] in
          let no_main =
            not
              (has_substr ~sub:"main_entry.o" nm_out
              || has_substr ~sub:" T _main\n" nm_out
              || has_substr ~sub:" T main\n" nm_out)
          in
          check "static library no main" no_main);

      (* 3d. Cross-target QBE assembly emission *)
      let asm_ok =
        List.for_all
          (fun (tname, needle) ->
            let out_s = Filename.concat tmp (tname ^ ".s") in
            match
              Driver.build
                { base_cfg with
                  target = Some tname;
                  inputs = [ mod_lib_mli; mod_lib_ml ];
                  kind = Some Driver.Kind_asm;
                  output = Some out_s;
                  work_dir = Some (Filename.concat tmp ("work_" ^ tname)) }
            with
            | Ok _ ->
                let s = read_file out_s in
                has_substr ~sub:needle s
            | Error msg ->
                Printf.printf "asm %s error: %s\n" tname msg;
                false)
          [ ("arm64_apple", "_ocamlcc_init_Mod_lib");
            ("arm64", "ocamlcc_init_Mod_lib");
            ("amd64_sysv", "ocamlcc_init_Mod_lib");
            ("rv64", "ocamlcc_init_Mod_lib") ]
      in
      check "cross-target asm emission" asm_ok;

      (* 3e. Multi-threaded C_bindgen shim + concurrent ocamlcc_arc_collect *)
      let mt_host_c =
        write_tmp "mt_bindgen_host.c"
          {|
#include "bindgen_lib.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>

extern int64_t ocamlcc_arc_collect(int64_t unit);

typedef struct {
    int tid;
    int ok;
} mt_arg_t;

static void *worker(void *p) {
    mt_arg_t *arg = (mt_arg_t *)p;
    int ok = 1;
    ocamlcc_error_t err = {0};
    for (int i = 0; i < 150; i++) {
        int64_t v = (int64_t)(arg->tid * 1000 + i);
        bindgen_lib_t_t h = bindgen_lib_create(v, &err);
        if (err.code != 0 || bindgen_lib_get(h, &err) != v) { ok = 0; }
        bindgen_lib_t_t_retain(h);
        bindgen_lib_t_t_release(h);
        bindgen_lib_t_t_release(h);
        bindgen_lib_user_t u = { "Bob", 20 + (i % 5) };
        char *g = bindgen_lib_greet(u, &err);
        if (err.code != 0 || g == NULL) { ok = 0; }
        ocamlcc_free_string(g);
        ocamlcc_opt_int64_t o = bindgen_lib_opt_inc((ocamlcc_opt_int64_t){ true, v }, &err);
        if (err.code != 0 || !o.is_some || o.value != v + 1) { ok = 0; }
        int64_t ps = bindgen_lib_pair_sum((ocamlcc_tuple_int64_t_int64_t){ v, 5 }, &err);
        if (err.code != 0 || ps != v + 5) { ok = 0; }
        if (!ok) break;
    }
    arg->ok = ok;
    return NULL;
}

static void *collector(void *p) {
    _Atomic int *stop = (_Atomic int *)p;
    while (atomic_load_explicit(stop, memory_order_acquire) == 0) {
        ocamlcc_arc_collect(1);
    }
    return NULL;
}

int main(void) {
    bindgen_lib_init();
    _Atomic int stop = 0;
    pthread_t col;
    if (pthread_create(&col, NULL, collector, &stop) != 0) return 2;
    pthread_t th[4];
    mt_arg_t args[4];
    for (int i = 0; i < 4; i++) {
        args[i].tid = i;
        args[i].ok = 0;
        if (pthread_create(&th[i], NULL, worker, &args[i]) != 0) return 2;
    }
    int ok = 1;
    for (int i = 0; i < 4; i++) {
        pthread_join(th[i], NULL);
        if (!args[i].ok) ok = 0;
    }
    atomic_store_explicit(&stop, 1, memory_order_release);
    pthread_join(col, NULL);
    printf("mt_bindgen=%s\n", ok ? "ok" : "fail");
    return ok ? 0 : 1;
}
|}
      in
      let mt_hdr = Filename.concat tmp "mt_hdr/bindgen_lib.h" in
      let mt_exe = Filename.concat tmp "mt_bindgen_app" in
      (match
         Driver.build
           { base_cfg with
             inputs = [ bindgen_mli; bindgen_ml; mt_host_c ];
             no_main = true;
             emit_header = Some mt_hdr;
             extra_cflags = [ "-pthread" ];
             extra_ldflags = [ "-pthread" ];
             output = Some mt_exe;
             work_dir = Some (Filename.concat tmp "work_mt_bindgen") }
       with
      | Error msg ->
          Printf.printf "mt bindgen error: %s\n" msg;
          check "mt bindgen mutator gate" false
      | Ok _ ->
          let code, out = run_capture mt_exe [] in
          check "mt bindgen mutator gate" (code = 0 && out = "mt_bindgen=ok\n"));

      (* 3f. .mli-mediated mutually dependent implementations + true cycle rejection *)
      let mut_a_mli =
        write_tmp "mut_a.mli"
          "val even : int -> bool\nval odd_from_b : int -> bool\n"
      in
      let mut_b_mli =
        write_tmp "mut_b.mli" "val odd : int -> bool\n"
      in
      let mut_a_ml =
        write_tmp "mut_a.ml"
          "let even n = if n = 0 then true else Mut_b.odd (n - 1)\nlet odd_from_b n = Mut_b.odd n\n"
      in
      let mut_b_ml =
        write_tmp "mut_b.ml"
          "let odd n = if n = 0 then false else Mut_a.even (n - 1)\n"
      in
      let mut_main_ml =
        write_tmp "mut_main.ml"
          "let () = print_endline (Printf.sprintf \"e6=%b o7=%b\" (Mut_a.even 6) (Mut_a.odd_from_b 7))\n"
      in
      let cyc_a_ml = write_tmp "cyc_a.ml" "let f x = Cyc_b.g x\n" in
      let cyc_b_ml = write_tmp "cyc_b.ml" "let g x = Cyc_a.f x\n" in
      let cyc_a_mli = write_tmp "cyc_a.mli" "type t = Cyc_b.t\n" in
      let cyc_b_mli = write_tmp "cyc_b.mli" "type t = Cyc_a.t\n" in
      let cyc_rejected =
        (match Driver.plan_build_order [ cyc_a_ml; cyc_b_ml ] with
        | Error _ -> true
        | Ok _ -> false)
        &&
        (match Driver.plan_build_order [ cyc_a_mli; cyc_b_mli ] with
        | Error _ -> true
        | Ok _ -> false)
      in
      let mut_exe = Filename.concat tmp "mut_app" in
      let mut_ok =
        match
          Driver.build
            { base_cfg with
              inputs =
                [ mut_main_ml; mut_a_ml; mut_b_ml; mut_a_mli; mut_b_mli ];
              output = Some mut_exe;
              work_dir = Some (Filename.concat tmp "work_mut") }
        with
        | Error msg ->
            Printf.printf "mli-mediated mutual error: %s\n" msg;
            false
        | Ok _ ->
            let code, out = run_capture mut_exe [] in
            code = 0 && out = "e6=true o7=true\n"
      in
      check "mli-mediated mutual deps" (cyc_rejected && mut_ok);

      (* 3g. Two separate OCaml shared libs in one C host without symbol collision *)
      let lib_a_mli = write_tmp "lib_a.mli" "val tag : string -> string option\n" in
      let lib_a_ml =
        write_tmp "lib_a.ml"
          "let tag s = if String.length s = 0 then None else Some (\"A:\" ^ s)\n"
      in
      let lib_b_mli = write_tmp "lib_b.mli" "val sum_str : int -> string option\n" in
      let lib_b_ml =
        write_tmp "lib_b.ml"
          "let sum_str n = if n <= 0 then None else Some (Printf.sprintf \"B:%d\" (List.fold_left ( + ) 0 [ n; 1; 2 ]))\n"
      in
      let so_a = Filename.concat tmp ("liba" ^ shared_ext) in
      let so_b = Filename.concat tmp ("libb" ^ shared_ext) in
      let hdr_a = Filename.concat tmp "a_api.h" in
      let hdr_b = Filename.concat tmp "b_api.h" in
      let two_libs_ok =
        match
          ( Driver.build
              { base_cfg with
                inputs = [ lib_a_mli; lib_a_ml ];
                kind = Some Driver.Kind_shared;
                emit_header = Some hdr_a;
                output = Some so_a;
                work_dir = Some (Filename.concat tmp "work_lib_a") },
            Driver.build
              { base_cfg with
                inputs = [ lib_b_mli; lib_b_ml ];
                kind = Some Driver.Kind_shared;
                emit_header = Some hdr_b;
                output = Some so_b;
                work_dir = Some (Filename.concat tmp "work_lib_b") } )
        with
        | Ok _, Ok _ ->
            let _, nma = nm_exported so_a in
            let _, nmb = nm_exported so_b in
            let syms_ok =
              (not (has_substr ~sub:"arc_alloc" nma))
              && (not (has_substr ~sub:"ocamlcc_init_Stdlib" nma))
              && (not (has_substr ~sub:"arc_alloc" nmb))
              && not (has_substr ~sub:"ocamlcc_init_Stdlib" nmb)
            in
            let two_host =
              write_tmp "two_so_host.c"
                {|
#include "a_api.h"
#include "b_api.h"
#include <stdio.h>

int main(void) {
    lib_a_init();
    lib_b_init();
    ocamlcc_error_t err = {0};
    ocamlcc_opt_cstr_t a = lib_a_tag("hi", &err);
    ocamlcc_opt_cstr_t b = lib_b_sum_str(10, &err);
    printf("a=%s b=%s\n", a.is_some ? a.value : "none", b.is_some ? b.value : "none");
    ocamlcc_opt_cstr_t_free(&a);
    ocamlcc_opt_cstr_t_free(&b);
    return 0;
}
|}
            in
            let two_bin = Filename.concat tmp "two_so_app" in
            let cc_code, cc_out =
              run_capture "cc"
                [ "-std=c99"; "-Wall"; "-Wextra"; "-Werror"; "-I" ^ tmp;
                  two_host; so_a; so_b; "-Wl,-rpath," ^ tmp; "-lm"; "-o";
                  two_bin ]
            in
            if cc_code <> 0 then begin
              Printf.printf "two shared link failed: %s\n" cc_out;
              false
            end
            else
              let rcode, rout = run_capture two_bin [] in
              if not (syms_ok && rcode = 0 && rout = "a=A:hi b=B:13\n") then
                Printf.printf "two_libs diag: syms=%b rcode=%d rout=%S\n"
                  syms_ok rcode rout;
              syms_ok && rcode = 0 && rout = "a=A:hi b=B:13\n"
        | Error m, _ | _, Error m ->
            Printf.printf "two shared build failed: %s\n" m;
            false
      in
      let no_hdr_so = Filename.concat tmp ("libmod_nohdr" ^ shared_ext) in
      let no_hdr_hidden =
        match
          Driver.build
            { base_cfg with
              inputs = [ mod_lib_mli; mod_lib_ml ];
              kind = Some Driver.Kind_shared;
              output = Some no_hdr_so;
              work_dir = Some (Filename.concat tmp "work_nohdr_so") }
        with
        | Error m ->
            Printf.printf "no_hdr_so build failed: %s\n" m;
            false
        | Ok _ ->
            let _, nm_o = nm_exported no_hdr_so in
            let ok =
              (not (has_substr ~sub:"arc_alloc" nm_o))
              && (not (has_substr ~sub:"ocamlcc_init_Stdlib" nm_o))
              && has_substr ~sub:"ocamlcc_init_Mod_lib" nm_o
            in
            if not ok then Printf.printf "no_hdr_hidden nm:\n%s\n" nm_o;
            ok
      in
      check "two shared libs no collision" (two_libs_ok && no_hdr_hidden);

      (* 3h. Multi-.mli --emit-header respects basename and writes umbrella header *)
      let sdk_dir = Filename.concat tmp "sdk_hdrs" in
      let sdk_hdr = Filename.concat sdk_dir "my_sdk.h" in
      let sdk_so = Filename.concat tmp ("libmy_sdk" ^ shared_ext) in
      let multi_hdr_ok =
        match
          Driver.build
            { base_cfg with
              inputs = [ lib_a_mli; lib_a_ml; lib_b_mli; lib_b_ml ];
              kind = Some Driver.Kind_shared;
              emit_header = Some sdk_hdr;
              output = Some sdk_so;
              work_dir = Some (Filename.concat tmp "work_multi_sdk") }
        with
        | Error msg ->
            Printf.printf "multi mli build failed: %s\n" msg;
            false
        | Ok _ ->
            let files_exist =
              Sys.file_exists sdk_hdr
              && Sys.file_exists (Filename.concat sdk_dir "my_sdk_lib_a.h")
              && Sys.file_exists (Filename.concat sdk_dir "my_sdk_lib_b.h")
            in
            let sdk_host =
              write_tmp "sdk_host.c"
                {|
#include "my_sdk.h"
#include <stdio.h>

int main(void) {
    lib_a_init();
    lib_b_init();
    ocamlcc_error_t err = {0};
    ocamlcc_opt_cstr_t a = lib_a_tag("ok", &err);
    ocamlcc_opt_cstr_t b = lib_b_sum_str(5, &err);
    printf("sdk=%s/%s\n", a.value, b.value);
    ocamlcc_opt_cstr_t_free(&a);
    ocamlcc_opt_cstr_t_free(&b);
    return 0;
}
|}
            in
            let sdk_bin = Filename.concat tmp "sdk_app" in
            let cc_code, cc_out =
              run_capture "cc"
                [ "-std=c99"; "-Wall"; "-Wextra"; "-Werror"; "-I" ^ sdk_dir;
                  sdk_host; sdk_so; "-Wl,-rpath," ^ tmp; "-lm"; "-o"; sdk_bin ]
            in
            if cc_code <> 0 then begin
              Printf.printf "sdk host link failed: %s\n" cc_out;
              false
            end
            else
              let rcode, rout = run_capture sdk_bin [] in
              files_exist && rcode = 0 && rout = "sdk=A:ok/B:8\n"
      in
      check "multi-mli emit-header naming" multi_hdr_ok;

      (* 3i. ios-xcframework without .mli does not force --emit-header *)
      let ml_only = write_tmp "xcf_only.ml" "let id x = x + 1\n" in
      let explicit_err_ok =
        match
          Driver.build
            { base_cfg with
              target = Some "ios-xcframework";
              inputs = [ ml_only ];
              emit_header = Some (Filename.concat tmp "req.h");
              output = Some (Filename.concat tmp "Req.xcframework");
              work_dir = Some (Filename.concat tmp "work_xcf_req") }
        with
        | Error msg -> has_substr ~sub:"--emit-header requires at least one .mli" msg
        | Ok _ -> false
      in
      let has_ios_sdk =
        is_darwin
        &&
        let c1, _ = run_capture "xcrun" [ "--sdk"; "iphoneos"; "--show-sdk-path" ] in
        let c2, _ = run_capture "xcrun" [ "--sdk"; "iphonesimulator"; "--show-sdk-path" ] in
        c1 = 0 && c2 = 0
      in
      let xcf_out = Filename.concat tmp "Plain.xcframework" in
      let no_hdr_xcf_ok =
        match
          Driver.build
            { base_cfg with
              target = Some "ios-xcframework";
              inputs = [ ml_only ];
              output = Some xcf_out;
              work_dir = Some (Filename.concat tmp "work_xcf_plain") }
        with
        | Ok p -> Sys.file_exists p
        | Error msg ->
            (not has_ios_sdk)
            && not (has_substr ~sub:"--emit-header requires at least one .mli" msg)
      in
      check "ios-xcframework without mli" (explicit_err_ok && no_hdr_xcf_ok));

  exit (if !failures = 0 then 0 else 1)

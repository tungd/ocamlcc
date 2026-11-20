(* Single-binary build driver: dependency-ordered .mli/.ml compilation,
   QBE target assembly, C/NDK/xcrun toolchain invocation, optional C header +
   FFI shim generation, and runtime/stdlib linking. *)

type target_os =
  | Darwin
  | Linux
  | Ios
  | Ios_sim
  | Android
  | Windows

type target_spec = {
  name : string;
  qbe_target : string;
  os : target_os;
  arch : string;
}

type output_kind =
  | Kind_exe
  | Kind_shared
  | Kind_static
  | Kind_obj
  | Kind_asm
  | Kind_xcframework

type build_step = {
  modname : string;
  kind : [ `Mli | `Ml ];
  path : string;
}

type config = {
  inputs : string list;
  output : string option;
  target : string option;
  kind : output_kind option;
  include_dirs : string list;
  nostdlib : bool;
  nopervasives : bool;
  no_main : bool;
  emit_header : string option;
  qbe_path : string option;
  cc_path : string option;
  ar_path : string option;
  sysroot : string option;
  runtime_dir : string option;
  prebuilt_rt_dir : string option;
  inline_single_thread_rc : bool;
  stdlib_src_dir : string option;
  prebuilt_stdlib_dir : string option;
  work_dir : string option;
  extra_cflags : string list;
  extra_ldflags : string list;
  verbose : bool;
}

let default_config () =
  { inputs = [];
    output = None;
    target = None;
    kind = None;
    include_dirs = [];
    nostdlib = false;
    nopervasives = false;
    no_main = false;
    emit_header = None;
    qbe_path = None;
    cc_path = None;
    ar_path = None;
    sysroot = None;
    runtime_dir = None;
    prebuilt_rt_dir = None;
    inline_single_thread_rc = false;
    stdlib_src_dir = None;
    prebuilt_stdlib_dir = None;
    work_dir = None;
    extra_cflags = [];
    extra_ldflags = [];
    verbose = false }

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let write_file path data =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc data)

let rec mkdir_p dir =
  if dir <> "" && dir <> "." && not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    try Sys.mkdir dir 0o755 with Sys_error _ -> ()
  end

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let capture_process prog args stream =
  let read_fd, write_fd = Unix.pipe ~cloexec:true () in
  let stdout, stderr =
    match stream with
    | `Stdout -> (write_fd, Unix.stderr)
    | `Stderr stdout_fd -> (stdout_fd, write_fd)
  in
  let channel = Unix.in_channel_of_descr read_fd in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      match
        Fun.protect ~finally:(fun () -> Unix.close write_fd) (fun () ->
            Unix.create_process prog (Array.of_list (prog :: args))
              Unix.stdin stdout stderr)
      with
      | exception Unix.Unix_error (err, _, _) ->
          Error (Printf.sprintf "cannot start command `%s`: %s" prog (Unix.error_message err))
      | pid ->
          let output = In_channel.input_all channel in
          let _, status = Unix.waitpid [] pid in
          Ok (status, String.trim output))

let run_cmd ~verbose ?stdout_file prog args =
  if verbose then
    Printf.eprintf "+ %s %s\n%!" prog (String.concat " " args);
  let run stdout_fd = capture_process prog args (`Stderr stdout_fd) in
  let result =
    match stdout_file with
    | None -> run Unix.stdout
    | Some path ->
        let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> run fd)
  in
  match result with
  | Error _ as error -> error
  | Ok (Unix.WEXITED 0, _) -> Ok ()
  | Ok (Unix.WEXITED c, msg) ->
      Error
        (Printf.sprintf "command `%s` exited with %d%s" prog c
           (if msg = "" then "" else ": " ^ msg))
  | Ok ((Unix.WSIGNALED s | Unix.WSTOPPED s), _) ->
      Error (Printf.sprintf "command `%s` terminated by signal %d" prog s)

let capture_cmd prog args =
  match capture_process prog args `Stdout with
  | Error _ as error -> error
  | Ok (Unix.WEXITED 0, output) -> Ok output
  | Ok _ -> Error (Printf.sprintf "command `%s` failed" prog)

let detect_host_target () : target_spec =
  let os_s = match capture_cmd "uname" [ "-s" ] with Ok s -> s | Error _ -> "Linux" in
  let arch_s = match capture_cmd "uname" [ "-m" ] with Ok s -> s | Error _ -> "x86_64" in
  match (os_s, arch_s) with
  | "Darwin", ("arm64" | "aarch64") ->
      { name = "arm64_apple"; qbe_target = "arm64_apple"; os = Darwin; arch = "arm64" }
  | "Darwin", _ ->
      { name = "amd64_apple"; qbe_target = "amd64_apple"; os = Darwin; arch = "x86_64" }
  | _, ("arm64" | "aarch64") ->
      { name = "arm64"; qbe_target = "arm64"; os = Linux; arch = "arm64" }
  | _, "riscv64" ->
      { name = "rv64"; qbe_target = "rv64"; os = Linux; arch = "riscv64" }
  | _ ->
      { name = "amd64_sysv"; qbe_target = "amd64_sysv"; os = Linux; arch = "x86_64" }

let resolve_target (s : string) : (target_spec, string) result =
  match String.lowercase_ascii (String.trim s) with
  | "host" | "" -> Ok (detect_host_target ())
  | "arm64_apple" | "macos-arm64" ->
      Ok { name = s; qbe_target = "arm64_apple"; os = Darwin; arch = "arm64" }
  | "amd64_apple" | "macos-amd64" ->
      Ok { name = s; qbe_target = "amd64_apple"; os = Darwin; arch = "x86_64" }
  | "arm64" | "linux-arm64" ->
      Ok { name = s; qbe_target = "arm64"; os = Linux; arch = "arm64" }
  | "amd64_sysv" | "linux-amd64" ->
      Ok { name = s; qbe_target = "amd64_sysv"; os = Linux; arch = "x86_64" }
  | "rv64" | "linux-rv64" ->
      Ok { name = s; qbe_target = "rv64"; os = Linux; arch = "riscv64" }
  | "amd64_win" ->
      Ok { name = s; qbe_target = "amd64_win"; os = Windows; arch = "x86_64" }
  | "ios-arm64" ->
      Ok { name = s; qbe_target = "arm64_apple"; os = Ios; arch = "arm64" }
  | "ios-sim-arm64" ->
      Ok { name = s; qbe_target = "arm64_apple"; os = Ios_sim; arch = "arm64" }
  | "ios-xcframework" ->
      Ok { name = s; qbe_target = "arm64_apple"; os = Ios; arch = "arm64" }
  | "android-arm64" ->
      Ok { name = s; qbe_target = "arm64"; os = Android; arch = "arm64" }
  | "android-x86_64" ->
      Ok { name = s; qbe_target = "amd64_sysv"; os = Android; arch = "x86_64" }
  | other -> Error ("unsupported target: " ^ other)

let find_in_path exe =
  let path_var = try Sys.getenv "PATH" with Not_found -> "" in
  let dirs = String.split_on_char ':' path_var in
  List.find_map
    (fun d ->
      let p = Filename.concat d exe in
      if Sys.file_exists p && not (Sys.is_directory p) then Some p else None)
    dirs

(* The private backend, target runtime and core library share one Dune
   package directory, relative to the installed executable. *)
let installed_toolchain () =
  let exe = Sys.executable_name in
  let exe =
    if Filename.is_implicit exe then Option.value (find_in_path exe) ~default:exe
    else exe
  in
  let prefix = Filename.dirname (Filename.dirname exe) in
  let dir = Filename.concat prefix "lib/ocamlcc" in
  if Sys.file_exists (Filename.concat dir "qbe") then Some dir else None

let search_upwards rel_path =
  let starts =
    [ Sys.getcwd (); Filename.dirname Sys.executable_name ]
  in
  let rec up dir =
    let cand = Filename.concat dir rel_path in
    if Sys.file_exists cand then Some cand
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else up parent
  in
  List.find_map up starts

let resolve_qbe cfg =
  match cfg.qbe_path with
  | Some p -> Ok p
  | None -> (
      match Sys.getenv_opt "OCAMLCC_QBE" with
      | Some p when Sys.file_exists p -> Ok p
      | _ -> (match installed_toolchain () with
        | Some dir -> Ok (Filename.concat dir "qbe")
        | None ->
          let sibling =
            Filename.concat
              (Filename.dirname (Filename.dirname Sys.executable_name))
              "qbe/qbe"
          in
          if Sys.file_exists sibling then Ok sibling
          else
            match search_upwards "build/qbe/qbe" with
            | Some p -> Ok p
            | None -> (
                match find_in_path "qbe" with
                | Some p -> Ok p
                | None ->
                    Error "cannot locate qbe binary (pass --qbe or set OCAMLCC_QBE)")))

let resolve_runtime_dir cfg =
  match cfg.runtime_dir with
  | Some d -> Some d
  | None -> (
      match Sys.getenv_opt "OCAMLCC_RUNTIME_DIR" with
      | Some d when Sys.file_exists d -> Some d
      | _ -> (match installed_toolchain () with
              | Some dir -> Some (Filename.concat dir "runtime")
              | None -> search_upwards "runtime"))

let resolve_prebuilt_rt_dir cfg =
  match cfg.prebuilt_rt_dir with
  | Some d -> Some d
  | None when Option.is_some (installed_toolchain ()) -> None
  | None ->
      let sibling =
        Filename.concat
          (Filename.dirname (Filename.dirname Sys.executable_name))
          "rt"
      in
      if Sys.file_exists sibling then Some sibling
      else search_upwards "build/rt"

let resolve_stdlib_src_dir cfg =
  match cfg.stdlib_src_dir with
  | Some d -> Some d
  | None -> (
      match Sys.getenv_opt "OCAMLCC_STDLIB_DIR" with
      | Some d when Sys.file_exists d -> Some d
      | _ -> (match installed_toolchain () with
              | Some dir -> Some (Filename.concat dir "stdlib")
              | None -> search_upwards "stdlib"))

let resolve_prebuilt_stdlib_dir cfg =
  match cfg.prebuilt_stdlib_dir with
  | Some d -> Some d
  | None when Option.is_some (installed_toolchain ()) -> None
  | None ->
      let sibling =
        Filename.concat
          (Filename.dirname (Filename.dirname Sys.executable_name))
          "stdlib"
      in
      if Sys.file_exists (Filename.concat sibling "libocamlstdlib.a") then
        Some sibling
      else search_upwards "build/stdlib"

(* Extract module references using compiler-libs Depend. *)
let parse_deps ~(kind : [ `Mli | `Ml ]) path =
  try
    let src = read_file path in
    let lb = Lexing.from_string src in
    lb.Lexing.lex_curr_p <- { lb.Lexing.lex_curr_p with pos_fname = path };
    Depend.free_structure_names := Depend.String.Set.empty;
    (match kind with
    | `Mli ->
        let sg = Parse.interface lb in
        Depend.add_signature Depend.String.Map.empty sg
    | `Ml ->
        let impl = Parse.implementation lb in
        Depend.add_implementation Depend.String.Map.empty impl);
    Ok (Depend.String.Set.elements !Depend.free_structure_names)
  with exn ->
    Error (Printf.sprintf "dependency parse failed for %s: %s" path (Printexc.to_string exn))

let plan_build_order (ocaml_files : string list) : (build_step list, string) result =
  let mli_by_mod : (string, int * string) Hashtbl.t = Hashtbl.create 16 in
  let ml_by_mod : (string, int * string) Hashtbl.t = Hashtbl.create 16 in
  let order_counter = ref 0 in
  let next_ord () =
    let v = !order_counter in
    incr order_counter;
    v
  in
  let rec collect = function
    | [] -> Ok ()
    | f :: rest ->
        let modname = Pipeline.module_name_of_file f in
        let ord = next_ord () in
        if Filename.check_suffix f ".mli" then begin
          if Hashtbl.mem mli_by_mod modname then
            Error ("duplicate .mli for module " ^ modname)
          else begin
            Hashtbl.add mli_by_mod modname (ord, f);
            collect rest
          end
        end
        else if Filename.check_suffix f ".ml" then begin
          if Hashtbl.mem ml_by_mod modname then
            Error ("duplicate .ml for module " ^ modname)
          else begin
            Hashtbl.add ml_by_mod modname (ord, f);
            collect rest
          end
        end
        else Error ("expected .ml or .mli input: " ^ f)
  in
  match collect ocaml_files with
  | Error _ as e -> e
  | Ok () ->
      (* Build graph nodes (modname, `Mli | `Ml) with input order index. *)
      let nodes = ref [] in
      Hashtbl.iter
        (fun modname (ord, path) ->
          nodes := ({ modname; kind = `Mli; path }, ord) :: !nodes)
        mli_by_mod;
      Hashtbl.iter
        (fun modname (ord, path) ->
          nodes := ({ modname; kind = `Ml; path }, ord) :: !nodes)
        ml_by_mod;
      let nodes =
        List.sort (fun (_, a) (_, b) -> compare a b) !nodes |> List.map fst
      in
      let key_of (s : build_step) =
        (s.modname, match s.kind with `Mli -> 0 | `Ml -> 1)
      in
      let node_set = Hashtbl.create 32 in
      List.iteri (fun idx s -> Hashtbl.add node_set (key_of s) (idx, s)) nodes;
      let n = List.length nodes in
      let hard_deps = Array.make n [] in
      let soft_deps = Array.make n [] in
      let soft_rev = Array.make n [] in
      let dep_res = ref (Ok ()) in
      List.iteri
        (fun i (s : build_step) ->
          if !dep_res = Ok () then
            match parse_deps ~kind:s.kind s.path with
            | Error _ as e -> dep_res := e
            | Ok mod_refs ->
                let add_edge ~hard target_key =
                  match Hashtbl.find_opt node_set target_key with
                  | Some (j, _) when j <> i ->
                      if hard && not (List.mem j hard_deps.(i)) then
                        hard_deps.(i) <- j :: hard_deps.(i);
                      if not (List.mem j soft_deps.(i)) then begin
                        soft_deps.(i) <- j :: soft_deps.(i);
                        soft_rev.(j) <- i :: soft_rev.(j)
                      end
                  | _ -> ()
                in
                (match s.kind with
                | `Ml -> add_edge ~hard:true (s.modname, 0)
                | `Mli -> ());
                List.iter
                  (fun dep_mod ->
                    if dep_mod <> s.modname then begin
                      if Hashtbl.mem mli_by_mod dep_mod then begin
                        add_edge ~hard:true (dep_mod, 0);
                        if s.kind = `Ml && Hashtbl.mem ml_by_mod dep_mod then
                          add_edge ~hard:false (dep_mod, 1)
                      end
                      else if Hashtbl.mem ml_by_mod dep_mod then
                        add_edge ~hard:true (dep_mod, 1)
                    end)
                  mod_refs)
        nodes;
      match !dep_res with
      | Error _ as e -> e
      | Ok () -> (
          (* Compute Tarjan SCCs on soft_rev so .mli-mediated mutual .ml
             dependencies form one SCC while preserving dependency order
             between SCCs. *)
          let index = Array.make n (-1) in
          let lowlink = Array.make n 0 in
          let on_stack = Array.make n false in
          let stack = ref [] in
          let next_idx = ref 0 in
          let sccs = ref [] in
          let rec strongconnect v =
            index.(v) <- !next_idx;
            lowlink.(v) <- !next_idx;
            incr next_idx;
            stack := v :: !stack;
            on_stack.(v) <- true;
            List.iter
              (fun w ->
                if index.(w) = -1 then begin
                  strongconnect w;
                  lowlink.(v) <- min lowlink.(v) lowlink.(w)
                end
                else if on_stack.(w) then
                  lowlink.(v) <- min lowlink.(v) index.(w))
              soft_rev.(v);
            if lowlink.(v) = index.(v) then begin
              let rec pop acc =
                match !stack with
                | [] -> acc
                | w :: rest ->
                    stack := rest;
                    on_stack.(w) <- false;
                    let acc = w :: acc in
                    if w = v then acc else pop acc
              in
              sccs := List.sort compare (pop []) :: !sccs
            end
          in
          for v = 0 to n - 1 do
            if index.(v) = -1 then strongconnect v
          done;
          let scc_arr = Array.of_list !sccs in
          let num_sccs = Array.length scc_arr in
          let scc_of = Array.make n 0 in
          Array.iteri
            (fun cid members ->
              List.iter (fun u -> scc_of.(u) <- cid) members)
            scc_arr;
          (* Topological order over condensation DAG via Kahn with node-index tie-break. *)
          let c_rev = Array.make num_sccs [] in
          let c_indeg = Array.make num_sccs 0 in
          for i = 0 to n - 1 do
            let ci = scc_of.(i) in
            List.iter
              (fun j ->
                let cj = scc_of.(j) in
                if ci <> cj && not (List.mem ci c_rev.(cj)) then begin
                  c_rev.(cj) <- ci :: c_rev.(cj);
                  c_indeg.(ci) <- c_indeg.(ci) + 1
                end)
              soft_deps.(i)
          done;
          let min_node cid = List.hd scc_arr.(cid) in
          let cmp_cid a b = compare (min_node a) (min_node b) in
          let ready_c = ref [] in
          for cid = 0 to num_sccs - 1 do
            if c_indeg.(cid) = 0 then ready_c := cid :: !ready_c
          done;
          ready_c := List.sort cmp_cid !ready_c;
          let topo_hard members =
            let m_set = Hashtbl.create 8 in
            List.iter (fun u -> Hashtbl.add m_set u ()) members;
            let indeg = Hashtbl.create 8 in
            let rev = Hashtbl.create 8 in
            List.iter
              (fun u ->
                Hashtbl.add indeg u 0;
                Hashtbl.add rev u [])
              members;
            List.iter
              (fun i ->
                List.iter
                  (fun j ->
                    if Hashtbl.mem m_set j then begin
                      Hashtbl.replace indeg i (Hashtbl.find indeg i + 1);
                      Hashtbl.replace rev j (i :: Hashtbl.find rev j)
                    end)
                  hard_deps.(i))
              members;
            let ready = ref [] in
            List.iter
              (fun u -> if Hashtbl.find indeg u = 0 then ready := u :: !ready)
              members;
            ready := List.sort compare !ready;
            let out = ref [] in
            while !ready <> [] do
              let cur = List.hd !ready in
              ready := List.tl !ready;
              out := cur :: !out;
              List.iter
                (fun nxt ->
                  let d = Hashtbl.find indeg nxt - 1 in
                  Hashtbl.replace indeg nxt d;
                  if d = 0 then ready := List.sort compare (nxt :: !ready))
                (Hashtbl.find rev cur)
            done;
            if List.length !out <> List.length members then None
            else Some (List.rev !out)
          in
          let result = ref [] in
          let cyclic = ref false in
          while !ready_c <> [] && not !cyclic do
            let cid = List.hd !ready_c in
            ready_c := List.tl !ready_c;
            (match topo_hard scc_arr.(cid) with
            | None -> cyclic := true
            | Some sorted ->
                List.iter
                  (fun idx -> result := List.nth nodes idx :: !result)
                  sorted);
            List.iter
              (fun nxt ->
                c_indeg.(nxt) <- c_indeg.(nxt) - 1;
                if c_indeg.(nxt) = 0 then
                  ready_c := List.sort cmp_cid (nxt :: !ready_c))
              c_rev.(cid)
          done;
          if !cyclic || List.length !result <> n then
            Error "cyclic module dependency detected"
          else Ok (List.rev !result))

let infer_kind cfg =
  match cfg.kind with
  | Some k -> k
  | None -> (
      match cfg.target with
      | Some t when String.lowercase_ascii t = "ios-xcframework" ->
          Kind_xcframework
      | _ -> (
          match cfg.output with
          | Some o ->
              if Filename.check_suffix o ".so" || Filename.check_suffix o ".dylib"
              then Kind_shared
              else if Filename.check_suffix o ".a" then Kind_static
              else if Filename.check_suffix o ".o" then Kind_obj
              else if Filename.check_suffix o ".s" then Kind_asm
              else if Filename.check_suffix o ".xcframework" then
                Kind_xcframework
              else Kind_exe
          | None -> Kind_exe))

let resolve_ndk_cc arch =
  let ndk_opt =
    match Sys.getenv_opt "ANDROID_NDK_HOME" with
    | Some _ as p -> p
    | None -> Sys.getenv_opt "ANDROID_NDK_ROOT"
  in
  let triple =
    match arch with
    | "arm64" -> "aarch64-linux-android"
    | "x86_64" -> "x86_64-linux-android"
    | a -> a ^ "-linux-android"
  in
  let exe_name = triple ^ "24-clang" in
  let from_ndk =
    match ndk_opt with
    | None -> None
    | Some root ->
        let prebuilt = Filename.concat root "toolchains/llvm/prebuilt" in
        if Sys.file_exists prebuilt && Sys.is_directory prebuilt then
          let hosts = Array.to_list (Sys.readdir prebuilt) in
          List.find_map
            (fun h ->
              let cand = Filename.concat prebuilt (h ^ "/bin/" ^ exe_name) in
              if Sys.file_exists cand then Some cand else None)
            hosts
        else None
  in
  match from_ndk with
  | Some p -> Some p
  | None -> find_in_path exe_name

type toolchain = {
  cc_prog : string;
  cc_base_args : string list;
  ar_prog : string;
}

let resolve_toolchain cfg (t : target_spec) : (toolchain, string) result =
  let ar_prog =
    match cfg.ar_path with
    | Some a -> a
    | None -> (
        match cfg.cc_path with
        | Some cc ->
            let base = Filename.basename cc in
            let dir = Filename.dirname cc in
            let derive suffix =
              if String.ends_with ~suffix base then
                let prefix = String.sub base 0 (String.length base - String.length suffix) in
                let cand = if dir = "." then prefix ^ "ar" else Filename.concat dir (prefix ^ "ar") in
                if Sys.file_exists cand then Some cand
                else find_in_path (prefix ^ "ar")
              else None
            in
            let derived =
              List.find_map derive [ "-gcc"; "-clang"; "gcc"; "clang" ]
            in
            Option.value derived ~default:"ar"
        | None -> "ar")
  in
  match cfg.cc_path with
  | Some cc ->
      let sysroot_args =
        match cfg.sysroot with
        | Some s -> [ "--sysroot=" ^ s ]
        | None -> []
      in
      Ok { cc_prog = cc; cc_base_args = sysroot_args; ar_prog }
  | None -> (
      let host = detect_host_target () in
      match t.os with
      | Darwin ->
          if host.os = Darwin && host.arch = t.arch && cfg.sysroot = None then
            Ok { cc_prog = "cc"; cc_base_args = []; ar_prog }
          else
            let sdk_args =
              match cfg.sysroot with
              | Some s -> [ "-isysroot"; s ]
              | None -> []
            in
            Ok
              { cc_prog = "xcrun";
                cc_base_args = [ "--sdk"; "macosx"; "clang"; "-arch"; t.arch ] @ sdk_args;
                ar_prog }
      | Ios ->
          let sdk_args =
            match cfg.sysroot with
            | Some s -> [ "-isysroot"; s ]
            | None -> []
          in
          Ok
            { cc_prog = "xcrun";
              cc_base_args =
                [ "--sdk"; "iphoneos"; "clang"; "-arch"; "arm64";
                  "-miphoneos-version-min=14.0" ]
                @ sdk_args;
              ar_prog }
      | Ios_sim ->
          let sdk_args =
            match cfg.sysroot with
            | Some s -> [ "-isysroot"; s ]
            | None -> []
          in
          Ok
            { cc_prog = "xcrun";
              cc_base_args =
                [ "--sdk"; "iphonesimulator"; "clang"; "-arch"; "arm64";
                  "-mios-simulator-version-min=14.0" ]
                @ sdk_args;
              ar_prog }
      | Android -> (
          match resolve_ndk_cc t.arch with
          | Some cc ->
              let sysroot_args =
                match cfg.sysroot with
                | Some s -> [ "--sysroot=" ^ s ]
                | None -> []
              in
              Ok { cc_prog = cc; cc_base_args = sysroot_args; ar_prog }
          | None ->
              Error
                ("cannot locate Android NDK clang for " ^ t.name
               ^ " (pass --cc or set ANDROID_NDK_HOME)"))
      | Linux ->
          if host.os = Linux && host.arch = t.arch then
            Ok { cc_prog = "cc"; cc_base_args = []; ar_prog }
          else
            let gcc_name =
              match t.arch with
              | "arm64" -> "aarch64-linux-gnu-gcc"
              | "x86_64" -> "x86_64-linux-gnu-gcc"
              | "riscv64" -> "riscv64-linux-gnu-gcc"
              | a -> a ^ "-linux-gnu-gcc"
            in
            (match find_in_path gcc_name with
            | Some p -> Ok { cc_prog = p; cc_base_args = []; ar_prog }
            | None ->
                Error
                  ("cannot locate cross-compiler " ^ gcc_name
                 ^ " (pass --cc)") )
      | Windows -> (
          match find_in_path "x86_64-w64-mingw32-gcc" with
          | Some p -> Ok { cc_prog = p; cc_base_args = []; ar_prog }
          | None -> Error "cannot locate x86_64-w64-mingw32-gcc (pass --cc)"))

let compile_c_or_s ~verbose (tc : toolchain) extra_flags src obj =
  let args = tc.cc_base_args @ extra_flags @ [ "-c"; src; "-o"; obj ] in
  run_cmd ~verbose tc.cc_prog args

let runtime_sources ~include_main runtime_dir =
  let base =
    [ "pal.c"; "pal_ctx.S"; "arc.c"; "closure.c"; "fiber.c"; "builtins.c" ]
  in
  let files = if include_main then base @ [ "main_entry.c" ] else base in
  List.map (fun f -> Filename.concat runtime_dir f) files

let compile_runtime_objs ~verbose (tc : toolchain) ~include_main runtime_dir
    out_dir =
  mkdir_p out_dir;
  let srcs = runtime_sources ~include_main runtime_dir in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | src :: rest ->
        let base = Filename.chop_extension (Filename.basename src) in
        let obj = Filename.concat out_dir (base ^ ".o") in
        let flags =
          if Filename.check_suffix src ".S" then []
          else [ "-std=c11"; "-O2"; "-g"; "-fPIC"; "-I" ^ runtime_dir ]
        in
        match compile_c_or_s ~verbose tc flags src obj with
        | Error _ as e -> e
        | Ok () -> go (obj :: acc) rest
  in
  go [] srcs

let stdlib_ordered_units =
  [ "camlinternalFormatBasics.ml";
    "camlinternalIntFmt.ml";
    "camlinternalBulkOps.ml";
    "camlinternalChannel.ml";
    "camlinternalMarshal.ml";
    "camlinternalSys.ml";
    "stdlib__option.ml";
    "stdlib__result.ml";
    "stdlib__bytes.ml";
    "stdlib__string.ml";
    "stdlib__char.ml";
    "stdlib__int32.ml";
    "stdlib__int64.ml";
    "stdlib__nativeint.ml";
    "stdlib__list.ml";
    "stdlib__array.ml";
    "stdlib__buffer.ml";
    "stdlib__hashtbl.ml";
    "stdlib__printf.ml";
    "stdlib__weak.ml";
    "stdlib__fiber.ml";
    "stdlib.ml" ]

type stdlib_plan =
  | Stdlib_prebuilt of string * string list
  | Stdlib_compiled of (string * string) list
  | Stdlib_none

let compile_stdlib_cmis_and_ssa stdlib_src_dir out_dir :
    ((string * string) list, string) result =
  mkdir_p out_dir;
  let units =
    List.filter_map
      (fun f ->
        let p = Filename.concat stdlib_src_dir f in
        if Sys.file_exists p then Some p else None)
      stdlib_ordered_units
  in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | ml :: rest -> (
        let base = Filename.chop_extension (Filename.basename ml) in
        let prefix = Filename.concat out_dir base in
        let ssa = prefix ^ ".ssa" in
        let obj = prefix ^ ".o" in
        let modname = Pipeline.module_name_of_file ml in
        match
          Pipeline.compile_file ~include_dirs:[ out_dir ] ~output_prefix:prefix
            ~emit_cmi:true ~nopervasives:true ~nostdlib:true ~emit_entry:false
            ~filename:ml ~modname ()
        with
        | Error msg -> Error msg
        | Ok ssa_txt ->
            write_file ssa ssa_txt;
            go ((ssa, obj) :: acc) rest)
  in
  go [] units

let compile_stdlib_objs_from_ssa ~verbose ~qbe (tc : toolchain) ~qbe_target
    ssa_obj_pairs =
  let rec go objs = function
    | [] -> Ok (List.rev objs)
    | (ssa, obj) :: rest -> (
        let asm = Filename.chop_extension ssa ^ ".s" in
        match
          run_cmd ~verbose ~stdout_file:asm qbe [ "-t"; qbe_target; ssa ]
        with
        | Error _ as e -> e
        | Ok () -> (
            match compile_c_or_s ~verbose tc [] asm obj with
            | Error _ as e -> e
            | Ok () -> go (obj :: objs) rest))
  in
  go [] ssa_obj_pairs

let compile_stdlib_objs ~verbose ~qbe (tc : toolchain) ~qbe_target stdlib_src_dir
    out_dir =
  match compile_stdlib_cmis_and_ssa stdlib_src_dir out_dir with
  | Error _ as e -> e
  | Ok pairs ->
      compile_stdlib_objs_from_ssa ~verbose ~qbe tc ~qbe_target pairs

let list_o_files dir =
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".o")
    |> List.sort compare
    |> List.map (Filename.concat dir)
  else []

let is_host_default_toolchain cfg (t : target_spec) =
  let host = detect_host_target () in
  t.qbe_target = host.qbe_target
  && t.os = host.os && t.arch = host.arch
  && cfg.cc_path = None && cfg.sysroot = None

let rec build_single cfg ~(target : target_spec) ~(kind : output_kind)
    ~work_dir : (string, string) result =
  let verbose = cfg.verbose in
  match resolve_qbe cfg with
  | Error _ as e -> e
  | Ok qbe -> (
      mkdir_p work_dir;
          let ocaml_inputs, c_inputs, obj_inputs =
            List.fold_left
              (fun (oc, cc, ob) f ->
                if
                  Filename.check_suffix f ".ml"
                  || Filename.check_suffix f ".mli"
                then (f :: oc, cc, ob)
                else if Filename.check_suffix f ".c" then (oc, f :: cc, ob)
                else if
                  Filename.check_suffix f ".o"
                  || Filename.check_suffix f ".a"
                then (oc, cc, f :: ob)
                else (f :: oc, cc, ob))
              ([], [], []) cfg.inputs
          in
          let ocaml_inputs = List.rev ocaml_inputs in
          let c_inputs = List.rev c_inputs in
          let obj_inputs = List.rev obj_inputs in
          match plan_build_order ocaml_inputs with
          | Error _ as e -> e
          | Ok steps ->
              let ml_steps =
                List.filter (fun (s : build_step) -> s.kind = `Ml) steps
              in
              let mli_steps =
                List.filter (fun (s : build_step) -> s.kind = `Mli) steps
              in
              let cmi_dir = Filename.concat work_dir "cmi" in
              mkdir_p cmi_dir;
              let stdlib_prep_res =
                if cfg.nostdlib then Ok (Stdlib_none, [], true)
                else
                  let try_src () =
                    match resolve_stdlib_src_dir cfg with
                    | Some sdir
                      when Sys.file_exists (Filename.concat sdir "stdlib.ml") ->
                        let out_dir = Filename.concat work_dir "stdlib" in
                        (match compile_stdlib_cmis_and_ssa sdir out_dir with
                        | Error _ as e -> e
                        | Ok pairs ->
                            Ok (Stdlib_compiled pairs, [ out_dir ], true))
                    | _ -> Ok (Stdlib_none, [], false)
                  in
                  if is_host_default_toolchain cfg target then
                    match resolve_prebuilt_stdlib_dir cfg with
                    | Some d when Sys.file_exists (Filename.concat d "stdlib.cmi") ->
                        let inputs =
                          match kind, Export_summary.find_archive d with
                          | Kind_exe, Some archive -> [archive]
                          | _ -> list_o_files d
                        in
                        if inputs = [] then try_src ()
                        else Ok (Stdlib_prebuilt (d, inputs), [d], true)
                    | _ -> try_src ()
                  else try_src ()
              in
              match stdlib_prep_res with
              | Error _ as e -> e
              | Ok (stdlib_plan, stdlib_cmi_dirs, eff_nostdlib) ->
              let inc_dirs =
                cmi_dir :: (stdlib_cmi_dirs @ cfg.include_dirs)
              in
              let stdlib_dir = List.nth_opt stdlib_cmi_dirs 0 in
              let is_lib_kind =
                match kind with
                | Kind_shared | Kind_static | Kind_obj | Kind_asm
                | Kind_xcframework ->
                    true
                | Kind_exe -> false
              in
              let include_main = (not is_lib_kind) && not cfg.no_main in
              let last_ml_path =
                match List.rev ml_steps with
                | s :: _ -> Some s.path
                | [] -> None
              in
              let asm_files = ref [] in
              let imports = ref (
                match stdlib_plan with
                | Stdlib_prebuilt (_, [archive]) when Filename.check_suffix archive ".a" ->
                    Export_summary.read_archive ~include_dirs:inc_dirs archive
                    |> List.filter (fun (unit_name, _) ->
                         not (List.exists (fun (step : build_step) -> step.modname = unit_name)
                                ml_steps))
                | _ -> []) in
              let shim_c_files = ref [] in
              let shim_exported_syms = ref [] in
              let has_mli modname =
                List.exists (fun (s : build_step) -> s.modname = modname) mli_steps
              in
              let step_res =
                List.fold_left
                  (fun acc (s : build_step) ->
                    match acc with
                    | Error _ as e -> e
                    | Ok () -> (
                        let lower = String.uncapitalize_ascii s.modname in
                        let prefix = Filename.concat cmi_dir lower in
                        match s.kind with
                        | `Mli -> (
                            match
                              Pipeline.compile_interface_file
                                ~include_dirs:inc_dirs ~output_prefix:prefix
                                ~nopervasives:cfg.nopervasives
                                ~nostdlib:eff_nostdlib ~filename:s.path
                                ~modname:s.modname ()
                            with
                            | Error msg -> Error msg
                            | Ok _ ->
                                Gc.full_major ();
                                Ok ())
                        | `Ml -> (
                            let emit_cmi = not (has_mli s.modname) in
                            let emit_entry =
                              include_main
                              && (match last_ml_path with
                                 | Some p -> p = s.path
                                 | None -> false)
                            in
                            match
                              Pipeline.compile_file ~include_dirs:inc_dirs ?stdlib_dir
                                ~output_prefix:prefix ~emit_cmi
                                ~imports:!imports
                                ~on_exports:(fun exports ->
                                  imports := (s.modname, exports) :: !imports)
                                ~nopervasives:cfg.nopervasives
                                ~nostdlib:eff_nostdlib ~emit_entry:false
                                ~inline_single_thread_rc:cfg.inline_single_thread_rc
                                ~filename:s.path ~modname:s.modname ()
                            with
                            | Error msg -> Error msg
                            | Ok ssa_txt -> (
                                let ssa = Filename.concat work_dir (lower ^ ".ssa") in
                                let asm = Filename.concat work_dir (lower ^ ".s") in
                                let startup =
                                  if emit_entry then
                                    let names = List.map (fun step -> step.modname) ml_steps in
                                    Qbe_il.to_string { funcs = [Codegen.entry_point names]; datas = [] }
                                  else ""
                                in
                                write_file ssa (ssa_txt ^ startup);
                                match
                                  run_cmd ~verbose ~stdout_file:asm qbe
                                    [ "-t"; target.qbe_target; ssa ]
                                with
                                | Error _ as e -> e
                                | Ok () ->
                                    asm_files := asm :: !asm_files;
                                    Gc.full_major ();
                                    Ok ()))))
                  (Ok ()) steps
              in
              match step_res with
              | Error _ as e -> e
              | Ok () -> (
                  let asm_files = List.rev !asm_files in
                  (* Optional .mli -> .h + _shim.c generation *)
                  let bindgen_res =
                    match cfg.emit_header with
                    | None -> Ok ()
                    | Some hdr_path -> (
                        match mli_steps with
                        | [] ->
                            Error
                              "--emit-header requires at least one .mli input"
                        | _ ->
                            let hdr_dir = Filename.dirname hdr_path in
                            mkdir_p hdr_dir;
                            let multi = List.length mli_steps > 1 in
                            let hdr_base = Filename.basename hdr_path in
                            let hdr_stem = Filename.remove_extension hdr_base in
                            let hdr_ext =
                              let e = Filename.extension hdr_base in
                              if e = "" then ".h" else e
                            in
                            let sub_headers = ref [] in
                            let res =
                              List.fold_left
                                (fun acc (s : build_step) ->
                                  match acc with
                                  | Error _ as e -> e
                                  | Ok () -> (
                                      let out_h =
                                        if multi then
                                          let name =
                                            Printf.sprintf "%s_%s%s" hdr_stem
                                              (String.uncapitalize_ascii
                                                 s.modname)
                                              hdr_ext
                                          in
                                          sub_headers := name :: !sub_headers;
                                          Filename.concat hdr_dir name
                                        else hdr_path
                                      in
                                      let out_c =
                                        Filename.concat work_dir
                                          (String.uncapitalize_ascii s.modname
                                         ^ "_shim.c")
                                      in
                                      match
                                        C_bindgen.generate_file
                                          ~include_dirs:inc_dirs
                                          ~nopervasives:cfg.nopervasives
                                          ~nostdlib:eff_nostdlib
                                          ~header_include:
                                            (Filename.basename out_h)
                                          ~filename:s.path ~modname:s.modname ()
                                      with
                                      | Error msg -> Error msg
                                      | Ok { header; shim_c; exported_symbols } ->
                                          write_file out_h header;
                                          write_file out_c shim_c;
                                          shim_c_files := out_c :: !shim_c_files;
                                          shim_exported_syms :=
                                            List.rev_append exported_symbols
                                              !shim_exported_syms;
                                          Ok ()))
                                (Ok ()) mli_steps
                            in
                            (match res with
                            | Ok () when multi ->
                                let sanitize_guard s =
                                  String.map
                                    (fun c ->
                                      if
                                        (c >= 'A' && c <= 'Z')
                                        || (c >= '0' && c <= '9')
                                      then c
                                      else if c >= 'a' && c <= 'z' then
                                        Char.uppercase_ascii c
                                      else '_')
                                    s
                                in
                                let guard =
                                  "OCAMLCC_UMBRELLA_"
                                  ^ sanitize_guard hdr_base
                                in
                                let includes =
                                  List.rev !sub_headers
                                  |> List.map (Printf.sprintf "#include \"%s\"")
                                  |> String.concat "\n"
                                in
                                let umbrella =
                                  Printf.sprintf
                                    "#ifndef %s\n#define %s\n\n%s\n\n#endif /* %s */\n"
                                    guard guard includes guard
                                in
                                write_file hdr_path umbrella
                            | _ -> ());
                            res)
                  in
                  match bindgen_res with
                  | Error _ as e -> e
                  | Ok () -> (
                      let shim_c_files = List.rev !shim_c_files in
                      let shim_exported_syms = List.rev !shim_exported_syms in
                      let out_path =
                        match cfg.output with
                        | Some o -> o
                        | None -> (
                            match kind with
                            | Kind_exe -> "a.out"
                            | Kind_shared ->
                                if target.os = Darwin then "libout.dylib"
                                else "libout.so"
                            | Kind_static -> "libout.a"
                            | Kind_obj -> "out.o"
                            | Kind_asm -> "out.s"
                            | Kind_xcframework -> "Out.xcframework")
                      in
                      mkdir_p (Filename.dirname out_path);
                      match kind with
                      | Kind_asm ->
                          let combined =
                            String.concat "\n" (List.map read_file asm_files)
                          in
                          write_file out_path combined;
                          Ok out_path
                      | Kind_obj -> (
                          match resolve_toolchain cfg target with
                          | Error _ as e -> e
                          | Ok tc -> (
                              match asm_files with
                              | [ asm ] -> (
                                  match
                                    compile_c_or_s ~verbose tc cfg.extra_cflags
                                      asm out_path
                                  with
                                  | Error _ as e -> e
                                  | Ok () -> Ok out_path)
                              | _ ->
                                  Error
                                    "-c requires a single .ml compilation unit"))
                      | Kind_exe | Kind_shared | Kind_static -> (
                          match resolve_toolchain cfg target with
                          | Error _ as e -> e
                          | Ok tc -> (
                          let compile_many srcs flags =
                            let rec go acc idx = function
                              | [] -> Ok (List.rev acc)
                              | s :: rest -> (
                                  let obj =
                                    Filename.concat work_dir
                                      (Printf.sprintf "u_%d_%s.o" idx
                                         (Filename.chop_extension
                                            (Filename.basename s)))
                                  in
                                  match compile_c_or_s ~verbose tc flags s obj with
                                  | Error _ as e -> e
                                  | Ok () -> go (obj :: acc) (idx + 1) rest)
                            in
                            go [] 0 srcs
                          in
                          let pic_flags =
                            if target.os = Windows then [] else [ "-fPIC" ]
                          in
                          let hdr_inc_flags =
                            match cfg.emit_header with
                            | Some h -> [ "-I" ^ Filename.dirname h ]
                            | None -> []
                          in
                          match
                            compile_many asm_files (pic_flags @ cfg.extra_cflags)
                          with
                          | Error _ as e -> e
                          | Ok unit_objs -> (
                              match
                                compile_many shim_c_files
                                  ([ "-std=c99"; "-O2" ] @ pic_flags
                                 @ hdr_inc_flags @ cfg.extra_cflags)
                              with
                              | Error _ as e -> e
                              | Ok shim_objs -> (
                                  match
                                    compile_many c_inputs
                                      (pic_flags @ hdr_inc_flags
                                     @ cfg.extra_cflags)
                                  with
                                  | Error _ as e -> e
                                  | Ok c_objs -> (
                                      let user_objs =
                                        unit_objs @ shim_objs @ c_objs @ obj_inputs
                                      in
                                      let rt_objs_res =
                                        if is_host_default_toolchain cfg target
                                        then
                                          match resolve_prebuilt_rt_dir cfg with
                                          | Some d
                                            when Sys.file_exists
                                                   (Filename.concat d "arc.o") ->
                                              let base =
                                                [ "pal.o"; "pal_ctx.o"; "arc.o";
                                                  "closure.o"; "fiber.o";
                                                  "builtins.o" ]
                                              in
                                              let files =
                                                if include_main then
                                                  base @ [ "main_entry.o" ]
                                                else base
                                              in
                                              Ok
                                                (List.map
                                                   (Filename.concat d)
                                                   files)
                                          | _ -> (
                                              match resolve_runtime_dir cfg with
                                              | Some rdir ->
                                                  compile_runtime_objs ~verbose
                                                    tc ~include_main rdir
                                                    (Filename.concat work_dir
                                                       "rt")
                                              | None ->
                                                  Error
                                                    "cannot locate runtime/ directory")
                                        else
                                          match resolve_runtime_dir cfg with
                                          | Some rdir ->
                                              compile_runtime_objs ~verbose tc
                                                ~include_main rdir
                                                (Filename.concat work_dir "rt")
                                          | None ->
                                              Error
                                                "cannot locate runtime/ directory for cross build"
                                      in
                                      match rt_objs_res with
                                      | Error _ as e -> e
                                      | Ok rt_objs -> (
                                          let stdlib_objs_res =
                                            match stdlib_plan with
                                            | Stdlib_prebuilt (_, objs) ->
                                                Ok objs
                                            | Stdlib_compiled pairs ->
                                                compile_stdlib_objs_from_ssa
                                                  ~verbose ~qbe tc
                                                  ~qbe_target:target.qbe_target
                                                  pairs
                                            | Stdlib_none ->
                                                if cfg.nostdlib then Ok []
                                                else if
                                                  is_host_default_toolchain cfg
                                                    target
                                                then
                                                  match
                                                    resolve_prebuilt_stdlib_dir
                                                      cfg
                                                  with
                                                  | Some d
                                                    when list_o_files d <> [] ->
                                                      Ok (list_o_files d)
                                                  | _ -> (
                                                      match
                                                        resolve_stdlib_src_dir
                                                          cfg
                                                      with
                                                      | Some sdir ->
                                                          compile_stdlib_objs
                                                            ~verbose ~qbe tc
                                                            ~qbe_target:
                                                              target.qbe_target
                                                            sdir
                                                            (Filename.concat
                                                               work_dir "stdlib")
                                                      | None -> Ok [])
                                                else
                                                  match
                                                    resolve_stdlib_src_dir cfg
                                                  with
                                                  | Some sdir ->
                                                      compile_stdlib_objs
                                                        ~verbose ~qbe tc
                                                        ~qbe_target:
                                                          target.qbe_target
                                                        sdir
                                                        (Filename.concat
                                                           work_dir "stdlib")
                                                  | None -> Ok []
                                          in
                                          match stdlib_objs_res with
                                          | Error _ as e -> e
                                          | Ok stdlib_objs -> (
                                              let all_objs =
                                                user_objs @ stdlib_objs @ rt_objs
                                              in
                                              match kind with
                                              | Kind_static -> (
                                                  if Sys.file_exists out_path
                                                  then Sys.remove out_path;
                                                  match
                                                    run_cmd ~verbose tc.ar_prog
                                                      ([ "rcs"; out_path ]
                                                      @ all_objs)
                                                  with
                                                  | Error _ as e -> e
                                                  | Ok () -> Ok out_path)
                                              | Kind_shared -> (
                                                  let internal_objs =
                                                    stdlib_objs @ rt_objs
                                                  in
                                                  let vis_res =
                                                    if
                                                      cfg.emit_header <> None
                                                      && c_inputs = []
                                                      && obj_inputs = []
                                                      && shim_exported_syms <> []
                                                    then
                                                      match target.os with
                                                      | Darwin | Ios | Ios_sim ->
                                                          let exp_f =
                                                            Filename.concat
                                                              work_dir
                                                              "exports.txt"
                                                          in
                                                          let body =
                                                            shim_exported_syms
                                                            |> List.sort_uniq
                                                                 String.compare
                                                            |> List.map
                                                                 (fun s ->
                                                                   "_" ^ s)
                                                            |> String.concat
                                                                 "\n"
                                                          in
                                                          write_file exp_f
                                                            (body ^ "\n");
                                                          Ok
                                                            ( all_objs,
                                                              [ "-Wl,-exported_symbols_list,"
                                                                ^ exp_f ] )
                                                      | Linux | Android ->
                                                          let ver_f =
                                                            Filename.concat
                                                              work_dir
                                                              "exports.ver"
                                                          in
                                                          let syms =
                                                            shim_exported_syms
                                                            |> List.sort_uniq
                                                                 String.compare
                                                            |> List.map
                                                                 (fun s ->
                                                                   "    " ^ s
                                                                   ^ ";")
                                                            |> String.concat
                                                                 "\n"
                                                          in
                                                          write_file ver_f
                                                            ("{\n  global:\n"
                                                           ^ syms
                                                           ^ "\n  local:\n    *;\n};\n");
                                                          Ok
                                                            ( all_objs,
                                                              [ "-Wl,--version-script="
                                                                ^ ver_f ] )
                                                      | Windows ->
                                                          Ok (all_objs, [])
                                                    else
                                                      match target.os with
                                                      | Darwin | Ios | Ios_sim ->
                                                          if internal_objs = []
                                                          then Ok (all_objs, [])
                                                          else (
                                                            match
                                                              capture_cmd "nm"
                                                                ("-gUj"
                                                                :: internal_objs
                                                                )
                                                            with
                                                            | Error _ as e -> e
                                                            | Ok raw_syms ->
                                                                let syms =
                                                                  String
                                                                  .split_on_char
                                                                    '\n'
                                                                    raw_syms
                                                                  |> List
                                                                     .filter_map
                                                                       (fun l ->
                                                                         let s =
                                                                           String
                                                                           .trim
                                                                             l
                                                                         in
                                                                         if
                                                                           s
                                                                           = ""
                                                                           || s.[
                                                                              String
                                                                              .length
                                                                                s
                                                                              - 1]
                                                                              = ':'
                                                                         then
                                                                           None
                                                                         else
                                                                           Some
                                                                             s)
                                                                  |> List
                                                                     .sort_uniq
                                                                       String
                                                                       .compare
                                                                in
                                                                if syms = []
                                                                then
                                                                  Ok
                                                                    ( all_objs,
                                                                      [] )
                                                                else
                                                                  let unexp_f =
                                                                    Filename
                                                                    .concat
                                                                      work_dir
                                                                      "unexports.txt"
                                                                  in
                                                                  write_file
                                                                    unexp_f
                                                                    (String
                                                                     .concat
                                                                       "\n" syms
                                                                    ^ "\n");
                                                                  Ok
                                                                    ( all_objs,
                                                                      [ "-Wl,-unexported_symbols_list,"
                                                                        ^ unexp_f
                                                                      ] ))
                                                      | Linux | Android ->
                                                          if internal_objs = []
                                                          then Ok (all_objs, [])
                                                          else
                                                            let internal_a =
                                                              Filename.concat
                                                                work_dir
                                                                "libocaml_internal.a"
                                                            in
                                                            if
                                                              Sys.file_exists
                                                                internal_a
                                                            then
                                                              Sys.remove
                                                                internal_a;
                                                            (match
                                                               run_cmd ~verbose
                                                                 tc.ar_prog
                                                                 ([ "rcs";
                                                                    internal_a ]
                                                                 @ internal_objs
                                                                 )
                                                             with
                                                            | Error _ as e -> e
                                                            | Ok () ->
                                                                Ok
                                                                  ( user_objs
                                                                    @ [ internal_a
                                                                      ],
                                                                    [ "-Wl,--exclude-libs,ALL"
                                                                    ] ))
                                                      | Windows ->
                                                          Ok (all_objs, [])
                                                  in
                                                  match vis_res with
                                                  | Error _ as e -> e
                                                  | Ok (link_objs, vis_flags) -> (
                                                      let os_link_flags =
                                                        match target.os with
                                                        | Windows -> []
                                                        | Linux -> [ "-lm"; "-pthread" ]
                                                        | Darwin | Ios | Ios_sim | Android -> [ "-lm" ]
                                                      in
                                                      let link_args =
                                                        tc.cc_base_args
                                                        @ [ "-shared" ]
                                                        @ link_objs @ vis_flags
                                                        @ os_link_flags
                                                        @ cfg.extra_ldflags
                                                        @ [ "-o"; out_path ]
                                                      in
                                                      match
                                                        run_cmd ~verbose
                                                          tc.cc_prog link_args
                                                      with
                                                      | Error _ as e -> e
                                                      | Ok () -> Ok out_path))
                                              | Kind_exe -> (
                                                  let os_link_flags =
                                                    match target.os with
                                                    | Windows -> []
                                                    | Linux -> [ "-lm"; "-pthread" ]
                                                    | Darwin | Ios | Ios_sim | Android -> [ "-lm" ]
                                                  in
                                                  let link_args =
                                                    tc.cc_base_args @ all_objs
                                                    @ os_link_flags
                                                    @ cfg.extra_ldflags
                                                    @ [ "-o"; out_path ]
                                                  in
                                                  match
                                                    run_cmd ~verbose tc.cc_prog
                                                      link_args
                                                  with
                                                  | Error _ as e -> e
                                                  | Ok () -> Ok out_path)
                                              | Kind_obj | Kind_asm
                                              | Kind_xcframework ->
                                                  assert false)))))))
                      | Kind_xcframework -> assert false)))

and build (cfg : config) : (string, string) result =
  let tname = Option.value ~default:"host" cfg.target in
  let kind = infer_kind cfg in
  let work_dir, cleanup =
    match cfg.work_dir with
    | Some d -> (d, false)
    | None ->
        let tmp = Filename.temp_dir "ocamlcc_build_" "" in
        (tmp, true)
  in
  Fun.protect
    ~finally:(fun () -> if cleanup then rm_rf work_dir)
    (fun () ->
      if kind = Kind_xcframework || String.lowercase_ascii tname = "ios-xcframework"
      then
        let out_xcf =
          Option.value ~default:"Out.xcframework" cfg.output
        in
        let has_mli_input =
          List.exists (fun f -> Filename.check_suffix f ".mli") cfg.inputs
        in
        let eff_emit_header =
          match cfg.emit_header with
          | Some _ as h -> h
          | None ->
              if has_mli_input then begin
                let hdr_dir = Filename.concat work_dir "headers" in
                mkdir_p hdr_dir;
                Some (Filename.concat hdr_dir "ocamlcc_ffi.h")
              end
              else None
        in
        let dev_a = Filename.concat work_dir "ios_arm64.a" in
        let sim_a = Filename.concat work_dir "ios_sim_arm64.a" in
        let dev_t =
          { name = "ios-arm64";
            qbe_target = "arm64_apple";
            os = Ios;
            arch = "arm64" }
        in
        let sim_t =
          { name = "ios-sim-arm64";
            qbe_target = "arm64_apple";
            os = Ios_sim;
            arch = "arm64" }
        in
        let cfg_dev =
          { cfg with
            output = Some dev_a;
            emit_header = eff_emit_header;
            kind = Some Kind_static }
        in
        let cfg_sim =
          { cfg with
            output = Some sim_a;
            emit_header = eff_emit_header;
            kind = Some Kind_static }
        in
        match
          build_single cfg_dev ~target:dev_t ~kind:Kind_static
            ~work_dir:(Filename.concat work_dir "dev")
        with
        | Error _ as e -> e
        | Ok _ -> (
            match
              build_single cfg_sim ~target:sim_t ~kind:Kind_static
                ~work_dir:(Filename.concat work_dir "sim")
            with
            | Error _ as e -> e
            | Ok _ -> (
                if Sys.file_exists out_xcf then rm_rf out_xcf;
                let hdr_args =
                  match eff_emit_header with
                  | Some h ->
                      let xcf_hdr_dir = Filename.concat work_dir "xcf_headers" in
                      mkdir_p xcf_hdr_dir;
                      let dst = Filename.concat xcf_hdr_dir (Filename.basename h) in
                      write_file dst (read_file h);
                      [ "-headers"; xcf_hdr_dir ]
                  | None -> []
                in
                let xcb_args =
                  [ "-create-xcframework"; "-library"; dev_a ]
                  @ hdr_args
                  @ [ "-library"; sim_a ]
                  @ hdr_args
                  @ [ "-output"; out_xcf ]
                in
                let stdout_file =
                  if cfg.verbose then None else Some "/dev/null"
                in
                match run_cmd ~verbose:cfg.verbose ?stdout_file "xcodebuild" xcb_args with
                | Error _ as e -> e
                | Ok () -> Ok out_xcf))
      else
        match resolve_target tname with
        | Error _ as e -> e
        | Ok target -> build_single cfg ~target ~kind ~work_dir)

open Sys_util

type os =
  | Darwin
  | Linux
  | Ios
  | Ios_sim
  | Android
  | Windows

type t = {
  name : string;
  qbe_target : string;
  os : os;
  arch : string;
}

let detect_host_target () : t =
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

let resolve (s : string) : (t, string) result =
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

let qbe override =
  match override with
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

let runtime_sources override =
  match override with
  | Some d -> Some d
  | None -> (
      match Sys.getenv_opt "OCAMLCC_RUNTIME_DIR" with
      | Some d when Sys.file_exists d -> Some d
      | _ -> (match installed_toolchain () with
              | Some dir -> Some (Filename.concat dir "runtime")
              | None -> search_upwards "runtime"))

let prebuilt_runtime ~single_thread override =
  match override with
  | Some dir -> Some dir
  | None when Option.is_some (installed_toolchain ()) -> None
  | None ->
      let dir = if single_thread then "rt-single" else "rt" in
      let sibling =
        Filename.concat
          (Filename.dirname (Filename.dirname Sys.executable_name))
          dir
      in
      if Sys.file_exists sibling then Some sibling
      else search_upwards (Filename.concat "build" dir)

let stdlib_sources override =
  let bundle directory = Filename.concat directory "stdlib.sources" in
  let existing path =
    if Sys.file_exists path && not (Sys.is_directory path) then Some path else None
  in
  let at path =
    if Sys.file_exists path && Sys.is_directory path then
      List.find_map existing [bundle path; bundle (Filename.dirname path)]
    else existing path
  in
  match override with
  | Some path -> at path
  | None -> (
      match Option.bind (Sys.getenv_opt "OCAMLCC_STDLIB_DIR") at with
      | Some _ as sources -> sources
      | _ -> (match installed_toolchain () with
              | Some dir -> at (Filename.concat dir "stdlib")
              | None ->
                  let sibling =
                    bundle (Filename.dirname (Filename.dirname Sys.executable_name))
                  in
                  match existing sibling with
                  | Some _ as sources -> sources
                  | None -> search_upwards "build/stdlib.sources"))

let prebuilt_stdlib override =
  match override with
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

module Toolchain = struct
  type t = {
    cc_prog : string;
    cc_base_args : string list;
    ar_prog : string;
  }
end

let toolchain ?cc_path ?ar_path ?sysroot (t : t) : (Toolchain.t, string) result =
  let open Toolchain in
  let ar_prog =
    match ar_path with
    | Some a -> a
    | None -> (
        match cc_path with
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
  match cc_path with
  | Some cc ->
      let sysroot_args =
        match sysroot with
        | Some s -> [ "--sysroot=" ^ s ]
        | None -> []
      in
      Ok { cc_prog = cc; cc_base_args = sysroot_args; ar_prog }
  | None -> (
      let host = detect_host_target () in
      match t.os with
      | Darwin ->
          if host.os = Darwin && host.arch = t.arch && sysroot = None then
            Ok { cc_prog = "cc"; cc_base_args = []; ar_prog }
          else
            let sdk_args =
              match sysroot with
              | Some s -> [ "-isysroot"; s ]
              | None -> []
            in
            Ok
              { cc_prog = "xcrun";
                cc_base_args = [ "--sdk"; "macosx"; "clang"; "-arch"; t.arch ] @ sdk_args;
                ar_prog }
      | Ios ->
          let sdk_args =
            match sysroot with
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
            match sysroot with
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
                match sysroot with
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

let is_host t =
  let host = detect_host_target () in
  t.qbe_target = host.qbe_target && t.os = host.os && t.arch = host.arch

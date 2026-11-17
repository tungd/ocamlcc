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
  stdlib_src_dir : string option;
  prebuilt_stdlib_dir : string option;
  work_dir : string option;
  extra_cflags : string list;
  extra_ldflags : string list;
  verbose : bool;
}

val default_config : unit -> config

val resolve_target : string -> (target_spec, string) result
(** Resolve a CLI [--target] name (["host"], QBE targets ["arm64_apple"],
    ["arm64"], ["amd64_sysv"], ["rv64"], ["amd64_apple"], ["amd64_win"], or
    platform targets ["ios-arm64"], ["ios-sim-arm64"], ["ios-xcframework"],
    ["android-arm64"], ["android-x86_64"], ["linux-arm64"], ["linux-amd64"],
    ["linux-rv64"], ["macos-arm64"], ["macos-amd64"]). *)

val plan_build_order : string list -> (build_step list, string) result
(** Parse [.mli]/[.ml] module dependencies with compiler-libs [Depend] and
    return the topologically sorted build steps. *)

val build : config -> (string, string) result
(** Execute the full single-binary driver pipeline and return the output path. *)

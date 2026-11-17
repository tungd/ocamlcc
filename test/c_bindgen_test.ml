(* Unit tests for .mli -> C99 header + FFI shim generator (C_bindgen). *)

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

let check_contains label text needles =
  let missing = List.filter (fun n -> not (has_substr ~sub:n text)) needles in
  if missing = [] then begin
    Printf.printf "%s: PASS\n" label;
    true
  end
  else begin
    Printf.printf "%s: FAIL missing [%s]\n" label (String.concat "; " missing);
    false
  end

let sample_mli =
  {|
type t
type point = { x : float; y : float }
type user = { name : string; age : int }
type alias_i = int

exception Lib_err of int

val create : int -> t
val get : t -> int
val add_pt : point -> point -> point
val greet : user -> string
val opt_add : int option -> int32 -> int64 -> int64 option
val flip : bool -> bool
val pair_sum : int * int -> alias_i
val ping : unit -> unit
val version : int
|}

let extract_fn_body ~fn_prefix text =
  let n = String.length text in
  let pl = String.length fn_prefix in
  let rec find_start i =
    if i > n - pl then None
    else if String.sub text i pl = fn_prefix then Some i
    else find_start (i + 1)
  in
  match find_start 0 with
  | None -> None
  | Some start ->
      let brace = String.index_from text start '{' in
      let rec scan idx depth =
        if idx >= n then None
        else
          match text.[idx] with
          | '{' -> scan (idx + 1) (depth + 1)
          | '}' ->
              if depth = 1 then Some (String.sub text brace (idx - brace + 1))
              else scan (idx + 1) (depth - 1)
          | _ -> scan (idx + 1) depth
      in
      scan (brace + 1) 1

let find_substr ~sub s =
  let sl = String.length sub in
  let n = String.length s in
  if sl = 0 then Some 0
  else if sl > n then None
  else
    let rec go i =
      if i > n - sl then None
      else if String.sub s i sl = sub then Some i
      else go (i + 1)
    in
    go 0

let check_mutator_gated ~fn_prefix text =
  match extract_fn_body ~fn_prefix text with
  | None -> false
  | Some body -> (
      match find_substr ~sub:"arc_mutator_enter()" body with
      | None -> false
      | Some enter_pos ->
          let leave_ok =
            match find_substr ~sub:"arc_mutator_leave(" body with
            | None -> false
            | Some leave_pos -> leave_pos > enter_pos
          in
          let ops_after_enter =
            List.for_all
              (fun op ->
                match find_substr ~sub:op body with
                | None -> true
                | Some p -> p > enter_pos)
              [ "arc_retain_val"; "arc_release_val"; "shim_to_ocaml_";
                "shim_from_ocaml_"; "ocamlcc_apply"; "ocamlcc_init_" ]
          in
          leave_ok && ops_after_enter)

let () =
  let failures = ref 0 in
  (match
     C_bindgen.generate ~nopervasives:true ~nostdlib:true
       ~header_include:"sample.h" ~filename:"sample.mli" ~modname:"Sample"
       sample_mli
   with
  | Error msg ->
      Printf.printf "generate sample: FAIL %s\n" msg;
      incr failures
  | Ok { C_bindgen.header; shim_c } ->
      if
        not
          (check_contains "header signatures" header
             [ "#ifndef OCAMLCC_SAMPLE_H";
               "typedef struct ocamlcc_error_t";
               "typedef struct { int64_t raw; } sample_t_t;";
               "void sample_t_t_retain(sample_t_t h);";
               "void sample_t_t_release(sample_t_t h);";
               "double x;";
               "double y;";
               "} sample_point_t;";
               "const char * name;";
               "int64_t age;";
               "} sample_user_t;";
               "void sample_user_t_free(sample_user_t *v);";
               "ocamlcc_opt_int64_t";
               "ocamlcc_tuple_int64_t_int64_t";
               "void sample_init(void);";
               "sample_t_t sample_create(int64_t a0, ocamlcc_error_t *err);";
               "int64_t sample_get(sample_t_t a0, ocamlcc_error_t *err);";
               "sample_point_t sample_add_pt(sample_point_t a0, sample_point_t a1, ocamlcc_error_t *err);";
               "char * sample_greet(sample_user_t a0, ocamlcc_error_t *err);";
               "ocamlcc_opt_int64_t sample_opt_add(ocamlcc_opt_int64_t a0, int32_t a1, int64_t a2, ocamlcc_error_t *err);";
               "bool sample_flip(bool a0, ocamlcc_error_t *err);";
               "int64_t sample_pair_sum(ocamlcc_tuple_int64_t_int64_t a0, ocamlcc_error_t *err);";
               "void sample_ping(ocamlcc_error_t *err);";
               "int64_t sample_version(ocamlcc_error_t *err);" ])
      then incr failures;
      if
        not
          (check_contains "shim body" shim_c
             [ "#include \"sample.h\"";
               "arc_mutator_enter(void);";
               "arc_mutator_leave(int entered);";
               "extern void ocamlcc_init_Sample(void);";
               "extern int64_t ocamlcc_global_Sample;";
               "ocamlcc_format_exn(ex, err->message, sizeof(err->message))";
               "ocamlcc_set_exn(0);";
               "arc_release_val(ex);";
               "arc_retain_val((a0).raw)";
               "ocamlcc_alloc_float(";
               "ocamlcc_alloc_custom(OCAMLCC_CUSTOM_INT32,";
               "ocamlcc_alloc_custom(OCAMLCC_CUSTOM_INT64,";
               "OCAMLCC_TAG_FLOAT_ARRAY";
               "mod[1]";
               "mod[9]" ])
      then incr failures;
      let gated_ok =
        List.for_all
          (fun fn_prefix -> check_mutator_gated ~fn_prefix shim_c)
          [ "void sample_init(";
            "void sample_t_t_retain(";
            "void sample_t_t_release(";
            "sample_t_t sample_create(";
            "int64_t sample_get(";
            "char * sample_greet(";
            "ocamlcc_opt_int64_t sample_opt_add(";
            "int64_t sample_pair_sum(";
            "void sample_ping(";
            "int64_t sample_version(" ]
      in
      Printf.printf "shim mutator gate: %s\n"
        (if gated_ok then "PASS" else "FAIL");
      if not gated_ok then incr failures);
  (* Unsupported higher-order val must produce an explicit Error. *)
  (match
     C_bindgen.generate ~nopervasives:true ~nostdlib:true ~filename:"bad.mli"
       ~modname:"Bad" "val apply : (int -> int) -> int -> int\n"
   with
  | Ok _ ->
      Printf.printf "reject higher-order: FAIL\n";
      incr failures
  | Error _ -> Printf.printf "reject higher-order: PASS\n");
  (* Dependency-ordered typedefs + _free helpers for option/tuple + const char* free *)
  let nested_mli =
    {|
type item = { tag : string option; pt : int * int }
type bag = { label : string; item : item; opt_pair : (string * int) option }
val make_bag : string option -> string * int -> (int * int) option -> bag
|}
  in
  (match
     C_bindgen.generate ~nopervasives:true ~nostdlib:true
       ~header_include:"nested.h" ~filename:"nested.mli" ~modname:"Nested"
       nested_mli
   with
  | Error msg ->
      Printf.printf "nested typedef order: FAIL %s\n" msg;
      incr failures
  | Ok { C_bindgen.header; shim_c } ->
      let before a b =
        match (find_substr ~sub:a header, find_substr ~sub:b header) with
        | Some pa, Some pb -> pa < pb
        | _ -> false
      in
      let order_ok =
        before "} ocamlcc_opt_cstr_t;" "} nested_item_t;"
        && before "} ocamlcc_tuple_int64_t_int64_t;" "} nested_item_t;"
        && before "} ocamlcc_tuple_cstr_int64_t;"
             "} ocamlcc_opt_tuple_cstr_int64_t;"
        && before "} nested_item_t;" "} nested_bag_t;"
        && before "} ocamlcc_opt_tuple_cstr_int64_t;" "} nested_bag_t;"
        && before "} ocamlcc_tuple_int64_t_int64_t;"
             "} ocamlcc_opt_tuple_int64_t_int64_t;"
      in
      let free_ok =
        has_substr ~sub:"ocamlcc_opt_cstr_t_free(" header
        && has_substr ~sub:"ocamlcc_tuple_cstr_int64_t_free(" header
        && has_substr ~sub:"ocamlcc_opt_tuple_cstr_int64_t_free(" header
        && has_substr ~sub:"nested_item_t_free(" header
        && has_substr ~sub:"nested_bag_t_free(" header
      in
      let tmp =
        Filename.concat (Filename.get_temp_dir_name ())
          (Printf.sprintf "ocamlcc_bindgen_nested_%d" (Unix.getpid ()))
      in
      if not (Sys.file_exists tmp) then Sys.mkdir tmp 0o755;
      let write p s =
        let oc = open_out_bin p in
        output_string oc s;
        close_out oc
      in
      let hdr_p = Filename.concat tmp "nested.h" in
      let shim_p = Filename.concat tmp "nested_shim.c" in
      let use_p = Filename.concat tmp "use_nested.c" in
      let shim_o = Filename.concat tmp "nested_shim.o" in
      let use_o = Filename.concat tmp "use_nested.o" in
      write hdr_p header;
      write shim_p shim_c;
      write use_p
        {|
#include "nested.h"
void test_cleanup(void) {
    ocamlcc_opt_cstr_t o = { true, "x" };
    ocamlcc_free_string(o.value);
    ocamlcc_opt_cstr_t_free(&o);
    ocamlcc_tuple_cstr_int64_t t = { "y", 1 };
    ocamlcc_tuple_cstr_int64_t_free(&t);
    ocamlcc_opt_tuple_cstr_int64_t ot = { true, { "z", 2 } };
    ocamlcc_opt_tuple_cstr_int64_t_free(&ot);
}
|};
      let cc_shim =
        Sys.command
          (Printf.sprintf
             "cc -std=c99 -Wall -Wextra -Werror -I%s -c %s -o %s"
             (Filename.quote tmp) (Filename.quote shim_p)
             (Filename.quote shim_o))
      in
      let cc_use =
        Sys.command
          (Printf.sprintf
             "cc -std=c99 -Wall -Wextra -Werror -I%s -c %s -o %s"
             (Filename.quote tmp) (Filename.quote use_p)
             (Filename.quote use_o))
      in
      List.iter
        (fun f -> if Sys.file_exists f then Sys.remove f)
        [ hdr_p; shim_p; use_p; shim_o; use_o ];
      (try Sys.rmdir tmp with Sys_error _ -> ());
      let ok = order_ok && free_ok && cc_shim = 0 && cc_use = 0 in
      if not ok then
        Printf.printf "debug: order=%b free=%b cc_shim=%d cc_use=%d\n"
          order_ok free_ok cc_shim cc_use;
      Printf.printf "nested typedef order + free: %s\n"
        (if ok then "PASS" else "FAIL");
      if not ok then incr failures);
  exit (if !failures = 0 then 0 else 1)

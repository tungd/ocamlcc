(* .mli -> C99 header (.h) and FFI shim (.c) generator. *)

type generated = {
  header : string;
  shim_c : string;
}

type record_field = {
  rf_name : string;
  rf_type : c_type;
}

and record_info = {
  ri_cname : string;
  ri_is_float : bool;
  ri_is_unboxed : bool;
  ri_fields : record_field list;
}

and c_type =
  | CT_unit
  | CT_int
  | CT_bool
  | CT_char
  | CT_float
  | CT_string
  | CT_int32
  | CT_int64
  | CT_nativeint
  | CT_option of c_type
  | CT_tuple of c_type list
  | CT_record of record_info
  | CT_opaque of string

type exported_val = {
  ev_name : string;
  ev_slot : int;
  ev_params : c_type list;
  ev_ret : c_type;
  ev_is_fn : bool;
}

let sanitize_c s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '_'
      then Buffer.add_char b c
      else Buffer.add_char b '_')
    s;
  let r = Buffer.contents b in
  if r = "" then "_" else r

let read_file filename =
  let ic = open_in_bin filename in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let rec type_key = function
  | CT_unit -> "unit"
  | CT_int -> "int"
  | CT_bool -> "bool"
  | CT_char -> "char"
  | CT_float -> "float"
  | CT_string -> "string"
  | CT_int32 -> "int32"
  | CT_int64 -> "int64"
  | CT_nativeint -> "nativeint"
  | CT_option t -> "opt_" ^ type_key t
  | CT_tuple ts -> "tup_" ^ String.concat "_" (List.map type_key ts)
  | CT_record r -> "rec_" ^ r.ri_cname
  | CT_opaque s -> "opq_" ^ s

let rec c_slug = function
  | CT_unit -> "void"
  | CT_int -> "int64_t"
  | CT_bool -> "bool"
  | CT_char -> "uint8_t"
  | CT_float -> "double"
  | CT_string -> "cstr"
  | CT_int32 -> "int32_t"
  | CT_int64 -> "int64_t"
  | CT_nativeint -> "intptr_t"
  | CT_option t -> "opt_" ^ c_slug t
  | CT_tuple ts -> "tuple_" ^ String.concat "_" (List.map c_slug ts)
  | CT_record r -> r.ri_cname
  | CT_opaque s -> s

let ensure_t_suffix s =
  if String.length s >= 2 && String.sub s (String.length s - 2) 2 = "_t" then s
  else s ^ "_t"

let c_type_in_struct = function
  | CT_unit -> "uint8_t"
  | CT_int -> "int64_t"
  | CT_bool -> "bool"
  | CT_char -> "uint8_t"
  | CT_float -> "double"
  | CT_string -> "const char *"
  | CT_int32 -> "int32_t"
  | CT_int64 -> "int64_t"
  | CT_nativeint -> "intptr_t"
  | CT_option t -> ensure_t_suffix ("ocamlcc_opt_" ^ c_slug t)
  | CT_tuple ts -> "ocamlcc_tuple_" ^ String.concat "_" (List.map c_slug ts)
  | CT_record r -> r.ri_cname
  | CT_opaque s -> s

let c_type_param = c_type_in_struct

let c_type_ret = function
  | CT_unit -> "void"
  | CT_string -> "char *"
  | t -> c_type_in_struct t

let rec needs_free = function
  | CT_string | CT_opaque _ -> true
  | CT_option t -> needs_free t
  | CT_tuple ts -> List.exists needs_free ts
  | CT_record r -> List.exists (fun rf -> needs_free rf.rf_type) r.ri_fields
  | CT_unit | CT_int | CT_bool | CT_char | CT_float
  | CT_int32 | CT_int64 | CT_nativeint -> false

let zero_expr = function
  | CT_unit -> ""
  | CT_int | CT_int64 -> "0"
  | CT_int32 -> "0"
  | CT_nativeint -> "0"
  | CT_bool -> "false"
  | CT_char -> "0"
  | CT_float -> "0.0"
  | CT_string -> "NULL"
  | CT_option _ | CT_tuple _ | CT_record _ | CT_opaque _ -> "{0}"

type header_decl =
  | HD_opaque of string
  | HD_record of record_info
  | HD_option of string * c_type
  | HD_tuple of string * c_type list

let translate_signature ~modname sg env =
  let mod_prefix = sanitize_c (String.uncapitalize_ascii modname) in
  let local_types : (string, c_type) Hashtbl.t = Hashtbl.create 16 in
  let decls_rev = ref [] in
  let seen_header_decls = Hashtbl.create 16 in
  let header_decls_rev = ref [] in
  let rec register_decl = function
    | CT_opaque cname ->
        if not (Hashtbl.mem seen_header_decls cname) then begin
          Hashtbl.add seen_header_decls cname ();
          header_decls_rev := HD_opaque cname :: !header_decls_rev
        end
    | CT_record r ->
        if not (Hashtbl.mem seen_header_decls r.ri_cname) then begin
          List.iter (fun rf -> register_decl rf.rf_type) r.ri_fields;
          Hashtbl.add seen_header_decls r.ri_cname ();
          header_decls_rev := HD_record r :: !header_decls_rev
        end
    | CT_option inner ->
        let sname = c_type_in_struct (CT_option inner) in
        if not (Hashtbl.mem seen_header_decls sname) then begin
          register_decl inner;
          Hashtbl.add seen_header_decls sname ();
          header_decls_rev := HD_option (sname, inner) :: !header_decls_rev
        end
    | CT_tuple ts ->
        let sname = c_type_in_struct (CT_tuple ts) in
        if not (Hashtbl.mem seen_header_decls sname) then begin
          List.iter register_decl ts;
          Hashtbl.add seen_header_decls sname ();
          header_decls_rev := HD_tuple (sname, ts) :: !header_decls_rev
        end
    | CT_unit | CT_int | CT_bool | CT_char | CT_float
    | CT_string | CT_int32 | CT_int64 | CT_nativeint -> ()
  in
  let rec resolve_type ?(seen = []) ~ctx ty =
    let ty = Ctype.expand_head env ty in
    match Types.get_desc ty with
    | Types.Tconstr (path, args, _) ->
        if Path.same path Predef.path_unit && args = [] then CT_unit
        else if Path.same path Predef.path_int && args = [] then CT_int
        else if Path.same path Predef.path_bool && args = [] then CT_bool
        else if Path.same path Predef.path_char && args = [] then CT_char
        else if Path.same path Predef.path_float && args = [] then CT_float
        else if Path.same path Predef.path_string && args = [] then CT_string
        else if Path.same path Predef.path_int32 && args = [] then CT_int32
        else if Path.same path Predef.path_int64 && args = [] then CT_int64
        else if Path.same path Predef.path_nativeint && args = [] then CT_nativeint
        else if Path.same path Predef.path_option then (
          match args with
          | [ inner ] ->
              let t = resolve_type ~seen ~ctx inner in
              if t = CT_unit then
                failwith (ctx ^ ": unit option is unsupported in C FFI");
              CT_option t
          | _ -> failwith (ctx ^ ": invalid option type"))
        else
          let pname = Path.name path in
          if List.mem pname seen then
            failwith (ctx ^ ": recursive type " ^ pname ^ " is unsupported in C FFI")
          else (
            match Hashtbl.find_opt local_types pname with
            | Some ct when args = [] -> ct
            | _ ->
                failwith
                  (Printf.sprintf "%s: unsupported type %s" ctx pname))
    | Types.Ttuple fields ->
        let ts =
          List.map
            (fun (_, fty) ->
              let t = resolve_type ~seen ~ctx fty in
              if t = CT_unit then
                failwith (ctx ^ ": unit inside tuple is unsupported in C FFI");
              t)
            fields
        in
        CT_tuple ts
    | Types.Tpoly (ty', _) -> resolve_type ~seen ~ctx ty'
    | Types.Tarrow _ ->
        failwith (ctx ^ ": higher-order function types are unsupported in C FFI")
    | Types.Tvar _ ->
        failwith (ctx ^ ": polymorphic type variables are unsupported in C FFI")
    | _ ->
        let desc_str = Format.asprintf "%a" Printtyp.type_expr ty in
        failwith (ctx ^ ": unsupported type expression in C FFI: " ^ desc_str)
  in
  let rec uncurry_val ty =
    let ty' = Ctype.expand_head env ty in
    match Types.get_desc ty' with
    | Types.Tpoly (inner, _) -> uncurry_val inner
    | Types.Tarrow (_, arg, ret, _) ->
        let params, r = uncurry_val ret in
        (arg :: params, r)
    | _ -> ([], ty')
  in
  let vals_rev = ref [] in
  let slot = ref 0 in
  List.iter
    (fun item ->
      match item with
      | Types.Sig_type (id, td, _, _) ->
          let tname = Ident.name id in
          let cname = Printf.sprintf "%s_%s_t" mod_prefix (sanitize_c tname) in
          if td.Types.type_params = [] then (
            match td.Types.type_kind with
            | Types.Type_abstract _ when td.Types.type_manifest = None ->
                let ct = CT_opaque cname in
                Hashtbl.replace local_types tname ct;
                register_decl ct;
                decls_rev := ct :: !decls_rev
            | Types.Type_record (labels, rep) ->
                let is_float =
                  match rep with Types.Record_float -> true | _ -> false
                in
                let is_unboxed =
                  match rep with
                  | Types.Record_unboxed _ -> true
                  | _ -> false
                in
                let ctx = "type " ^ tname in
                let rf_fields =
                  List.map
                    (fun (ld : Types.label_declaration) ->
                      let ft = resolve_type ~seen:[ tname ] ~ctx ld.ld_type in
                      { rf_name = sanitize_c (Ident.name ld.ld_id); rf_type = ft })
                    labels
                in
                let ri =
                  { ri_cname = cname;
                    ri_is_float = is_float;
                    ri_is_unboxed = is_unboxed;
                    ri_fields = rf_fields }
                in
                let ct = CT_record ri in
                Hashtbl.replace local_types tname ct;
                register_decl ct;
                decls_rev := ct :: !decls_rev
            | _ -> ())
      | Types.Sig_value (id, vd, _) ->
          let is_prim =
            match vd.Types.val_kind with Types.Val_prim _ -> true | _ -> false
          in
          if not is_prim then begin
            let cur_slot = !slot in
            incr slot;
            let vname = Ident.name id in
            let ctx = "val " ^ vname in
            let raw_params, raw_ret = uncurry_val vd.Types.val_type in
            let params =
              List.map (fun p -> resolve_type ~ctx p) raw_params
            in
            let params =
              match params with [ CT_unit ] -> [] | ps -> ps
            in
            List.iter register_decl params;
            let ret = resolve_type ~ctx raw_ret in
            register_decl ret;
            vals_rev :=
              { ev_name = sanitize_c vname;
                ev_slot = cur_slot;
                ev_params = params;
                ev_ret = ret;
                ev_is_fn = raw_params <> [] }
              :: !vals_rev
          end
      | Types.Sig_module (_, _, md, _, _) -> (
          match md.Types.md_type with
          | Types.Mty_alias _ -> ()
          | _ -> incr slot)
      | Types.Sig_typext _ | Types.Sig_class _ -> incr slot
      | Types.Sig_modtype _ | Types.Sig_class_type _ -> ())
    sg.Typedtree.sig_type;
  ( mod_prefix,
    List.rev !decls_rev,
    List.rev !header_decls_rev,
    List.rev !vals_rev )

let emit_free_field ?(indent = "    ") b ptr t =
  let p fmt = Printf.bprintf b fmt in
  match t with
  | CT_string -> p "%socamlcc_free_string(%s);\n" indent ptr
  | CT_opaque cname -> p "%s%s_release(%s);\n" indent cname ptr
  | CT_option inner when needs_free inner ->
      let sname = c_type_in_struct (CT_option inner) in
      p "%s%s_free(&(%s));\n" indent sname ptr
  | CT_tuple ts when List.exists needs_free ts ->
      let sname = c_type_in_struct (CT_tuple ts) in
      p "%s%s_free(&(%s));\n" indent sname ptr
  | CT_record r2 when needs_free (CT_record r2) ->
      p "%s%s_free(&(%s));\n" indent r2.ri_cname ptr
  | _ -> ()

let emit_header ~modname ~mod_prefix header_decls vals =
  let b = Buffer.create 2048 in
  let p fmt = Printf.bprintf b fmt in
  let guard = "OCAMLCC_" ^ String.uppercase_ascii mod_prefix ^ "_H" in
  p "#ifndef %s\n#define %s\n\n" guard guard;
  p "#include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n#include <stdlib.h>\n\n";
  p "#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n";
  p "#ifndef OCAMLCC_ERROR_T_DEFINED\n#define OCAMLCC_ERROR_T_DEFINED\n";
  p "typedef struct ocamlcc_error_t {\n";
  p "    int32_t code;\n";
  p "    char message[256];\n";
  p "} ocamlcc_error_t;\n";
  p "#endif\n\n";
  p "#ifndef OCAMLCC_FREE_STRING_DECLARED\n#define OCAMLCC_FREE_STRING_DECLARED\n";
  p "static inline void ocamlcc_free_string(const char *s) {\n";
  p "    free((void *)(uintptr_t)s);\n";
  p "}\n";
  p "#endif\n\n";
  List.iter
    (function
      | HD_opaque cname ->
          p "typedef struct { int64_t raw; } %s;\n" cname;
          p "void %s_retain(%s h);\n" cname cname;
          p "void %s_release(%s h);\n\n" cname cname
      | HD_record r ->
          p "typedef struct {\n";
          List.iter
            (fun rf -> p "    %s %s;\n" (c_type_in_struct rf.rf_type) rf.rf_name)
            r.ri_fields;
          p "} %s;\n" r.ri_cname;
          if needs_free (CT_record r) then
            p "void %s_free(%s *v);\n" r.ri_cname r.ri_cname;
          p "\n"
      | HD_option (sname, inner) ->
          let dg = "OCAMLCC_DEF_" ^ String.uppercase_ascii sname in
          p "#ifndef %s\n#define %s\n" dg dg;
          p "typedef struct {\n    bool is_some;\n    %s value;\n} %s;\n"
            (c_type_in_struct inner) sname;
          if needs_free (CT_option inner) then begin
            p "static inline void %s_free(%s *v) {\n" sname sname;
            p "    if (v == NULL)\n        return;\n";
            p "    if (v->is_some) {\n";
            emit_free_field ~indent:"        " b "v->value" inner;
            p "    }\n";
            p "}\n"
          end;
          p "#endif\n\n"
      | HD_tuple (sname, ts) ->
          let dg = "OCAMLCC_DEF_" ^ String.uppercase_ascii sname in
          p "#ifndef %s\n#define %s\n" dg dg;
          p "typedef struct {\n";
          List.iteri
            (fun i t -> p "    %s f%d;\n" (c_type_in_struct t) i)
            ts;
          p "} %s;\n" sname;
          if needs_free (CT_tuple ts) then begin
            p "static inline void %s_free(%s *v) {\n" sname sname;
            p "    if (v == NULL)\n        return;\n";
            List.iteri
              (fun i ft ->
                if needs_free ft then
                  emit_free_field b (Printf.sprintf "v->f%d" i) ft)
              ts;
            p "}\n"
          end;
          p "#endif\n\n")
    header_decls;
  p "void %s_init(void);\n\n" mod_prefix;
  ignore modname;
  List.iter
    (fun ev ->
      let args =
        List.mapi
          (fun i t -> Printf.sprintf "%s a%d" (c_type_param t) i)
          ev.ev_params
        @ [ "ocamlcc_error_t *err" ]
      in
      p "%s %s_%s(%s);\n" (c_type_ret ev.ev_ret) mod_prefix ev.ev_name
        (String.concat ", " args))
    vals;
  p "\n#ifdef __cplusplus\n}\n#endif\n\n#endif /* %s */\n" guard;
  Buffer.contents b

let emit_shim ~modname ~mod_prefix ~header_include decls vals =
  let b = Buffer.create 4096 in
  let p fmt = Printf.bprintf b fmt in
  let mod_sym = sanitize_c modname in
  p "#include \"%s\"\n" header_include;
  p "#include <stdlib.h>\n#include <string.h>\n\n";
  p "#if defined(__GNUC__) || defined(__clang__)\n";
  p "#define OCAMLCC_UNUSED __attribute__((unused))\n";
  p "#else\n#define OCAMLCC_UNUSED\n#endif\n\n";
  p "#define OCAMLCC_TAG_STRING 252u\n";
  p "#define OCAMLCC_TAG_FLOAT_ARRAY 254u\n";
  p "#define OCAMLCC_CUSTOM_INT32 0u\n";
  p "#define OCAMLCC_CUSTOM_INT64 1u\n";
  p "#define OCAMLCC_CUSTOM_NATIVEINT 2u\n\n";
  p "extern void *arc_alloc(uint16_t tag, uint16_t scan_fields, uint32_t byte_size);\n";
  p "extern void *arc_alloc_bytes(uint64_t len);\n";
  p "extern void  arc_retain_val(int64_t val);\n";
  p "extern void  arc_release_val(int64_t val);\n";
  p "extern int   arc_mutator_enter(void);\n";
  p "extern void  arc_mutator_leave(int entered);\n";
  p "extern int64_t ocamlcc_alloc_float(double d);\n";
  p "extern int64_t ocamlcc_alloc_custom(uint32_t kind, uint64_t bits);\n";
  p "extern int64_t ocamlcc_get_exn(void);\n";
  p "extern void    ocamlcc_set_exn(int64_t exn);\n";
  p "extern void    ocamlcc_format_exn(int64_t ex, char *buf, size_t cap);\n";
  p "extern int64_t ocamlcc_apply1(int64_t clos, int64_t a0);\n";
  p "extern int64_t ocamlcc_apply2(int64_t clos, int64_t a0, int64_t a1);\n";
  p "extern int64_t ocamlcc_apply3(int64_t clos, int64_t a0, int64_t a1, int64_t a2);\n";
  p "extern int64_t ocamlcc_apply4(int64_t clos, int64_t a0, int64_t a1, int64_t a2, int64_t a3);\n";
  p "extern int64_t ocamlcc_apply_n(int64_t clos, int64_t argc, int64_t *argv);\n\n";
  p "extern void ocamlcc_init_%s(void);\n" mod_sym;
  p "extern int64_t ocamlcc_global_%s;\n\n" mod_sym;
  p "static inline int64_t ocamlcc_shim_tag_int(int64_t n) {\n";
  p "    return (int64_t)(((uint64_t)n << 1) | 1ull);\n";
  p "}\n\n";
  p "OCAMLCC_UNUSED static int64_t ocamlcc_shim_cstr_to_ocaml(const char *s) {\n";
  p "    size_t len = (s != NULL) ? strlen(s) : 0u;\n";
  p "    char *buf = (char *)arc_alloc_bytes((uint64_t)len);\n";
  p "    if (len > 0u)\n        memcpy(buf, s, len);\n";
  p "    return (int64_t)(uintptr_t)buf;\n";
  p "}\n\n";
  p "OCAMLCC_UNUSED static char *ocamlcc_shim_ocaml_to_cstr(int64_t v) {\n";
  p "    const uint32_t *hdr = (const uint32_t *)(uintptr_t)v - 4;\n";
  p "    uint32_t len = hdr[3];\n";
  p "    char *out = (char *)malloc((size_t)len + 1u);\n";
  p "    if (out != NULL) {\n";
  p "        if (len > 0u)\n            memcpy(out, (const void *)(uintptr_t)v, (size_t)len);\n";
  p "        out[len] = '\\0';\n";
  p "    }\n";
  p "    return out;\n";
  p "}\n\n";
  p "OCAMLCC_UNUSED static void ocamlcc_shim_clear_err(ocamlcc_error_t *err) {\n";
  p "    if (err != NULL) {\n        err->code = 0;\n        err->message[0] = '\\0';\n    }\n";
  p "}\n\n";
  p "OCAMLCC_UNUSED static int ocamlcc_shim_check_exn(ocamlcc_error_t *err) {\n";
  p "    int64_t ex = ocamlcc_get_exn();\n";
  p "    if (ex == 0)\n        return 0;\n";
  p "    ocamlcc_set_exn(0);\n";
  p "    if (err != NULL) {\n";
  p "        err->code = 1;\n";
  p "        ocamlcc_format_exn(ex, err->message, sizeof(err->message));\n";
  p "    }\n";
  p "    arc_release_val(ex);\n";
  p "    return 1;\n";
  p "}\n\n";
  let emitted_helpers = Hashtbl.create 16 in
  let rec ensure_helpers t =
    let k = type_key t in
    if not (Hashtbl.mem emitted_helpers k) then begin
      Hashtbl.add emitted_helpers k ();
      match t with
      | CT_option inner ->
          ensure_helpers inner;
          let ct = c_type_in_struct t in
          p "OCAMLCC_UNUSED static int64_t shim_to_ocaml_%s(%s v) {\n" k ct;
          p "    if (!v.is_some)\n        return 1ll;\n";
          p "    int64_t *blk = (int64_t *)arc_alloc(0u, 1u, 8u);\n";
          p "    blk[0] = %s;\n" (to_ocaml_expr inner "v.value");
          p "    return (int64_t)(uintptr_t)blk;\n";
          p "}\n\n";
          p "OCAMLCC_UNUSED static %s shim_from_ocaml_%s(int64_t v) {\n" ct k;
          p "    %s out;\n" ct;
          p "    if (v == 1ll) {\n        out.is_some = false;\n        memset(&out.value, 0, sizeof(out.value));\n        return out;\n    }\n";
          p "    out.is_some = true;\n";
          p "    const int64_t *blk = (const int64_t *)(uintptr_t)v;\n";
          p "    out.value = %s;\n" (from_ocaml_expr inner "blk[0]");
          p "    return out;\n";
          p "}\n\n"
      | CT_tuple ts ->
          List.iter ensure_helpers ts;
          let ct = c_type_in_struct t in
          let n = List.length ts in
          p "OCAMLCC_UNUSED static int64_t shim_to_ocaml_%s(%s v) {\n" k ct;
          p "    int64_t *blk = (int64_t *)arc_alloc(0u, %du, %du);\n" n (8 * n);
          List.iteri
            (fun i ft ->
              p "    blk[%d] = %s;\n" i
                (to_ocaml_expr ft (Printf.sprintf "v.f%d" i)))
            ts;
          p "    return (int64_t)(uintptr_t)blk;\n";
          p "}\n\n";
          p "OCAMLCC_UNUSED static %s shim_from_ocaml_%s(int64_t v) {\n" ct k;
          p "    %s out;\n" ct;
          p "    const int64_t *blk = (const int64_t *)(uintptr_t)v;\n";
          List.iteri
            (fun i ft ->
              p "    out.f%d = %s;\n" i
                (from_ocaml_expr ft (Printf.sprintf "blk[%d]" i)))
            ts;
          p "    return out;\n";
          p "}\n\n"
      | CT_record r ->
          List.iter (fun rf -> ensure_helpers rf.rf_type) r.ri_fields;
          let ct = r.ri_cname in
          let n = List.length r.ri_fields in
          p "OCAMLCC_UNUSED static int64_t shim_to_ocaml_%s(%s v) {\n" k ct;
          if r.ri_is_unboxed then begin
            let rf = List.hd r.ri_fields in
            p "    return %s;\n" (to_ocaml_expr rf.rf_type ("v." ^ rf.rf_name))
          end
          else if r.ri_is_float then begin
            p "    double *blk = (double *)arc_alloc(OCAMLCC_TAG_FLOAT_ARRAY, 0u, %du);\n"
              (8 * n);
            List.iteri
              (fun i rf -> p "    blk[%d] = v.%s;\n" i rf.rf_name)
              r.ri_fields;
            p "    return (int64_t)(uintptr_t)blk;\n"
          end
          else begin
            p "    int64_t *blk = (int64_t *)arc_alloc(0u, %du, %du);\n" n (8 * n);
            List.iteri
              (fun i rf ->
                p "    blk[%d] = %s;\n" i
                  (to_ocaml_expr rf.rf_type ("v." ^ rf.rf_name)))
              r.ri_fields;
            p "    return (int64_t)(uintptr_t)blk;\n"
          end;
          p "}\n\n";
          p "OCAMLCC_UNUSED static %s shim_from_ocaml_%s(int64_t v) {\n" ct k;
          p "    %s out;\n" ct;
          if r.ri_is_unboxed then begin
            let rf = List.hd r.ri_fields in
            p "    out.%s = %s;\n" rf.rf_name (from_ocaml_expr rf.rf_type "v")
          end
          else if r.ri_is_float then begin
            p "    const double *blk = (const double *)(uintptr_t)v;\n";
            List.iteri
              (fun i rf -> p "    out.%s = blk[%d];\n" rf.rf_name i)
              r.ri_fields
          end
          else begin
            p "    const int64_t *blk = (const int64_t *)(uintptr_t)v;\n";
            List.iteri
              (fun i rf ->
                p "    out.%s = %s;\n" rf.rf_name
                  (from_ocaml_expr rf.rf_type (Printf.sprintf "blk[%d]" i)))
              r.ri_fields
          end;
          p "    return out;\n";
          p "}\n\n"
      | _ -> ()
    end
  and to_ocaml_expr t expr =
    match t with
    | CT_unit -> Printf.sprintf "((void)(%s), 1ll)" expr
    | CT_int -> Printf.sprintf "ocamlcc_shim_tag_int(%s)" expr
    | CT_bool -> Printf.sprintf "((%s) ? 3ll : 1ll)" expr
    | CT_char -> Printf.sprintf "ocamlcc_shim_tag_int((int64_t)(uint8_t)(%s))" expr
    | CT_float -> Printf.sprintf "ocamlcc_alloc_float(%s)" expr
    | CT_string -> Printf.sprintf "ocamlcc_shim_cstr_to_ocaml(%s)" expr
    | CT_int32 ->
        Printf.sprintf "ocamlcc_alloc_custom(OCAMLCC_CUSTOM_INT32, (uint64_t)(int64_t)(%s))" expr
    | CT_int64 ->
        Printf.sprintf "ocamlcc_alloc_custom(OCAMLCC_CUSTOM_INT64, (uint64_t)(%s))" expr
    | CT_nativeint ->
        Printf.sprintf "ocamlcc_alloc_custom(OCAMLCC_CUSTOM_NATIVEINT, (uint64_t)(int64_t)(%s))" expr
    | CT_opaque _ ->
        Printf.sprintf "(arc_retain_val((%s).raw), (%s).raw)" expr expr
    | CT_option _ | CT_tuple _ | CT_record _ ->
        Printf.sprintf "shim_to_ocaml_%s(%s)" (type_key t) expr
  and from_ocaml_expr t expr =
    match t with
    | CT_unit -> Printf.sprintf "((void)(%s))" expr
    | CT_int -> Printf.sprintf "(int64_t)((%s) >> 1)" expr
    | CT_bool -> Printf.sprintf "(((%s) >> 1) != 0)" expr
    | CT_char -> Printf.sprintf "(uint8_t)((%s) >> 1)" expr
    | CT_float -> Printf.sprintf "(*(const double *)(uintptr_t)(%s))" expr
    | CT_string -> Printf.sprintf "ocamlcc_shim_ocaml_to_cstr(%s)" expr
    | CT_int32 -> Printf.sprintf "(int32_t)(*(const int64_t *)(uintptr_t)(%s))" expr
    | CT_int64 -> Printf.sprintf "(*(const int64_t *)(uintptr_t)(%s))" expr
    | CT_nativeint -> Printf.sprintf "(intptr_t)(*(const int64_t *)(uintptr_t)(%s))" expr
    | CT_opaque cname ->
        Printf.sprintf "(arc_retain_val(%s), (%s){ .raw = (%s) })" expr cname expr
    | CT_option _ | CT_tuple _ | CT_record _ ->
        Printf.sprintf "shim_from_ocaml_%s(%s)" (type_key t) expr
  in
  List.iter
    (function
      | CT_record r -> ensure_helpers (CT_record r)
      | _ -> ())
    decls;
  List.iter
    (fun ev ->
      List.iter ensure_helpers ev.ev_params;
      ensure_helpers ev.ev_ret)
    vals;
  p "void %s_init(void) {\n" mod_prefix;
  p "    int _entered = arc_mutator_enter();\n";
  p "    ocamlcc_init_%s();\n" mod_sym;
  p "    arc_mutator_leave(_entered);\n";
  p "}\n\n";
  List.iter
    (function
      | CT_opaque cname ->
          p "void %s_retain(%s h) {\n" cname cname;
          p "    int _entered = arc_mutator_enter();\n";
          p "    arc_retain_val(h.raw);\n";
          p "    arc_mutator_leave(_entered);\n";
          p "}\n";
          p "void %s_release(%s h) {\n" cname cname;
          p "    int _entered = arc_mutator_enter();\n";
          p "    arc_release_val(h.raw);\n";
          p "    arc_mutator_leave(_entered);\n";
          p "}\n\n"
      | CT_record r when needs_free (CT_record r) ->
          p "void %s_free(%s *v) {\n" r.ri_cname r.ri_cname;
          p "    if (v == NULL)\n        return;\n";
          List.iter
            (fun rf ->
              if needs_free rf.rf_type then
                emit_free_field b ("v->" ^ rf.rf_name) rf.rf_type)
            r.ri_fields;
          p "}\n\n"
      | _ -> ())
    decls;
  List.iter
    (fun ev ->
      let args =
        List.mapi
          (fun i t -> Printf.sprintf "%s a%d" (c_type_param t) i)
          ev.ev_params
        @ [ "ocamlcc_error_t *err" ]
      in
      p "%s %s_%s(%s) {\n" (c_type_ret ev.ev_ret) mod_prefix ev.ev_name
        (String.concat ", " args);
      p "    int _entered = arc_mutator_enter();\n";
      p "    const int64_t *mod = (const int64_t *)(uintptr_t)ocamlcc_global_%s;\n"
        mod_sym;
      if not ev.ev_is_fn then begin
        p "    int64_t res = mod[%d];\n" ev.ev_slot;
        p "    ocamlcc_shim_clear_err(err);\n";
        (match ev.ev_ret with
        | CT_unit ->
            p "    (void)res;\n";
            p "    arc_mutator_leave(_entered);\n"
        | t ->
            p "    %s out = %s;\n" (c_type_ret t) (from_ocaml_expr t "res");
            p "    arc_mutator_leave(_entered);\n";
            p "    return out;\n")
      end
      else begin
        let clos_expr = Printf.sprintf "mod[%d]" ev.ev_slot in
        let call_expr =
          match ev.ev_params with
          | [] -> Printf.sprintf "ocamlcc_apply1(%s, 1ll)" clos_expr
          | [ a0 ] ->
              Printf.sprintf "ocamlcc_apply1(%s, %s)" clos_expr
                (to_ocaml_expr a0 "a0")
          | [ a0; a1 ] ->
              Printf.sprintf "ocamlcc_apply2(%s, %s, %s)" clos_expr
                (to_ocaml_expr a0 "a0") (to_ocaml_expr a1 "a1")
          | [ a0; a1; a2 ] ->
              Printf.sprintf "ocamlcc_apply3(%s, %s, %s, %s)" clos_expr
                (to_ocaml_expr a0 "a0") (to_ocaml_expr a1 "a1")
                (to_ocaml_expr a2 "a2")
          | [ a0; a1; a2; a3 ] ->
              Printf.sprintf "ocamlcc_apply4(%s, %s, %s, %s, %s)" clos_expr
                (to_ocaml_expr a0 "a0") (to_ocaml_expr a1 "a1")
                (to_ocaml_expr a2 "a2") (to_ocaml_expr a3 "a3")
          | ps ->
              let n = List.length ps in
              p "    int64_t argv[%d];\n" n;
              List.iteri
                (fun i t ->
                  p "    argv[%d] = %s;\n" i
                    (to_ocaml_expr t (Printf.sprintf "a%d" i)))
                ps;
              Printf.sprintf "ocamlcc_apply_n(%s, %d, argv)" clos_expr n
        in
        p "    int64_t res = %s;\n" call_expr;
        p "    if (ocamlcc_shim_check_exn(err)) {\n";
        (match ev.ev_ret with
        | CT_unit ->
            p "        arc_mutator_leave(_entered);\n";
            p "        return;\n"
        | t ->
            p "        arc_mutator_leave(_entered);\n";
            p "        return (%s)%s;\n" (c_type_ret t) (zero_expr t));
        p "    }\n";
        p "    ocamlcc_shim_clear_err(err);\n";
        match ev.ev_ret with
        | CT_unit ->
            p "    arc_release_val(res);\n";
            p "    arc_mutator_leave(_entered);\n"
        | CT_opaque cname ->
            p "    %s out = (%s){ .raw = res };\n" cname cname;
            p "    arc_mutator_leave(_entered);\n";
            p "    return out;\n"
        | t ->
            p "    %s out = %s;\n" (c_type_ret t) (from_ocaml_expr t "res");
            p "    arc_release_val(res);\n";
            p "    arc_mutator_leave(_entered);\n";
            p "    return out;\n"
      end;
      p "}\n\n")
    vals;
  Buffer.contents b

let generate ?(include_dirs = []) ?(nopervasives = false) ?(nostdlib = false)
    ?header_include ~filename ~modname source : (generated, string) result =
  match
    Frontend.with_typed_interface ~include_dirs ~nopervasives ~nostdlib ~filename
      source (fun sg env ->
        try
          let mod_prefix, decls, header_decls, vals =
            translate_signature ~modname sg env
          in
          let hdr_inc =
            match header_include with
            | Some h -> h
            | None -> mod_prefix ^ ".h"
          in
          let header =
            emit_header ~modname ~mod_prefix header_decls vals
          in
          let shim_c =
            emit_shim ~modname ~mod_prefix ~header_include:hdr_inc decls vals
          in
          Ok { header; shim_c }
        with Failure msg -> Error msg)
  with
  | Error { msg } -> Error msg
  | Ok r -> r

let generate_file ?(include_dirs = []) ?(nopervasives = false)
    ?(nostdlib = false) ?header_include ~filename ~modname () :
    (generated, string) result =
  match read_file filename with
  | exception Sys_error msg -> Error msg
  | source ->
      generate ~include_dirs ~nopervasives ~nostdlib ?header_include ~filename
        ~modname source

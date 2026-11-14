(* Builtins: resolves Lambda expressions denoting known Stdlib entry points
   to ocamlcc runtime symbols.

   In Lambda, Stdlib entry points surface as field loads from the Stdlib
   module block, e.g. [(field_imm 43 (global Stdlib!))]. The field offsets
   are an implementation detail of the linked compiler-libs, so instead of
   hardcoding them we probe that very compiler with tiny reference programs
   and learn the rendered form of each builtin. *)

type arg_kind =
  | Int_arg    (* tagged 63-bit integer; codegen untags before the call *)
  | String_arg (* raw pointer to a NUL-terminated byte sequence *)

type builtin = { symbol : string; arg_kind : arg_kind }

let render (lam : Lambda.lambda) : string =
  let buf = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer buf in
  Format.fprintf ppf "%a" Printlambda.lambda lam;
  Format.pp_print_flush ppf ();
  String.trim (Buffer.contents buf)

(* The first application node in a Lambda tree, if any. *)
let rec find_apply (lam : Lambda.lambda) : Lambda.lambda option =
  match lam with
  | Lapply { ap_func; _ } -> Some ap_func
  | Llet (_, _, _, arg, body) | Lmutlet (_, _, arg, body) -> (
      match find_apply arg with
      | Some func -> Some func
      | None -> find_apply body)
  | Lsequence (a, b) -> (
      match find_apply a with
      | Some func -> Some func
      | None -> find_apply b)
  | Levent (l, _) | Lifused (_, l) -> find_apply l
  | Lifthenelse (c, t, e) -> (
      match find_apply c with
      | Some func -> Some func
      | None -> (
          match find_apply t with
          | Some func -> Some func
          | None -> find_apply e))
  | Lprim (_, args, _) -> List.find_map find_apply args
  | _ -> None

(* (builtin name, probe argument, runtime symbol, argument kind) *)
let probes =
  [ ("print_int", "1", "ocamlcc_print_int", Int_arg);
    ("print_string", "\"x\"", "ocamlcc_print_string", String_arg);
    ("print_endline", "\"x\"", "ocamlcc_print_endline", String_arg);
    ("exit", "0", "ocamlcc_exit", Int_arg) ]

let table : (string * builtin) list Lazy.t =
  lazy
    (List.filter_map
       (fun (name, arg, symbol, arg_kind) ->
         let src = Printf.sprintf "let () = %s %s" name arg in
         match
           Frontend.compile_implementation ~filename:"builtins-probe.ml"
             ~modname:"Builtins_probe" src
         with
         | Ok program -> (
             match find_apply program.code with
             | Some func ->
                 Some (render func, { symbol; arg_kind })
             | None -> None)
         | Error _ -> None)
       probes)

let resolve (func : Lambda.lambda) : builtin option =
  List.assoc_opt (render func) (Lazy.force table)

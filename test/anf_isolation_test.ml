type _ Effect.t += Import_requested : unit Effect.t

type step =
  | Finished of Anf.program
  | Paused of (unit -> step)

let lambda =
  let open Lambda in
  let loc = Debuginfo.Scoped_location.Loc_unknown in
  let provider = Ident.create_persistent "Provider" in
  let global = Lprim (Pgetglobal provider, [], loc) in
  let read = Lprim (Pfield (0, Pointer, Immutable), [global], loc) in
  let code =
    Lapply { ap_func = read; ap_args = [Lconst (Const_int 1)];
             ap_loc = loc; ap_tailcall = Default_tailcall;
             ap_inlined = Default_inline; ap_specialised = Default_specialise }
  in
  { module_ident = Ident.create_persistent "Consumer"; main_module_block_size = 0;
    required_globals = Ident.Set.singleton provider; code }

let start symbol =
  let fn : Anf.imported_function =
    { symbol; unit_name = "Provider"; arity = 1; yields = false;
      borrowed_entry = None; raises = No_raise; returns_immediate = true;
      unicode_validation = None; inline_leaf = None; inline_lambda = None }
  in
  let first_request = ref true in
  let load_exports unit_name =
    assert (unit_name = "Provider");
    if !first_request then begin
      first_request := false;
      Effect.perform Import_requested
    end;
    Some [[0], fn]
  in
  Effect.Deep.try_with
    (fun () ->
      match Anf.lower ~use_builtins:false ~load_exports ~collect_exports:false lambda with
      | Ok (program, _) -> Finished program
      | Error msg -> failwith msg)
    ()
    { effc = fun (type a) (operation : a Effect.t) ->
        match operation with
        | Import_requested ->
            Some (fun (k : (a, step) Effect.Deep.continuation) ->
                Paused (fun () -> Effect.Deep.continue k ()))
        | _ -> None }

let resume = function
  | Paused next -> next ()
  | Finished _ -> failwith "expected import lookup to suspend"

let check expected = function
  | Finished { Anf.code = Let (_, DirectApp (fn, _), _); _ } ->
      if fn.symbol <> expected then
        failwith (Printf.sprintf "expected import %s, got %s" expected fn.symbol)
  | Finished _ -> failwith ("expected a direct call to " ^ expected)
  | Paused _ -> failwith "unexpected second suspension"

let () =
  let first = start "provider_first" in
  let second = start "provider_second" in
  check "provider_first" (resume first);
  check "provider_second" (resume second)

(** Test-only adapter, not the B0 implementation. Every comparison is executed;
    failed checks abort the current test and produce a nonzero suite exit. *)
module Test = struct
  module Fmt = B0_std.Fmt

  module Eq = struct
    module type S = sig
      type t
      val equal : t -> t -> bool
      val pp : Format.formatter -> t -> unit
    end
    type 'a t = (module S with type t = 'a)
    let make (type a) ?(equal = ( = )) ~pp () : a t =
      (module struct type t = a let equal = equal let pp = pp end)
    let int = make ~pp:Format.pp_print_int ()
  end

  let checks = ref 0
  let passed = ref 0
  let failed = ref 0
  let position = function
    | None -> ""
    | Some (file, line, first, last) ->
        Printf.sprintf "%s:%d:%d-%d: " file line first last
  let fail ?__POS__ message = failwith (position __POS__ ^ message)

  let eq (type a) ?__POS__ (module E : Eq.S with type t = a) actual expected =
    incr checks;
    if not (E.equal actual expected) then
      fail ?__POS__ (Format.asprintf "actual %a; expected %a" E.pp actual E.pp expected)
  let int ?__POS__ = eq ?__POS__ Eq.int
  let bool ?__POS__ = eq ?__POS__ (Eq.make ~pp:Format.pp_print_bool ())
  let float ?__POS__ = eq ?__POS__ (Eq.make ~equal:Float.equal ~pp:Format.pp_print_float ())
  let string ?__POS__ = eq ?__POS__ (Eq.make ~pp:(fun ppf s -> Format.fprintf ppf "%S" s) ())
  let holds ?__POS__ value = bool ?__POS__ value true

  let option (type a) ?__POS__ ~some:(module E : Eq.S with type t = a) actual expected =
    let equal a b = match a, b with
      | None, None -> true | Some a, Some b -> E.equal a b | _ -> false
    in
    eq ?__POS__ (Eq.make ~equal ~pp:(Fmt.option E.pp) ()) actual expected

  let result' (type a b) ?__POS__
      ~ok:(module A : Eq.S with type t = a)
      ~error:(module B : Eq.S with type t = b) actual expected =
    let equal a b = match a, b with
      | Ok a, Ok b -> A.equal a b
      | Error a, Error b -> B.equal a b
      | _ -> false
    in
    let pp ppf = function
      | Ok a -> Format.fprintf ppf "Ok (%a)" A.pp a
      | Error b -> Format.fprintf ppf "Error (%a)" B.pp b
    in
    eq ?__POS__ (Eq.make ~equal ~pp ()) actual expected

  let get_some ?__POS__ = function Some value -> value | None -> fail ?__POS__ "expected Some"
  let get_ok ?__POS__ = function Ok value -> value | Error _ -> fail ?__POS__ "expected Ok"
  let log_fail ?__POS__ fmt =
    Format.kasprintf (fun message -> Printf.eprintf "%s%s\n%!" (position __POS__) message) fmt
  let block ?__POS__ ?fail f =
    let before = !checks in
    try f () with exn ->
      Option.iter (fun report -> report ?__POS__ 1 ~checks:(!checks - before)) fail;
      raise exn

  module Rand = struct
    let seed = 20261118
    let random = Random.State.make [| seed |]
    let state () = random
  end
  module Cli = struct
    let parse () =
      if Array.length Sys.argv <> 1 then invalid_arg "Ptime adapter accepts no arguments";
      Printf.printf "random seed: %d\n%!" Rand.seed
  end
  let test name f =
    let before = !checks in
    try
      f (); incr passed;
      Printf.printf "PASS %s (%d checks)\n%!" name (!checks - before)
    with exn ->
      incr failed;
      Printf.printf "FAIL %s: %s\n%!" name (Printexc.to_string exn)
  let main f =
    (try f () with exn -> incr failed; Printf.eprintf "%s\n%!" (Printexc.to_string exn));
    Printf.printf "RESULT passed=%d failed=%d checks=%d\n%!" !passed !failed !checks;
    if !failed = 0 then 0 else 1
end

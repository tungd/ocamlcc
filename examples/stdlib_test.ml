external arc_live : unit -> int = "ocamlcc_arc_live"
external arc_collect : unit -> int = "ocamlcc_arc_collect"
external ocamlcc_pipe : unit -> int * int = "ocamlcc_pipe"
external ocamlcc_fd_read : int -> bytes -> int -> int -> int = "ocamlcc_fd_read"

type cyc = { mutable cnxt : cyc option; cv : int }

let run () =
  (* Option *)
  let o1 = Option.bind (Option.map (fun x -> x * 3) (Some 7)) (fun x -> Some (x + 1)) in
  let o2 = Option.value (Option.join (Some None)) ~default:99 in
  let o_eq = Option.equal (fun a b -> a = b) (Some 22) o1 in
  Printf.printf "option=%d,%d,%b\n" (Option.value o1 ~default:0) o2 o_eq;

  (* Result *)
  let r1 = Result.bind (Ok 10) (fun x -> if x > 5 then Ok (x + 5) else Error "low") in
  let r2 = Result.map_error String.length (Error "oops") in
  let r_v = Result.value r1 ~default:0 in
  let r_e = Result.get_error r2 in
  Printf.printf "result=%d,%d,%b\n" r_v r_e (Result.is_ok r1 && Result.is_error r2);

  (* List *)
  let xs = [ 5; 1; 4; 2; 3; 2 ] in
  let sorted = List.sort compare xs in
  let uniq = List.sort_uniq compare xs in
  let mapped = List.filter_map (fun x -> if x mod 2 = 0 then Some (x * 10) else None) uniq in
  let folded = List.fold_left ( + ) 0 mapped in
  let found = Option.value (List.assoc_opt "b" [ ("a", 11); ("b", 22) ]) ~default:(-1) in
  Printf.printf "list=%d,%d,%d,%b\n"
    (List.length sorted) folded found (xs @ [] = [ 5; 1; 4; 2; 3; 2 ]);

  (* List.init: f is invoked in order 0..len-1 *)
  let init_order = ref [] in
  let inited = List.init 4 (fun i -> init_order := i :: !init_order; i * i) in
  Printf.printf "listinit=%s,%b\n"
    (String.concat "" (List.map string_of_int (List.rev !init_order)))
    (inited = [ 0; 1; 4; 9 ]);

  (* Array *)
  let arr = Array.init 5 (fun i -> 5 - i) in
  Array.sort compare arr;
  let arr_sum = Array.fold_left ( + ) 0 arr in
  Printf.printf "array=%d,%d,%d,%b\n" arr.(0) arr.(4) arr_sum (arr = [| 1; 2; 3; 4; 5 |]);

  (* Bytes & String *)
  let b = Bytes.of_string "  hello-ocamlcc  " in
  let trimmed = Bytes.to_string (Bytes.trim b) in
  let parts = String.split_on_char '-' (String.uppercase_ascii trimmed) in
  let joined = String.concat "/" parts in
  Printf.printf "string=%s,%b,%b\n"
    joined
    (String.starts_with ~prefix:"HELLO" joined)
    (String.ends_with ~suffix:"OCAMLCC" joined);

  (* Buffer *)
  let buf = Buffer.create 4 in
  Buffer.add_string buf "alpha";
  Buffer.add_char buf ':';
  Printf.bprintf buf "%d:%x:%s" 42 255 "done";
  Printf.printf "buffer=%s,%d\n" (Buffer.contents buf) (Buffer.length buf);

  (* Hashtbl *)
  let tbl = Hashtbl.create 4 in
  for i = 0 to 39 do
    let k = Printf.sprintf "k%02d" i in
    Hashtbl.replace tbl k (i * i)
  done;
  Hashtbl.remove tbl "k10";
  let v7 = Option.value (Hashtbl.find_opt tbl "k07") ~default:(-1) in
  let v10 = Option.value (Hashtbl.find_opt tbl "k10") ~default:(-1) in
  let tbl_sum = Hashtbl.fold (fun _ v acc -> acc + v) tbl 0 in
  Printf.printf "hashtbl=%d,%d,%d,%d\n" (Hashtbl.length tbl) v7 v10 tbl_sum;

  (* Weak *)
  let w = Weak.create 2 in
  let helper () =
    let target = ref 123 in
    Weak.set w 0 (Some target);
    let alive_before = Weak.check w 0 in
    let got = match Weak.get w 0 with Some r -> !r | None -> -1 in
    let still = !target in
    Printf.printf "weak_live=%b,%d,%d\n" alive_before got still
  in
  helper ();
  Printf.printf "weak_cleared=%b\n" (Weak.check w 0);

  (* Weak.get_copy returns an independent copy of the stored value *)
  let w2 = Weak.create 1 in
  let orig = ref 10 in
  Weak.set w2 0 (Some orig);
  let copied =
    match Weak.get_copy w2 0 with Some cp -> cp := 20; !cp | None -> -1
  in
  let stored = match Weak.get w2 0 with Some r -> !r | None -> -1 in
  let alive = Weak.check w2 0 in
  Printf.printf "weak_copy=%d,%d,%b,%d\n" copied stored alive !orig;

  (* Structural compare, division/modulo by zero & refs *)
  let r = ref 10 in
  incr r;
  r := !r + int_of_string (string_of_int 31);
  let cmp = compare ("ab", [ 1; 2 ]) ("ab", [ 1; 3 ]) in
  let d1 = try 1 / 0 with Division_by_zero -> -11 in
  let m1 = try 1 mod 0 with Division_by_zero -> -22 in
  let div_pair a b = a / b in
  let mod_pair a b = a mod b in
  let d2 = div_pair 21 3 in
  let d3 = try div_pair 21 0 with Division_by_zero -> -33 in
  let m2 = mod_pair 23 5 in
  let m3 = try mod_pair 23 0 with Division_by_zero -> -44 in
  let keep = ref 50 in
  let un =
    try
      let tmp = ref 99 in
      !keep / (!tmp - 99)
    with Division_by_zero -> !keep + 5
  in
  Printf.printf "misc=%d,%d,%b\n" !r cmp (("x" ^ "y") = "xy");

  (* Structural comparisons that reach a closure raise Invalid_argument. *)
  let f1 x = x + 1 in
  let f2 x = x + 2 in
  let raises_cmp =
    try let _ = compare f1 f2 in false with Invalid_argument _ -> true
  in
  let raises_lt =
    try let _ = f1 < f2 in false with Invalid_argument _ -> true
  in
  let rejects f = try ignore (f ()); false with Invalid_argument _ -> true in
  let eq_fns = rejects (fun () -> f1 = f2) in
  let eq_self = rejects (fun () -> f1 = f1) in
  Printf.printf "fncompare=%b,%b,%b,%b\n" raises_cmp raises_lt eq_fns eq_self;
  Printf.printf "div0=%d,%d,%d,%d,%d,%d,%d\n" d1 m1 d2 d3 m2 m3 un;

  (* int_of_string: radix prefixes (0x/0o/0b), underscores, decimal overflow *)
  Printf.printf "intparse_hex=%d,%d,%d\n"
    (Option.value (int_of_string_opt "0xff") ~default:(-1))
    (Option.value (int_of_string_opt "-0xff") ~default:(-1))
    (Option.value (int_of_string_opt "0XAB") ~default:(-1));
  Printf.printf "intparse_ovf=%d,%b,%b\n"
    (Option.value (int_of_string_opt "4611686018427387903") ~default:0)
    (int_of_string_opt "4611686018427387904" = None)
    (int_of_string_opt "99999999999999999999" = None);
  Printf.printf "intparse_edge=%d,%b,%b,%b,%b,%b,%b,%b\n"
    (Option.value (int_of_string_opt "-4611686018427387904") ~default:0)
    (int_of_string_opt "-4611686018427387905" = None)
    (int_of_string_opt "0x4000000000000000" = Some min_int)
    (int_of_string_opt "007" = Some 7)
    (int_of_string_opt "+42" = Some 42)
    (int_of_string_opt "1_000" = Some 1000)
    (int_of_string_opt "100_" = Some 100)
    (int_of_string_opt "0u10" = Some 10);
  let parse_fails s = try ignore (int_of_string s); false with Failure _ -> true in
  Printf.printf "intparse_fail=%b,%b,%b,%b,%b\n"
    (parse_fails "12x") (parse_fails "0x") (parse_fails "_100")
    (parse_fails "4611686018427387904") (parse_fails "0x_ff");

  (* Bounds checks and invalid allocation sizes -> Invalid_argument *)
  let ia_arr = [| 10; 20 |] in
  let i1 = try ia_arr.(2) with Invalid_argument _ -> -1 in
  let i2 = try ia_arr.(-1) with Invalid_argument _ -> -2 in
  let ia_ref_arr = [| ref 1; ref 2 |] in
  let i3 =
    try ia_ref_arr.(5) <- ref 77; 0
    with Invalid_argument _ -> -3
  in
  let i4 =
    try ia_ref_arr.(-1) <- ref 88; 0
    with Invalid_argument _ -> -4
  in
  let i5 = try int_of_char "ab".[2] with Invalid_argument _ -> -5 in
  let i6 = try int_of_char "ab".[-1] with Invalid_argument _ -> -6 in
  let ia_b = Bytes.of_string "xy" in
  let i7 = try int_of_char (Bytes.get ia_b 9) with Invalid_argument _ -> -7 in
  let i8 = try Bytes.set ia_b (-1) 'z'; 0 with Invalid_argument _ -> -8 in
  let i9 =
    try Array.length (Array.make (-1) 0)
    with Invalid_argument _ -> -9
  in
  let i10 =
    try Array.length (Array.make (-1) (ref 99))
    with Invalid_argument _ -> -10
  in
  let i11 =
    try Bytes.length (Bytes.create (-1))
    with Invalid_argument _ -> -11
  in
  let i12 =
    try String.length (String.make (-1) 'q')
    with Invalid_argument _ -> -12
  in
  let i13 =
    try Weak.length (Weak.create (-1))
    with Invalid_argument _ -> -13
  in
  let ia_w = Weak.create 1 in
  let i14 =
    try match Weak.get ia_w 2 with Some _ -> 1 | None -> 0
    with Invalid_argument _ -> -14
  in
  let i15 =
    try Weak.set ia_w (-1) None; 0
    with Invalid_argument _ -> -15
  in
  let i16 =
    try if Weak.check ia_w 4 then 1 else 0
    with Invalid_argument _ -> -16
  in
  let ia_keep = ref 300 in
  let i_un =
    try
      let tmp = ref 400 in
      let _ = Array.make (!tmp - 401) (ref 500) in
      !ia_keep + 1
    with Invalid_argument msg -> !ia_keep + String.length msg
  in
  let bsrc = Bytes.make 8 'a' in
  let bdst = Bytes.make 8 'b' in
  let i_blit =
    try Bytes.unsafe_blit bsrc 0 bdst 6 4; 0
    with Invalid_argument _ -> -17
  in
  let i_fill =
    try Bytes.unsafe_fill bsrc 6 4 'z'; 0
    with Invalid_argument _ -> -18
  in
  Printf.printf "invarg=%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n"
    i1 i2 i3 i4 i5 i6 i7 i8 i9 i10 i11 i12 i13 i14 i15 i16 i_un i_blit i_fill;

  (* compare contract: cyclic structures raise Invalid_argument instead of
     recursing forever; exception constructor ids compare structurally
     (name string + OID), not by raw heap address. *)
  let cmp_cyc =
    let probe () =
      let mk_cyc () =
        let c = { cnxt = None; cv = 1 } in
        c.cnxt <- Some c;
        c
      in
      let c1 = mk_cyc () in
      let c2 = mk_cyc () in
      match (ignore (compare c1 c2); 0) with
      | _ -> 0
      | exception Invalid_argument _ -> 1
    in
    let r = probe () in
    (* the cyclic probes' garbage needs the opt-in collector *)
    let _freed = arc_collect () in
    r
  in
  let eq_cyc =
    let probe () =
      let mk_cyc () =
        let c = { cnxt = None; cv = 1 } in
        c.cnxt <- Some c;
        c
      in
      let c1 = mk_cyc () in
      let c2 = mk_cyc () in
      let live = (10, 20) in
      try
        if c1 = c2 then fst live else 0
      with Invalid_argument _ -> 1
    in
    let r = probe () in
    let _freed = arc_collect () in
    r
  in
  let neq_cyc =
    let probe () =
      let mk_cyc () =
        let c = { cnxt = None; cv = 1 } in
        c.cnxt <- Some c;
        c
      in
      let c1 = mk_cyc () in
      let c2 = mk_cyc () in
      let live = (10, 20) in
      try
        if c1 <> c2 then fst live else 0
      with Invalid_argument _ -> 1
    in
    let r = probe () in
    let _freed = arc_collect () in
    r
  in
  let cmp_exn =
    if compare (Invalid_argument "x") (Failure "x") > 0 then 1 else 0
  in
  let fd_oob =
    let rfd, _wfd = ocamlcc_pipe () in
    let b = Bytes.create 4 in
    try (ignore (ocamlcc_fd_read rfd b 2 8); 0)
    with Invalid_argument _ -> 1
  in
  Printf.printf "cmp=%d,%d,%d,%d,%d\n" cmp_cyc eq_cyc neq_cyc cmp_exn fd_oob;
  Printf.printf "fmt=%d,%i,%d,%u,%u,%x,%X,%o\n"
    min_int min_int max_int (-1) min_int (-1) (-1) (-1);
  Printf.printf "fmtpad=[%05d],[%+05d],[% 05d],[%#05x],[%.3d],[%.3d],[%5.3d],[%-5.3d],[%*.*d],[%0*d]\n"
    (-12) 12 12 15 7 (-7) (-7) 7 6 3 (-12) 5 (-12);
  Printf.printf "fmtsc=%C,%C,%C,%C,%C,%C,%S,[%10S]\n"
    'a' '\'' '"' '\\' '\n' '\255'
    "a\"'\\\n\t\r\b\000\255" "a\nb";
  Printf.eprintf "err=%d,%s\n" 42 "ok";
  print_string "nul:a\000b\n";
  print_char '\000';
  print_endline "after-nul-char"

let () =
  (* Warm up printf once outside the measurement window. *)
  let _ = Printf.sprintf "warm=%d" 1 in
  let before = arc_live () in
  run ();
  let after = arc_live () in
  Printf.printf "arc_delta=%d\n" (after - before)

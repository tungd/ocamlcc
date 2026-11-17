external arc_live : unit -> int = "ocamlcc_arc_live"
external arc_collect : unit -> int = "ocamlcc_arc_collect"

type fpair = { x : float; mutable y : float }

let test_floats () =
  let a = 1.5 +. 2.25 in
  let b = (a *. 2.0) -. (3.0 /. 2.0) in
  let c = -. (abs_float (-4.5)) in
  let n = int_of_float (b +. 0.9) in
  let f = float_of_int n +. 0.5 in
  let p = { x = a; y = b } in
  p.y <- p.x +. 1.0;
  let cmp_nan =
    (nan = nan) = false
    && (nan <> nan) = true
    && compare nan 1.0 < 0
    && compare 1.0 nan > 0
    && compare nan nan = 0
  in
  let parsed = float_of_string "12.5" in
  let ht = Hashtbl.create 4 in
  Hashtbl.add ht 3.25 "ok";
  let h_ok = Hashtbl.find ht (1.5 +. 1.75) = "ok" in
  Printf.printf "float=%.2f,%.2f,%.2f,%d,%.1f,%.2f,nan=%b,parse=%.1f,ht=%b\n"
    a b c n f p.y cmp_nan parsed h_ok

let test_float_arrays () =
  let c_arr = [| 1.25; 2.5 |] in
  let d = 3.5 in
  let m_arr = [| 1.25; d; d +. 1.0 |] in
  m_arr.(0) <- m_arr.(1) +. 0.25;
  let mk = Array.make 3 2.5 in
  mk.(1) <- 7.5;
  let poly_sum (a : float array) =
    let s = ref 0.0 in
    for i = 0 to Array.length a - 1 do
      s := !s +. Array.get a i
    done;
    !s
  in
  let oob_caught =
    try
      let _ = c_arr.(5) in
      false
    with Invalid_argument _ -> true
  in
  let poly_eq = c_arr = [| 1.25; 2.5 |] && compare [| 1.0; 2.0 |] [| 1.0; 3.0 |] < 0 in
  Printf.printf "farr=%.2f,%.2f,%.2f,oob=%b,eq=%b\n"
    m_arr.(0) (poly_sum m_arr) (poly_sum mk) oob_caught poly_eq

let test_boxed_ints () =
  let i32_a = Int32.add 10l 32l in
  let i32_wrap = Int32.add Int32.max_int 1l = Int32.min_int in
  let i32_div = Int32.div i32_a 5l in
  let i32_rem = Int32.rem i32_a 5l in
  let i32_bits =
    Int32.shift_right (Int32.logand (Int32.shift_left 7l 4) 0xf0l) 2
  in
  let i32_lsr = Int32.shift_right_logical (-1l) 28 in
  let i32_dbz =
    try
      let _ = Int32.div 10l 0l in
      false
    with Division_by_zero -> true
  in
  let i64_a = Int64.mul 100000L 200000L in
  let i64_b = Int64.of_int32 i32_a in
  let bits = Int64.bits_of_float 3.5 in
  let roundtrip = Int64.float_of_bits bits in
  let i64_dbz =
    try
      let _ = Int64.rem 10L 0L in
      false
    with Division_by_zero -> true
  in
  let nat_a = Nativeint.sub (Nativeint.mul 6n 7n) 2n in
  let nat_b = Nativeint.of_int32 i32_div in
  let nat_cmp = 10l < 20l && 100L = Int64.of_int 100 && compare nat_a 40n = 0 in
  let ht = Hashtbl.create 4 in
  Hashtbl.add ht 42L "forty-two";
  let h_ok = Hashtbl.find ht i64_b = "forty-two" in
  Printf.printf
    "i32=%ld,%ld,%ld,%ld,%ld,wrap=%b,dbz=%b;i64=%Ld,%Ld,%.1f,dbz=%b;nat=%nd,%nd,cmp=%b,ht=%b\n"
    i32_a i32_div i32_rem i32_bits i32_lsr i32_wrap i32_dbz
    i64_a i64_b roundtrip i64_dbz nat_a nat_b nat_cmp h_ok

let test_printf () =
  let s =
    Printf.sprintf "[%8.2f|%-6.1f|%06ld|%#Lx|%04nx|%e]"
      3.14159 (-2.5) 42l 255L 31n 125.0
  in
  Printf.printf "fmt=%s\n" s

let () =
  let before = arc_live () in
  test_floats ();
  test_float_arrays ();
  test_boxed_ints ();
  test_printf ();
  let _ = arc_collect () in
  let after = arc_live () in
  Printf.printf "delta=%d\n" (after - before)

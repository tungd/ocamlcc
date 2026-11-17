let () =
  let expected = [("alpha", Some "12", 0, 7); ("b", None, 8, 9)] in
  assert (Lexer.tokens (Lexing.from_string "alpha12 b") = expected);
  let text = "alpha12 b" in
  let index = ref 0 in
  let buffer = Lexing.from_function (fun bytes _ ->
    if !index = String.length text then 0 else begin
      Bytes.set bytes 0 text.[!index]; incr index; 1
    end) in
  assert (Lexer.tokens buffer = expected);
  let long = String.make 3000 'a' ^ "123" in
  let at = ref 0 in
  let chunked = Lexing.from_function (fun b max ->
    let n = min max (min 127 (String.length long - !at)) in
    Bytes.blit_string long !at b 0 n; at := !at + n; n) in
  assert (Lexer.tokens chunked = [(String.make 3000 'a', Some "123", 0, 3003)]);
  let no_pos = Lexing.from_string ~with_positions:false "x" in
  ignore (Lexer.tokens no_pos);
  assert (not (Lexing.with_positions no_pos));
  assert (Plain.token (Lexing.from_string "ac") = 1);
  assert (Plain.token (Lexing.from_string "ab") = 2);
  assert (Plain.token (Lexing.from_string "") = 0);
  assert (try ignore (Plain.token (Lexing.from_string "z")); false
          with Failure message -> message = "lexing: empty token");
  print_endline "lexing: captures, backtracking, refill, EOF, positions"

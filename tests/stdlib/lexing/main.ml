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
  let no_pos = Lexing.from_string ~with_positions:false "x" in
  ignore (Lexer.tokens no_pos);
  assert (not (Lexing.with_positions no_pos));
  assert (Plain.token (Lexing.from_string "ac") = 1);
  assert (Plain.token (Lexing.from_string "ab") = 2);
  assert (Plain.token (Lexing.from_string "") = 0);
  assert (try ignore (Plain.token (Lexing.from_string "z")); false
          with Failure message -> message = "lexing: empty token");
  print_endline "lexing: captures, backtracking, refill, EOF, positions"

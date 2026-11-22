let one_byte_at_a_time text =
  let index = ref 0 in
  Lexing.from_function (fun bytes _ ->
    if !index = String.length text then 0 else begin
      Bytes.set bytes 0 text.[!index]; incr index; 1
    end)

let check_raw_positions buffer token expected eof =
  let start = Lexing.lexeme_start_p buffer in
  let finish = Lexing.lexeme_end_p buffer in
  assert (token buffer = expected);
  assert (token buffer = eof);
  assert (Lexing.lexeme_start_p buffer == start);
  assert (Lexing.lexeme_end_p buffer == finish)

let check_empty_token token =
  match token (Lexing.from_string "z") with
  | exception Failure message -> assert (message = "lexing: empty token")
  | _ -> assert false

let () =
  let expected = [("alpha", Some "12", 0, 7); ("b", None, 8, 9)] in
  assert (Lexer.tokens (Lexing.from_string "alpha12 b") = expected);
  assert (Lexer.tokens (one_byte_at_a_time "alpha12 b") = expected);
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
  check_empty_token Plain.token;
  check_empty_token Raw_plain.token;
  check_raw_positions (one_byte_at_a_time "42") Raw_plain.token 42 0;
  check_raw_positions (one_byte_at_a_time "abc123") Raw_capture.token
    (Some ("abc", Some "123")) None;
  print_endline "lexing: captures, backtracking, refill, EOF, positions"

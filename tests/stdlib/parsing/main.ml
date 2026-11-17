let parse s = Parser.main Lexer.token (Lexing.from_string s)
let () =
  assert (parse "1+(2+3)" = 6);
  let deep = String.make 250 '(' ^ "7" ^ String.make 250 ')' in
  assert (parse deep = 7);
  assert (try ignore (parse "1+?"); false with Parsing.Parse_error -> true);
  assert (parse "9" = 9);
  assert (not (Parsing.set_trace false));
  assert (not (Parsing.set_trace true));
  assert (Parsing.set_trace false);
  Parsing.clear_parser ();
  print_endline "parsing: reductions, stack growth, errors, restoration, trace state"

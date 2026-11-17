{
}
rule tokens = parse
| [' ' '\n']+ { tokens lexbuf }
| (['a'-'z']+ as word) (['0'-'9']+ as digits)?
    { let token = (word, digits, Lexing.lexeme_start lexbuf, Lexing.lexeme_end lexbuf) in
      token :: tokens lexbuf }
| eof { [] }

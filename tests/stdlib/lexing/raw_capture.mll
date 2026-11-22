{
module Lexing = struct
  include Lexing
  external new_engine : lex_tables -> int -> lexbuf -> int =
    "caml_new_lex_engine"
end
}
rule token = parse
| (['a'-'z']+ as word) (['0'-'9']+ as digits)? { Some (word, digits) }
| eof { None }

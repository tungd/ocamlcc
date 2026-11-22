{
module Lexing = struct
  include Lexing
  external engine : lex_tables -> int -> lexbuf -> int = "caml_lex_engine"
end
}
rule token = parse
| "42" { 42 }
| eof { 0 }

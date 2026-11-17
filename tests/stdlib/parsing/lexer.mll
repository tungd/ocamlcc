{ open Parser }
rule token = parse
| [' ' '\n']+ { token lexbuf }
| ['0'-'9']+ as n { INT (int_of_string n) }
| '+' { PLUS }
| '(' { LPAREN }
| ')' { RPAREN }
| eof { EOF }
| _ { BAD }

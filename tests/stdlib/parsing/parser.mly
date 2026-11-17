%token <int> INT
%token PLUS LPAREN RPAREN BAD EOF
%left PLUS
%start main recovered positions empty
%type <int> main recovered
%type <int * int * int * int> positions
%type <int * int> empty blank
%%
main: expr EOF { $1 };
recovered: expr EOF { $1 } | error EOF { 99 };
positions: LPAREN expr RPAREN EOF
  { (Parsing.symbol_start (), Parsing.rhs_start 2, Parsing.rhs_end 2, Parsing.symbol_end ()) };
empty: blank EOF { $1 };
blank: { (Parsing.symbol_start (), Parsing.symbol_end ()) };
expr:
  INT { if $1 = 13 then raise Parsing.Parse_error else $1 }
| expr PLUS expr { $1 + $3 }
| LPAREN expr RPAREN { $2 }
;

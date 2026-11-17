%token <int> INT
%token PLUS LPAREN RPAREN BAD EOF
%left PLUS
%start main
%type <int> main
%%
main: expr EOF { $1 };
expr:
  INT { $1 }
| expr PLUS expr { $1 + $3 }
| LPAREN expr RPAREN { $2 }
;

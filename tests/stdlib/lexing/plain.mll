rule token = parse
| "ab" { 2 }
| 'a' { 1 }
| eof { 0 }

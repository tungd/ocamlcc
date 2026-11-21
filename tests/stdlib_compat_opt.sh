#!/bin/sh
set -eu

stdlib=build/stdlib_compat/out
bulk='call extern \$ocamlcc_CamlinternalBulkOps_'
grep -Eq "${bulk}array_fill(_borrowed)?__" "$stdlib/stdlib__array.ssa"
grep -Eq "${bulk}array_sub(_borrowed)?__" "$stdlib/stdlib__array.ssa"
grep -Eq "${bulk}fill_bytes(_borrowed)?__" "$stdlib/stdlib__bytes.ssa"
grep -Eq "${bulk}blit_bytes(_borrowed)?__" "$stdlib/stdlib__bytes.ssa"
grep -Eq "${bulk}blit_string(_borrowed)?__" "$stdlib/stdlib__string.ssa"

for fn in array_fill array_sub fill_bytes blit_bytes; do
    grep -Eq "ocamlcc_CamlinternalBulkOps_${fn}_borrowed__" "$stdlib/camlinternalBulkOps.exports"
done
grep -Eq 'ocamlcc_Stdlib__Bytes_set_uint8_borrowed__' "$stdlib/stdlib__bytes.exports"

# Uchar.to_int is exposed as the immediate identity in the compatibility CMI.
awk '
    /function l \$ocamlcc_Stdlib__Bytes_set_utf_8_uchar(_borrowed)?__/ { body = 1; found = 1 }
    /^}/ { body = 0 }
    body && /\$ocamlcc_global_Stdlib__Uchar|\$ocamlcc_apply1_raw/ { indirect = 1 }
    END { exit !found || indirect }
' "$stdlib/stdlib__bytes.ssa"
echo 'stdlib compatibility direct calls: PASS'

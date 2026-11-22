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

# Later units can import both the Stdlib raise helpers and earlier bulk
# providers in the same build of the archive.
for unit in array bytes; do
    grep -Eq 'call extern \$ocamlcc_Stdlib_invalid_arg__' "$stdlib/stdlib__$unit.ssa"
    grep -Eq '_fill__[^ ]+ 4 false [^ ]+ [^ ]+ [^ ]+ 100[01]$' "$stdlib/stdlib__$unit.opt"
done
grep -Eq '_set_utf_8_uchar__[^ ]+ 3 false [^ ]+ [^ ]+ [^ ]+ 10[01]$' "$stdlib/stdlib__bytes.opt"

# Uchar.to_int is exposed as the immediate identity in the compatibility CMI.
awk '
    /function l \$ocamlcc_Stdlib__Bytes_set_utf_8_uchar(_borrowed)?__/ { body = 1; found = 1 }
    /^}/ { body = 0 }
    body && /\$ocamlcc_global_Stdlib__Uchar|\$ocamlcc_apply1_raw/ { indirect = 1 }
    END { exit !found || indirect }
' "$stdlib/stdlib__bytes.ssa"
echo 'stdlib compatibility direct calls: PASS'

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
cat > "$probe/probe.ml" <<'ML'
let valid n = Uchar.is_valid n
let of_int n = Uchar.to_int (Uchar.of_int n)
ML
build/bin/ocamlcc compile --nostdlib --stdlib-dir "$stdlib" --mod "$probe/probe.ml" -o "$probe/probe.ssa"
awk '
    /function l \$ocamlcc_Probe_(valid|of_int)\(/ { guard = 0; count++ }
    / =l cultl 110591,/ { guard = 1 }
    /call extern \$ocamlcc_Stdlib__Uchar_(is_valid|of_int)__/ {
        if (!guard) exit 1
        cold++
    }
    END { if (cold != 2 || count != 2) exit 1 }
' "$probe/probe.ssa"

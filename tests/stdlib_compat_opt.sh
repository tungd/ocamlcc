#!/bin/sh
set -eu

stdlib=build/stdlib
check_bulk_entry() {
    awk -v entry="$2" -v primitive="$3" '
        /function l / {
            body = $0 ~ ("\\$" entry "(_borrowed)?__")
            if (body) { count++; called = 0 }
        }
        body && /call extern \$ocamlcc_CamlinternalBulkOps\./ { checked = 1 }
        body && $0 ~ ("call extern \\$" primitive "\\(") { called = 1 }
        /^}/ && body { if (!called) missing = 1; body = 0 }
        END { exit count != 2 || checked || missing }
    ' "$1"
}
check_bulk_entry "$stdlib/stdlib__Array.ssa" ocamlcc_Stdlib__Array.fill ocamlcc_bulk_array_fill
check_bulk_entry "$stdlib/stdlib__Array.ssa" ocamlcc_Stdlib__Array.sub ocamlcc_bulk_array_sub
check_bulk_entry "$stdlib/stdlib__Bytes.ssa" ocamlcc_Stdlib__Bytes.fill ocamlcc_bulk_fill_bytes
check_bulk_entry "$stdlib/stdlib__Bytes.ssa" ocamlcc_Stdlib__Bytes.sub ocamlcc_bulk_blit_bytes

# The public unsafe Bytes functions keep the compatibility runtime's checks.
bulk='call extern \$ocamlcc_CamlinternalBulkOps\.'
grep -Eq "${bulk}fill_bytes(_borrowed)?__" "$stdlib/stdlib__Bytes.ssa"
grep -Eq "${bulk}blit_bytes(_borrowed)?__" "$stdlib/stdlib__Bytes.ssa"
grep -Eq "${bulk}blit_string(_borrowed)?__" "$stdlib/stdlib__String.ssa"
grep -Eq 'ocamlcc_Stdlib__Bytes\.set_uint8_borrowed__' "$stdlib/stdlib__Bytes.exports"

# Later units can import both the Stdlib raise helpers and earlier bulk
# providers in the same build of the archive.
for unit in Array Bytes; do
    grep -Eq 'call extern \$ocamlcc_Stdlib\.invalid_arg__' "$stdlib/stdlib__$unit.ssa"
    grep -Eq '\.fill__[^ ]+ 4 false [^ ]+ [^ ]+ [^ ]+ 100[01]$' "$stdlib/stdlib__$unit.opt"
done
grep -Eq '\.set_utf_8_uchar__[^ ]+ 3 false [^ ]+ [^ ]+ [^ ]+ 10[01]$' "$stdlib/stdlib__Bytes.opt"

# Uchar.to_int is exposed as the immediate identity in the compatibility CMI.
awk '
    /function l \$ocamlcc_Stdlib__Bytes\.set_utf_8_uchar(_borrowed)?__/ { body = 1; found = 1 }
    /^}/ { body = 0 }
    body && /\$ocamlcc_global_Stdlib__Uchar|\$ocamlcc_apply1_raw/ { indirect = 1 }
    END { exit !found || indirect }
' "$stdlib/stdlib__Bytes.ssa"
echo 'stdlib compatibility direct calls: PASS'

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
cat > "$probe/probe.ml" <<'ML'
let valid n = Uchar.is_valid n
let of_int n = Uchar.to_int (Uchar.of_int n)
ML
build/bin/occ compile --nostdlib --stdlib-dir "$stdlib" --mod "$probe/probe.ml" -o "$probe/probe.ssa"
awk '
    /function l \$ocamlcc_Probe\.(valid|of_int)\(/ { guard = 0; count++ }
    / =l cultl 110591,/ { guard = 1 }
    /call extern \$ocamlcc_Stdlib__Uchar\.(is_valid|of_int)__/ {
        if (!guard) exit 1
        cold++
    }
    END { if (cold != 2 || count != 2) exit 1 }
' "$probe/probe.ssa"

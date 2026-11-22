#!/bin/sh
set -eu

qbe=$1
case "$(uname -sm)" in
    'Darwin arm64') target=arm64_apple ;;
    'Linux aarch64'|'Linux arm64') target=arm64 ;;
    *) echo 'QBE ARM64 long branches: skipped (requires native ARM64)'; exit 0 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Each retained call is one 4-byte instruction. The padding puts both
# conditional targets beyond the signed 19-bit word displacement.
awk 'BEGIN {
    print "export function w $choose() {"
    print "@entry"
    print "    jmp @head"
    print "@head"
    print "    %take =w call $should_work()"
    print "    jnz %take, @work, @done"
    print "@work"
    for (i = 0; i < 262145; i++)
        print "    call $touch()"
    print "    %again =w call $should_repeat()"
    print "    jnz %again, @head, @done"
    print "@done"
    print "    ret 42"
    print "}"
}' > "$work/long.ssa"

cat > "$work/host.c" <<'C'
static int checks, calls, repeat;
int should_work(void) { return checks++ == 0; }
void touch(void) { calls++; }
int should_repeat(void) { return repeat; }
extern int choose(void);
int main(void) {
    for (repeat = 0; repeat < 2; repeat++) {
        checks = calls = 0;
        if (choose() != 42 || checks != 1 + repeat || calls != 262145)
            return 1;
    }
    return 0;
}
C

"$qbe" -t "$target" -o "$work/long.s" "$work/long.ssa"
cc "$work/long.s" "$work/host.c" -o "$work/check"
"$work/check"
echo 'QBE ARM64 long branches: PASS'

#!/usr/bin/env python3
"""Run native stdlib API regressions, including real ocamllex/ocamlyacc output.

Run tools/stdlib_compat.py --skip-tests first. Artifacts/logs remain in build/.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys
from stdlib_compat import detect_host_qbe_target

ROOT = Path(__file__).resolve().parent.parent

def run_case(case: Path, stock: bool = False) -> None:
    work = ROOT / 'build/stdlib_regressions' / (case.name + ('-stock' if stock else ''))
    work.mkdir(parents=True, exist_ok=True)
    for source in case.iterdir():
        if source.suffix in ('.ml', '.mli', '.mll', '.mly'):
            shutil.copy2(source, work / source.name)
    log = work / 'commands.log'
    with log.open('w') as out:
        def command(args, timeout=30):
            out.write('$ ' + ' '.join(map(str, args)) + '\n'); out.flush()
            p = subprocess.run(list(map(str, args)), cwd=work, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=timeout)
            out.write(p.stdout.decode(errors='replace')); out.write(p.stderr.decode(errors='replace')); out.flush()
            if p.returncode:
                raise RuntimeError(f'exit {p.returncode}: {args[0]} (see {log})')
            return p.stdout
        for p in sorted(work.glob('*.mly')):
            command(['ocamlyacc', p.name])
        for p in sorted(work.glob('*.mll')):
            command(['ocamllex', p.name])
        # Parser interfaces precede lexers; main is the executable entrypoint.
        sources = sorted(work.glob('*.ml'), key=lambda p: (p.stem == 'main', p.stem != 'parser', p.name))
        if stock:
            for p in work.glob('*.mli'):
                command(['ocamlc', '-c', p.name])
            command(['ocamlc', '-o', 'run', *[p.name for p in sources]])
        else:
            cc = ROOT / 'build/bin/occ'
            stdlib = ROOT / 'build/stdlib'
            common = ['--nostdlib', '-I', stdlib, '-I', work]
            for p in work.glob('*.mli'):
                command([cc, 'compile-mli', *common, p.name])
            objects = []
            for p in sources:
                command([cc, 'compile', *common, '--stdlib-dir', stdlib, *([] if p.stem == 'main' else ['--mod', '--emit-cmi']),
                         p.name, '-o', p.with_suffix('.ssa').name])
                asm = command([ROOT / 'build/qbe/qbe', '-t', detect_host_qbe_target(), p.with_suffix('.ssa').name])
                p.with_suffix('.s').write_bytes(asm)
                command(['cc', '-c', p.with_suffix('.s').name, '-o', p.with_suffix('.o').name])
                objects.append(p.with_suffix('.o').name)
            command(['cc', *objects, stdlib / 'libocamlstdlib.a', ROOT / 'build/rt/libocamlrt.a', '-lm', '-o', 'run'])
        actual = command([work / 'run'], timeout=60)
        (work / 'actual').write_bytes(actual)
        expected = (case / 'expected').read_bytes()
        if actual != expected:
            raise RuntimeError(f'output mismatch: {work / "actual"}')
    print(f'PASS {case.name}{" (stock)" if stock else ""}: {log}')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', nargs='*')
    parser.add_argument('--stock', action='store_true')
    args = parser.parse_args()
    cases = [ROOT / 'tests/stdlib' / c for c in args.cases] if args.cases else sorted(p for p in (ROOT / 'tests/stdlib').iterdir() if p.is_dir())
    failed = False
    for case in cases:
        try:
            run_case(case, args.stock)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            print(f'FAIL {case.name}: {error}', file=sys.stderr); failed = True
    return int(failed)

if __name__ == '__main__':
    raise SystemExit(main())

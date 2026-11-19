# Non-Lwt package test results

Observed 2026-11-18T07:31:41+00:00, macOS arm64. All listed checks passed.

| Coverage | Result |
|---|---|
| Crunch upstream plain output | PASS |
| Crunch upstream extension-filtered plain output | PASS |
| Cmdliner, 18 upstream programs | 65/65 invocations match stock OCaml stdout, stderr and exit code |
| Ptime core | 21/21 groups, 700,809 comparisons |
| Ptime vs libc gmtime | 1/1 group, 200,004 comparisons |
| Ptime API examples | PASS |
| Assertion-adapter negative controls | 9/9 deliberate failures detected on both compilers |

Ptime package and test sources were unchanged. A test-only B0 assertion adapter
ran them with seed 20261118 and the original 100,000-iteration loop counts.
The ARC oracle uses libc `gmtime_r`; the stock reference uses `Unix.gmtime`.

Excluded: the Crunch Lwt/Mirage consumer, and Ptime `test_gmtime_all`/`min_clock`
which upstream marks `run:false`. The API examples are also upstream `run:false`
but were additionally executed here. Cmdliner has test/example programs rather
than a supplied golden-output runner; the 65-case comparison matrix is ours.

## Individual checks

- PASS: Crunch plain upstream golden
- PASS: Crunch plain-extension upstream golden
- PASS: Cmdliner chorus --help=plain
- PASS: Cmdliner chorus --ocpkg-invalid
- PASS: Cmdliner chorus (default)
- PASS: Cmdliner chorus --count 2 hello
- PASS: Cmdliner cp_ex --help=plain
- PASS: Cmdliner cp_ex --ocpkg-invalid
- PASS: Cmdliner cp_ex a b
- PASS: Cmdliner darcs_ex --help=plain
- PASS: Cmdliner darcs_ex --ocpkg-invalid
- PASS: Cmdliner darcs_ex initialize
- PASS: Cmdliner darcs_ex record --all
- PASS: Cmdliner revolt --help=plain
- PASS: Cmdliner revolt --ocpkg-invalid
- PASS: Cmdliner revolt (default)
- PASS: Cmdliner rm_ex --help=plain
- PASS: Cmdliner rm_ex --ocpkg-invalid
- PASS: Cmdliner rm_ex --force a b
- PASS: Cmdliner tail_ex --help=plain
- PASS: Cmdliner tail_ex --ocpkg-invalid
- PASS: Cmdliner tail_ex -n 3 a
- PASS: Cmdliner test_dupe_stdopts old --help=plain
- PASS: Cmdliner test_dupe_stdopts new --help=plain
- PASS: Cmdliner test_dupe_stdopts old sub
- PASS: Cmdliner test_dupe_stdopts new sub
- PASS: Cmdliner test_man --help=plain
- PASS: Cmdliner test_man --ocpkg-invalid
- PASS: Cmdliner test_man (default)
- PASS: Cmdliner test_man_utf8 --help=plain
- PASS: Cmdliner test_man_utf8 --ocpkg-invalid
- PASS: Cmdliner test_man_utf8 (default)
- PASS: Cmdliner test_nest --help=plain
- PASS: Cmdliner test_nest --ocpkg-invalid
- PASS: Cmdliner test_nest birds fly eagle --speed 5
- PASS: Cmdliner test_nest camels --bactrian
- PASS: Cmdliner test_nest unknown
- PASS: Cmdliner test_opt_req --help=plain
- PASS: Cmdliner test_opt_req --ocpkg-invalid
- PASS: Cmdliner test_opt_req (default)
- PASS: Cmdliner test_opt_req --req value
- PASS: Cmdliner test_pos --help=plain
- PASS: Cmdliner test_pos --ocpkg-invalid
- PASS: Cmdliner test_pos (default)
- PASS: Cmdliner test_pos a b c d
- PASS: Cmdliner test_pos_all --help=plain
- PASS: Cmdliner test_pos_all --ocpkg-invalid
- PASS: Cmdliner test_pos_all (default)
- PASS: Cmdliner test_pos_all a b c
- PASS: Cmdliner test_pos_left --help=plain
- PASS: Cmdliner test_pos_left --ocpkg-invalid
- PASS: Cmdliner test_pos_left (default)
- PASS: Cmdliner test_pos_left a b c d
- PASS: Cmdliner test_pos_req --help=plain
- PASS: Cmdliner test_pos_req --ocpkg-invalid
- PASS: Cmdliner test_pos_req (default)
- PASS: Cmdliner test_pos_req a b c d
- PASS: Cmdliner test_pos_rev --help=plain
- PASS: Cmdliner test_pos_rev --ocpkg-invalid
- PASS: Cmdliner test_pos_rev (default)
- PASS: Cmdliner test_pos_rev a b c d
- PASS: Cmdliner test_term_dups --help=plain
- PASS: Cmdliner test_term_dups --ocpkg-invalid
- PASS: Cmdliner test_term_dups value --flag
- PASS: Cmdliner test_with_used_args --help=plain
- PASS: Cmdliner test_with_used_args --ocpkg-invalid
- PASS: Cmdliner test_with_used_args -a -b value x --other
- PASS: Ptime test_ptime
- PASS: Ptime test_gmtime
- PASS: Ptime examples

## Ptime test groups

- PASS span constants and conversions (30 checks)
- PASS span predicates (16 checks)
- PASS span arithmetic (7 checks)
- PASS span rounding (188 checks)
- PASS span retty printing (119 checks)
- PASS stamp constants and base constructors (22 checks)
- PASS stamp predicates (18 checks)
- PASS stamp POSIX arithmetic (11 checks)
- PASS stamp truncation (195 checks)
- PASS calendar date field bounds (76 checks)
- PASS random valid dates to stamps round trips (100000 checks)
- PASS date-time time field bounds (19 checks)
- PASS testing date-time time zone calculations (11 checks)
- PASS subsecond stamp to date-time (6 checks)
- PASS testing leap second date-times (7 checks)
- PASS random stamps to date-time round trips (200000 checks)
- PASS random valid date-times to stamp round trips (100000 checks)
- PASS Ptime.{weekday_num,weekday} (10 checks)
- PASS stamp to RFC 3339 conversions (28 checks)
- PASS RFC 3339 to stamp conversions (46 checks)
- PASS random stamps to RFC 3339 round trips (300000 checks)
- RESULT passed=21 failed=0 checks=700809
- PASS random Ptime-valid stamps to date-time (200004 checks)
- RESULT passed=1 failed=0 checks=200004

## Receipts

- `build/crunch/non-lwt/all-receipt.json`: all 70 package checks and full per-command logs.
- `build/crunch/non-lwt/harness-receipt.json`: independent assertion-adapter negative controls.
- `packages/evidence/non-lwt-macos-arm64.json`: tracked summary, toolchain identity and adapter hashes.

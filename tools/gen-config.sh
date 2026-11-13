#!/bin/sh
# Generate vendor/qbe/config.h (default target selection), mirroring the
# logic in vendor/qbe/Makefile.
case `uname` in
*Darwin*)
    case `uname -m` in
    *arm64*) echo "#define Deftgt T_arm64_apple" ;;
    *)       echo "#define Deftgt T_amd64_apple" ;;
    esac
    ;;
*)
    case `uname -m` in
    *aarch64*|*arm64*) echo "#define Deftgt T_arm64" ;;
    *riscv64*)         echo "#define Deftgt T_rv64" ;;
    *)                 echo "#define Deftgt T_amd64_sysv" ;;
    esac
    ;;
esac

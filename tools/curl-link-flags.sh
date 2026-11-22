#!/bin/sh
set -eu
case "$(uname -s)" in
    Darwin)
        sdk=$(xcrun --show-sdk-path)
        printf '(-cclib "%s/usr/lib/libcurl.tbd")\n' "$sdk"
        ;;
    *)
        printf '(-cclib -lcurl)\n'
        ;;
esac

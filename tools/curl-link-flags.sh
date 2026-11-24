#!/bin/sh
set -eu
case "$(uname -s)" in
    Darwin)
        sdk=$(xcrun --show-sdk-path)
        printf '%s\n' -cclib "$sdk/usr/lib/libcurl.tbd"
        ;;
    *)
        printf '%s\n' -cclib -lcurl
        ;;
esac

#!/bin/sh
# Runs the package tests. With full Xcode installed a plain `swift test` is
# enough; with only the command line tools the Testing framework has to be
# pointed at explicitly.
set -e
cd "$(dirname "$0")"
if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    exec swift test "$@"
fi
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
    -Xswiftc -F"$FW" \
    -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"

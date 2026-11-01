#!/bin/sh
# Build the optional RetroArch pacing probe for BaseOS.
# Output: work/pacing-probe.so. Copy it to System/socket/retroarch/ on the card
# only while you measure. Remove it after.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
docker run --rm --platform linux/arm64 -v "$HERE/..":/src -w /src socket-baseos-godot \
	cc -O2 -Wall -Wextra -shared -fPIC tools/pacing-probe.c -o work/pacing-probe.so -ldl -lasound

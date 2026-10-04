#!/bin/sh
# Rebuild nullclaw from source and deploy it as the running service binary.
# Usage: nullclaw-rebuild.sh
#
# Lives in the fork (branch locus); each host symlinks it into ~/.local/bin:
#   ln -sf ~/Downloads/nullclaw/scripts/nullclaw-rebuild.sh ~/.local/bin/
# Overrides: NULLCLAW_REPO (default: checkout containing this script),
#            NULLCLAW_BIN  (default: $HOME/.local/bin/nullclaw),
#            ZIG           (default: zig from PATH).
set -e

REPO="${NULLCLAW_REPO:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
BIN="${NULLCLAW_BIN:-$HOME/.local/bin/nullclaw}"
ZIG="${ZIG:-zig}"

if ! command -v "$ZIG" >/dev/null 2>&1; then
    echo "nullclaw-rebuild: zig not found ('$ZIG'); put zig 0.16.0 in PATH or set ZIG=/path/to/zig" >&2
    exit 1
fi

cd "$REPO"

want_zig="0.16.0"
have_zig="$("$ZIG" version)"
if [ "$have_zig" != "$want_zig" ]; then
    echo "nullclaw-rebuild: need zig $want_zig, found $have_zig" >&2
    exit 1
fi

# e.g. 2026.5.29-69-g78147e72-locus (upstream tag, commits since, hash, -dirty if uncommitted)
VERSION="$(git describe --tags --always --dirty | sed 's/^v//')-locus"
echo "==> building nullclaw $VERSION from $REPO"

echo "==> zig build test --summary all"
"$ZIG" build test --summary all

echo "==> zig build -Doptimize=ReleaseSmall -Dversion=$VERSION"
"$ZIG" build -Doptimize=ReleaseSmall -Dversion="$VERSION"

echo "==> backing up current binary to ${BIN}.bak"
cp -f "$BIN" "${BIN}.bak"

echo "==> installing new binary to $BIN"
cp -f "$REPO/zig-out/bin/nullclaw" "$BIN"

echo "==> restarting nullclaw.service"
systemctl --user restart nullclaw.service

sleep 1
systemctl --user status nullclaw.service --no-pager -l | head -10

#!/bin/sh
# Build the prebuilt static binary shipped in src/bin/.
# Requires Rust 1.83+ with the x86_64-unknown-linux-musl target, plus a C
# compiler (gcc) for build scripts. Run from anywhere.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/src/prewarmer-rs"
OUT="$ROOT/src/bin"
mkdir -p "$OUT"

cd "$SRC"

echo "== unit tests =="
cargo test

echo "== musl static build (x86_64) =="
rustup target add x86_64-unknown-linux-musl 2>/dev/null || true
cargo build --release --target x86_64-unknown-linux-musl
cp target/x86_64-unknown-linux-musl/release/oxidns-prewarmer "$OUT/prewarmer-x86_64"
chmod 755 "$OUT/prewarmer-x86_64"

echo "== verify static =="
if ldd "$OUT/prewarmer-x86_64" 2>&1 | grep -q 'not a dynamic'; then
    echo "OK: statically linked"
else
    echo "WARNING: binary may not be static" >&2
fi

echo "== done =="
ls -lh "$OUT"

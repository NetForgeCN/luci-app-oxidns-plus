#!/bin/sh
# Build the prebuilt static binaries shipped in src/bin/.
# Requires Go >= 1.21. Run from anywhere.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/src/prewarmer"
OUT="$ROOT/src/bin"
mkdir -p "$OUT"
cd "$SRC"
export CGO_ENABLED=0

echo "== unit tests =="
go test ./...

echo "== cross build =="
GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$OUT/prewarmer-amd64" .
GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$OUT/prewarmer-arm64" .
GOOS=linux GOARCH=arm  GOARM=7 go build -trimpath -ldflags='-s -w' -o "$OUT/prewarmer-armv7" .
GOOS=linux GOARCH=mips GOMIPS=softfloat go build -trimpath -ldflags='-s -w' -o "$OUT/prewarmer-mips" .
GOOS=linux GOARCH=mipsle GOMIPS=softfloat go build -trimpath -ldflags='-s -w' -o "$OUT/prewarmer-mipsle" .

rm -f "$OUT"/*-go-tmp-umask 2>/dev/null || true
echo "== done =="
ls -lh "$OUT"

#!/usr/bin/env bash
# rh-farm fork build: bundle Src/ -> Cobalt.luau (committed at repo root) so it loadstring's from
#   https://raw.githubusercontent.com/bryson-g/cobalt/main/Cobalt.luau
# Iterate: edit Src/, run ./build.sh, commit + push. (raw.githubusercontent caches ~5 min.)
set -e
cd "$(dirname "$0")"
lune run Build bundle header=Build/Header.luau minify=true ci-mode=true
cp Distribution/Script.luau Cobalt.luau
echo "built -> Cobalt.luau ($(wc -c < Cobalt.luau | tr -d ' ') bytes)"

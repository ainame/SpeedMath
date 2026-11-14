#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
swiftc -target wasm32-unknown-none-wasm -enable-experimental-feature Embedded -wmo -Osize \
  -parse-as-library -c Sources/ProtocolModels/Wire.swift Sources/Worker/Exports.swift -o "$dir/worker.o"
wasm-ld --strip-all --no-entry --export=protocol_version --export=can_relay --export=valid_card --export=valid_snapshot --gc-sections "$dir/worker.o" -o "$dir/logic.wasm"
mkdir -p worker/generated
if ! cmp -s "$dir/logic.wasm" worker/generated/logic.wasm; then
  mv "$dir/logic.wasm" worker/generated/logic.wasm
fi

#!/usr/bin/env bash
set -euo pipefail

# Utility script to simulate TPM signing using an OpenSSL-managed private key.
# Usage:
#   ./mock_sign_root.sh --root 0x1234... --key ./mock_device_private.pem --out ./root.sig.b64
#   ./mock_sign_root.sh --root-file ./bundle.json --key ./mock_device_private.pem --out ./root.sig.b64
#
# Either pass --root with a hex string or point --root-file at a JSON file containing
# a root_hex field (e.g. device/merkle/bundle_mock/bundle.json).

ROOT_HEX=""
ROOT_FILE=""
PRIVATE_KEY=""
OUTPUT_FILE="root.sig.b64"
HASH_ALG="sha256"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_HEX="$2"
      shift 2
      ;;
    --root-file)
      ROOT_FILE="$2"
      shift 2
      ;;
    --key)
      PRIVATE_KEY="$2"
      shift 2
      ;;
    --out)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --hash)
      HASH_ALG="$2"
      shift 2
      ;;
    --help|-h)
      cat <<USAGE
Usage: $0 --key <pem> [--root 0x.. | --root-file bundle.json] [--out root.sig.b64] [--hash sha256]
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$PRIVATE_KEY" ]]; then
  echo "--key is required" >&2
  exit 1
fi

if [[ -z "$ROOT_HEX" ]]; then
  if [[ -n "$ROOT_FILE" ]]; then
    ROOT_HEX=$(jq -r '.root_hex // .root // empty' "$ROOT_FILE")
  fi
fi

if [[ -z "$ROOT_HEX" ]]; then
  echo "Provide a root via --root or --root-file" >&2
  exit 1
fi

ROOT_CLEAN=${ROOT_HEX#0x}
ROOT_BIN=$(mktemp)
trap 'rm -f "$ROOT_BIN"' EXIT

printf "%s" "$ROOT_CLEAN" | xxd -r -p > "$ROOT_BIN"

openssl dgst -$HASH_ALG -sign "$PRIVATE_KEY" -binary "$ROOT_BIN" | base64 > "$OUTPUT_FILE"

echo "Mock signature written to $OUTPUT_FILE"

#!/usr/bin/env bash
set -euo pipefail

# This script orchestrates the Noir -> Barretenberg flow for the real_frame_proof circuit.
# It assumes the following binaries are on PATH:
#   - nargo (matching compiler version declared in Nargo.toml)
#   - bb (Barretenberg CLI)
#
# Usage examples:
#   ./build_and_prove.sh                         # compile + prove using noir/Prover.toml
#   ./build_and_prove.sh --input ./Prover.toml   # point to a different prover input file
#   ./build_and_prove.sh --generate-mock         # regenerate mock inputs from the merkle helper before proving
#   ./build_and_prove.sh --output ./artifacts    # change output directory for proof bundle

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRAM_NAME="real_frame_proof"
INPUT_FILE="$PROJECT_DIR/Prover.toml"
OUTPUT_DIR="$PROJECT_DIR/target/artifacts"
GENERATE_MOCK=false
MERKLE_HELPER_DIR="$PROJECT_DIR/../device/merkle"

to_abs() {
  local target="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target"
  else
    TARGET="$target" python3 - <<'PY'
import os
print(os.path.abspath(os.path.expanduser(os.environ["TARGET"])))
PY
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_FILE="$(to_abs "$2")"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="$(to_abs "$2")"
      shift 2
      ;;
    --generate-mock)
      GENERATE_MOCK=true
      shift 1
      ;;
    --help|-h)
      cat <<USAGE
Usage: $0 [--input Prover.toml] [--output ./dir] [--generate-mock]

--input           Path to Prover.toml (defaults to noir/Prover.toml)
--output          Directory for witness/proof/vk outputs (default noir/target/artifacts)
--generate-mock   Rebuilds mock bundle via yarn bundle:mock before proving
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$GENERATE_MOCK" == true ]]; then
  echo "[build_and_prove] Generating mock bundle via merkle helper"
  pushd "$MERKLE_HELPER_DIR" >/dev/null
  yarn bundle:mock --out-dir "$MERKLE_HELPER_DIR/bundle_mock" --target-index 0 --count 4
  popd >/dev/null
  INPUT_FILE="$(to_abs "$MERKLE_HELPER_DIR/bundle_mock/Prover.toml")"
fi

mkdir -p "$OUTPUT_DIR"

ACIR_JSON="$PROJECT_DIR/target/${PROGRAM_NAME}.json"
WITNESS_PATH="$OUTPUT_DIR/${PROGRAM_NAME}.witness"
PROOF_PATH="$OUTPUT_DIR/${PROGRAM_NAME}.proof"
PUBLIC_PATH="$OUTPUT_DIR/${PROGRAM_NAME}.public.json"
VK_PATH="$OUTPUT_DIR/${PROGRAM_NAME}.vk"
SOL_VERIFIER_DIR="$OUTPUT_DIR/onchain"
SOL_VERIFIER_PATH="$SOL_VERIFIER_DIR/Verifier.sol"

NARGO_BIN=${NARGO_BIN:-"nargo"}
BB_BIN=${BB_BIN:-"bb"}

set -x
"$NARGO_BIN" check --program-dir "$PROJECT_DIR"
"$NARGO_BIN" compile --program-dir "$PROJECT_DIR" --output-path "$ACIR_JSON"
"$NARGO_BIN" execute --program-dir "$PROJECT_DIR" --input "$INPUT_FILE" --witness "$WITNESS_PATH"
"$BB_BIN" prove -b "$ACIR_JSON" -w "$WITNESS_PATH" -o "$PROOF_PATH" --public-inputs "$PUBLIC_PATH"
"$BB_BIN" write_vk -b "$ACIR_JSON" -o "$VK_PATH"
mkdir -p "$SOL_VERIFIER_DIR"
"$NARGO_BIN" codegen-verifier --program-dir "$PROJECT_DIR" --vk "$VK_PATH" --output "$SOL_VERIFIER_PATH"
"$BB_BIN" verify -k "$VK_PATH" -p "$PROOF_PATH"
set +x

echo "\n[build_and_prove] Outputs written to $OUTPUT_DIR"
echo "  • ACIR: $ACIR_JSON"
echo "  • Witness: $WITNESS_PATH"
echo "  • Proof: $PROOF_PATH"
echo "  • Public inputs: $PUBLIC_PATH"
echo "  • Verifying key: $VK_PATH"
echo "  • Solidity verifier: $SOL_VERIFIER_PATH"

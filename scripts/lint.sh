#!/usr/bin/env bash
# Verilator --lint-only pass over the rtl/ tree.
#
# Usage:  ./scripts/lint.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

VERILATOR_BIN="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR_BIN" >/dev/null 2>&1; then
  echo "Verilator not found in PATH. (Tried '$VERILATOR_BIN'.)"
  exit 2
fi

mapfile -t RTL_SRCS < <(ls rtl/*.sv 2>/dev/null)
if [ ${#RTL_SRCS[@]} -eq 0 ]; then
  echo "No RTL files found in rtl/"
  exit 1
fi

mkdir -p sim/verilator/lint

# Lint each module that has a `module name; ... endmodule` matching its
# filename. We lint with a synthetic top-module so Verilator includes the
# whole RTL set as a library.
"$VERILATOR_BIN" \
  --lint-only \
  --sv \
  -Wall \
  -Wno-DECLFILENAME \
  -Wno-UNUSEDSIGNAL \
  -Wno-UNUSEDPARAM \
  -Irtl \
  --Mdir sim/verilator/lint \
  "${RTL_SRCS[@]}" \
  --top-module s3_io_decode

echo "lint: ok"

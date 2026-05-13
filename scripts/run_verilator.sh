#!/usr/bin/env bash
# Run all SystemVerilog testbenches under sim/verilator using Verilator's
# --binary build. Each TB compiles + runs in its own obj_dir.
#
# Usage:  ./scripts/run_verilator.sh [tb_name ...]
#         (omit args to run every tb_*.sv in tb/)
#
# Exit code is the count of failed TBs.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

RTL_DIR="rtl"
TB_DIR="tb"
SIM_DIR="sim/verilator"
mkdir -p "$SIM_DIR"

# Allow filtering by TB name on the command line.
if [ $# -gt 0 ]; then
  tbs=()
  for n in "$@"; do
    tbs+=("$TB_DIR/$n.sv")
  done
else
  mapfile -t tbs < <(ls "$TB_DIR"/tb_*.sv 2>/dev/null | sort)
fi

if [ ${#tbs[@]} -eq 0 ]; then
  echo "No testbenches found in $TB_DIR/"
  exit 1
fi

VERILATOR_BIN="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR_BIN" >/dev/null 2>&1; then
  echo "Verilator not found in PATH. (Tried '$VERILATOR_BIN'.)"
  echo "Set VERILATOR=/path/to/verilator or install via your package manager."
  exit 2
fi

VFLAGS=(
  --binary
  --timing
  --sv
  -Wall
  -Wno-fatal
  -Wno-DECLFILENAME           # tb files contain the module of the same name
  -Wno-UNUSEDSIGNAL
  -Wno-UNUSEDPARAM
  -j 0
  -I"$RTL_DIR"
)

# Collect all rtl/*.sv as the design source set. We let each TB pick its DUT
# via its `include directives — Verilator will only elaborate what's reachable
# from the top module.
mapfile -t RTL_SRCS < <(ls "$RTL_DIR"/*.sv 2>/dev/null)

fail=0
pass=0
for tb in "${tbs[@]}"; do
  name="$(basename "$tb" .sv)"
  out_dir="$SIM_DIR/$name"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  echo "==========================================================="
  echo "[verilator] $name"
  echo "==========================================================="

  build_log="$out_dir/build.log"
  if ! "$VERILATOR_BIN" "${VFLAGS[@]}" \
        --Mdir "$out_dir" \
        --top-module "$name" \
        "${RTL_SRCS[@]}" "$tb" \
        >"$build_log" 2>&1; then
    echo "BUILD FAIL ($name) — see $build_log"
    tail -40 "$build_log"
    fail=$((fail+1))
    continue
  fi

  bin="$out_dir/V$name"
  if [ ! -x "$bin" ]; then
    echo "BUILD produced no binary ($bin) — see $build_log"
    tail -40 "$build_log"
    fail=$((fail+1))
    continue
  fi

  run_log="$out_dir/run.log"
  if "$bin" >"$run_log" 2>&1; then
    if grep -q "^PASS" "$run_log"; then
      echo "PASS ($name)"
      pass=$((pass+1))
    else
      echo "RUN FAIL ($name) — no PASS marker"
      tail -40 "$run_log"
      fail=$((fail+1))
    fi
  else
    echo "RUN FAIL ($name) — non-zero exit"
    tail -40 "$run_log"
    fail=$((fail+1))
  fi
done

echo "==========================================================="
echo "SUMMARY: $pass passed, $fail failed"
echo "==========================================================="
exit "$fail"

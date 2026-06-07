#!/bin/bash
# ============================================================================
# TPC-C Benchmark — go-tpc against YugabyteDB YSQL
#
# Usage:
#   bash scripts/08-tpcc-benchmark.sh [warehouses] [threads] [duration]
#
# Examples:
#   bash scripts/08-tpcc-benchmark.sh 4 4 2m          # smoke test
#   bash scripts/08-tpcc-benchmark.sh 20 8 10m         # full run
#
# Prerequisites: cluster already running (make up)
# ============================================================================
set -euo pipefail

WAREHOUSES="${1:-10}"
THREADS="${2:-8}"
DURATION="${3:-5m}"
HOST="${4:-yb-1}"
PORT="${5:-5433}"
DB="tpcc"
USER="yugabyte"
PASS="yugabyte"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

TPCC_RUN="docker compose -f compose/base.yaml -f compose/tpcc.yaml run --rm -T tpcc"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     TPC-C Benchmark (go-tpc)                             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  Warehouses:  $WAREHOUSES"
echo "  Threads:     $THREADS"
echo "  Duration:    $DURATION"
echo "  Host:        $HOST:$PORT"
echo "  Database:    $DB"
echo ""

cd "$PROJECT_ROOT"

# ── Step 1: Build image if needed ─────────────────────────────────────
echo "=== Step 1: Build TPC-C image ==="
docker compose -f compose/base.yaml -f compose/tpcc.yaml build tpcc 2>&1 | tail -3
echo ""

# ── Step 2: Create tpcc database ──────────────────────────────────────
echo "=== Step 2: Create database '$DB' ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -U "$USER" \
  -c "CREATE DATABASE $DB;" 2>/dev/null && echo "  Database '$DB' created" || echo "  Database '$DB' already exists"
echo ""

# ── Step 3: Prepare (schema + data load) ──────────────────────────────
echo "=== Step 3: Prepare TPC-C schema ($WAREHOUSES warehouses) ==="
$TPCC_RUN go-tpc tpcc --warehouses "$WAREHOUSES" prepare \
  -d postgres -U "$USER" -p "$PASS" -D "$DB" \
  -H "$HOST" -P "$PORT" --conn-params sslmode=disable \
  -T "$THREADS" --ignore-error --no-check
echo ""

# ── Step 4: Run benchmark ─────────────────────────────────────────────
echo "=== Step 4: Run TPC-C benchmark ($THREADS threads, $DURATION) ==="
START_TS=$(date +%s)
RAW_OUTPUT=$($TPCC_RUN go-tpc tpcc --warehouses "$WAREHOUSES" run \
  -d postgres -U "$USER" -p "$PASS" -D "$DB" \
  -H "$HOST" -P "$PORT" --conn-params sslmode=disable \
  -T "$THREADS" --time "$DURATION" --ignore-error 2>&1)
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
echo "$RAW_OUTPUT"
echo ""

# ── Step 5: Parse tpmC ────────────────────────────────────────────────
echo "=== Step 5: Results ==="

# Extract the final summary line: "tpmC: 34.0, tpmTotal: 76.9, efficiency: 26.5%"
SUMMARY=$(echo "$RAW_OUTPUT" | grep -oE 'tpmC: [0-9.]+.*efficiency: [0-9.]+%' | tail -1)
TPMC=$(echo "$SUMMARY" | grep -oE 'tpmC: [0-9.]+' | grep -oE '[0-9.]+')
TPM_TOTAL=$(echo "$SUMMARY" | grep -oE 'tpmTotal: [0-9.]+' | grep -oE '[0-9.]+')
EFFICIENCY=$(echo "$SUMMARY" | grep -oE 'efficiency: [0-9.]+%' | grep -oE '[0-9.]+%')

# Extract per-transaction summaries
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                    TPC-C BENCHMARK RESULTS                          ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  Warehouses: %-5s   Threads: %-5s   Duration: %-6s              ║\n" "$WAREHOUSES" "$THREADS" "$DURATION"
printf "║  Wall time:  %-5ss                                                    ║\n" "$ELAPSED"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  tpmC:       %-10s  (NEW_ORDER transactions/min)                 ║\n" "${TPMC:-N/A}"
printf "║  tpmTotal:   %-10s  (all transactions/min)                       ║\n" "${TPM_TOTAL:-N/A}"
printf "║  Efficiency: %-10s  (tpmC / 12.86×warehouses × 100%%)            ║\n" "${EFFICIENCY:-N/A}"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Print per-transaction breakdown
echo "Per-transaction summary:"
echo "$RAW_OUTPUT" | grep '^\[Summary\]' || echo "  (no summary lines found)"

# ── Step 6: Cleanup ───────────────────────────────────────────────────
echo ""
echo "=== Step 6: Cleanup TPC-C data ==="
$TPCC_RUN go-tpc tpcc --warehouses "$WAREHOUSES" cleanup \
  -d postgres -U "$USER" -p "$PASS" -D "$DB" \
  -H "$HOST" -P "$PORT" --conn-params sslmode=disable 2>/dev/null || true
docker compose exec -T yb-1 ysqlsh -h "$HOST" -U "$USER" \
  -c "DROP DATABASE IF EXISTS $DB;" 2>/dev/null || true
echo ""

echo "TPC-C benchmark complete."

#!/bin/bash
# ============================================================================
# Scalability Test — throughput vs node count
#
# Tests whether YugabyteDB throughput scales linearly with node count.
# Uses pgbench (TPC-B) for quick, reproducible throughput measurement.
#
# Usage:
#   bash scripts/09-scalability-test.sh
#
# Prerequisites: Docker, docker compose
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Configuration ─────────────────────────────────────────────────────
NODE_COUNTS=(1 3 5)
PG_CLIENTS=16          # pgbench concurrent clients
PG_DURATION=60         # pgbench duration per test (seconds)
PG_SCALE=20            # pgbench scale factor

# ── Results storage ───────────────────────────────────────────────────
declare -A TPS_RESULTS
declare -A LATENCY_RESULTS

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

cd "$PROJECT_ROOT"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Scalability Test — Throughput vs Node Count              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  Node counts:   ${NODE_COUNTS[*]}"
echo "  pgbench:       ${PG_CLIENTS} clients, ${PG_DURATION}s, scale=${PG_SCALE}"
echo ""

# ── Build bench image once ───────────────────────────────────────────
echo "=== Building bench image (pgbench) ==="
docker compose -f compose/base.yaml -f compose/bench.yaml build pg 2>&1 | tail -3
echo ""

# ── Iterate over node counts ──────────────────────────────────────────
for N in "${NODE_COUNTS[@]}"; do
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Testing with N=$N node(s)                                    ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""

  # ── Clean up any previous run ─────────────────────────────────────
  echo "  Cleaning up previous environment..."
  docker compose -f compose/base.yaml down -v 2>/dev/null || true
  sleep 3

  # ── Build node list ────────────────────────────────────────────────
  NODE_LIST=""
  for i in $(seq 1 "$N"); do
    NODE_LIST="$NODE_LIST yb-$i"
  done
  # trim leading space
  NODE_LIST="${NODE_LIST# }"
  COMPOSE="docker compose -f compose/base.yaml"
  echo "  Starting nodes: $NODE_LIST"

  # ── Start N nodes ──────────────────────────────────────────────────
  $COMPOSE up -d $NODE_LIST ui-7000 ui-15433 2>&1 | tail -5

  # ── Custom wait loop (replaces rfNready for variable N) ─────────────
  echo "  Waiting for all $N node(s) to accept connections..."
  ALL_READY=false
  for try in $(seq 1 120); do
    ready_count=0
    for i in $(seq 1 "$N"); do
      if docker compose exec -T "yb-$i" bash -c 'postgres/bin/pg_isready -h $(hostname) -p 5433' 2>/dev/null; then
        ready_count=$((ready_count + 1))
      fi
    done
    if [ "$ready_count" -eq "$N" ]; then
      ALL_READY=true
      echo "  All $N node(s) ready after ${try}s"
      break
    fi
    sleep 1
  done

  if [ "$ALL_READY" = false ]; then
    red "  FAIL: Nodes did not become ready within 120s"
    continue
  fi

  # ── Wait for YB-Master to discover all nodes ────────────────────────
  echo "  Waiting for YB-Master to register all nodes..."
  sleep 5
  for try in $(seq 1 30); do
    registered=$(docker compose exec -T yb-1 ysqlsh -h yb-1 -tAc \
      "SELECT count(*) FROM yb_servers();" 2>/dev/null || echo "0")
    registered=$(echo "$registered" | tr -d '[:space:]')
    if [ "$registered" -ge "$N" ]; then
      echo "  YB-Master sees $registered node(s)"
      break
    fi
    sleep 2
  done

  # ── Show cluster topology ──────────────────────────────────────────
  echo "  Cluster topology:"
  docker compose exec -T yb-1 ysqlsh -h yb-1 -c \
    "SELECT host, cloud, region, zone, node_type FROM yb_servers() ORDER BY host;" 2>/dev/null || true
  echo ""

  # ── Initialize pgbench ─────────────────────────────────────────────
  echo "  Initializing pgbench (scale=$PG_SCALE)..."
  docker compose -f compose/base.yaml -f compose/bench.yaml run --rm -T pg bash -c "
    export PGHOST=yb-1 PGPORT=5433 PGUSER=yugabyte PGDATABASE=yugabyte PGPASSWORD=yugabyte
    dropdb --if-exists pgbench 2>/dev/null
    createdb pgbench 2>/dev/null
    pgbench -i -s $PG_SCALE pgbench
  " 2>&1 | tail -3
  echo ""

  # ── Run pgbench throughput test ────────────────────────────────────
  echo "  Running pgbench ($PG_CLIENTS clients, ${PG_DURATION}s)..."
  BENCH_OUTPUT=$(docker compose -f compose/base.yaml -f compose/bench.yaml run --rm -T pg bash -c "
    export PGHOST=yb-1 PGPORT=5433 PGUSER=yugabyte PGDATABASE=pgbench PGPASSWORD=yugabyte
    pgbench -c $PG_CLIENTS -j $PG_CLIENTS -T $PG_DURATION pgbench
  " 2>&1)

  # ── Parse results ──────────────────────────────────────────────────
  TPS=$(echo "$BENCH_OUTPUT" | grep -oE 'tps = [0-9.]+' | grep -oE '[0-9.]+' | head -1)
  LATENCY=$(echo "$BENCH_OUTPUT" | grep -oE 'latency average = [0-9.]+' | grep -oE '[0-9.]+' | head -1)

  TPS_RESULTS[$N]="${TPS:-0}"
  LATENCY_RESULTS[$N]="${LATENCY:-0}"

  echo ""
  green "  N=$N: TPS = ${TPS_RESULTS[$N]}, Avg Latency = ${LATENCY_RESULTS[$N]} ms"
  echo "$BENCH_OUTPUT" | tail -8
  echo ""

done

# ── Final cleanup ─────────────────────────────────────────────────────
echo "=== Cleaning up ==="
docker compose -f compose/base.yaml down -v 2>/dev/null || true
sleep 2

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              SCALABILITY TEST SUMMARY                        ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-10s │ %-12s │ %-12s │ %-10s ║\n" "Nodes" "TPS" "Latency(ms)" "Scale Factor"
echo "╠══════════════════════════════════════════════════════════════╣"

BASE_TPS=""
for N in "${NODE_COUNTS[@]}"; do
  tps="${TPS_RESULTS[$N]}"
  lat="${LATENCY_RESULTS[$N]}"

  # Calculate scale factor relative to 1-node
  if [ -z "$BASE_TPS" ] && [ "$tps" != "0" ] && [ "$tps" != "" ]; then
    BASE_TPS="$tps"
    scale_factor="1.00×"
  elif [ -n "$BASE_TPS" ] && [ "$tps" != "0" ] && [ "$tps" != "" ] && [ "$BASE_TPS" != "0" ]; then
    ratio=$(echo "scale=2; $tps / $BASE_TPS" | bc 2>/dev/null || echo "N/A")
    scale_factor="${ratio}×"
  else
    scale_factor="N/A"
  fi

  printf "║  %-10s │ %-12s │ %-12s │ %-10s ║\n" "$N" "$tps" "$lat" "$scale_factor"
done

echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Check linear scaling (ideal: N nodes = N× throughput)
if [ "$N" -ge 1 ] 2>/dev/null; then
  echo "Linear scaling analysis:"
  echo "  If throughput scales linearly: 5 nodes ≈ 5× of 1 node"
  echo "  Actual scaling shown in 'Scale Factor' column above."
fi

echo ""
echo "Scalability test complete."

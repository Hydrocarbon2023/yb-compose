#!/bin/bash
#
# 07-flapping-node-test.sh - Flapping node resilience test
# Tests cluster behavior under intermittent network partitions
#
# Phases:
#   1. Baseline (15s): Measure read latency under normal conditions
#   2. Flapping (120s): Cycle network partition on/off every 5s while under load
#   3. Recovery (15s): Measure read latency after flapping ends
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
TARGET_NODE="${TARGET_NODE:-region2}"
CYCLES="${CYCLES:-12}"
INTERVAL="${INTERVAL:-5}"
BASELINE_DURATION=15
RECOVERY_DURATION=15
SAMPLE_INTERVAL=3

# Data collection
BASELINE_LATENCIES=()
FLAPPING_HEALTHY_LATENCIES=()
FLAPPING_ISOLATED_LATENCIES=()
RECOVERY_LATENCIES=()

# State tracking
IS_ISOLATED=0
FLAPPING_PID=""

# Cleanup on exit
cleanup() {
  echo ""
  echo "=== Cleanup ==="
  [ -n "$FLAPPING_PID" ] && kill "$FLAPPING_PID" 2>/dev/null || true
  cd "$PROJECT_ROOT"
  make chaos CMD="partition heal all" >/dev/null 2>&1 || true
  echo "  Network healed"
}
trap cleanup EXIT

# Measure read latency from yb-2
measure_read_latency() {
  local start end latency
  start=$(python3 -c 'import time; print(int(time.time()*1000))')
  if ! docker compose exec -T yb-2 ysqlsh -h yb-2 -tAc "SELECT id FROM perf_test WHERE id = 1;" >/dev/null 2>&1; then
    echo "-1"
    return
  fi
  end=$(python3 -c 'import time; print(int(time.time()*1000))')
  latency=$(( end - start ))
  echo "$latency"
}

# Check if target node is currently isolated
check_isolation_state() {
  local state
  state=$(docker compose exec -T yb-2 ysqlsh -h yb-2 -tAc "SELECT count(*) FROM yb_servers();" 2>/dev/null || echo "0")
  if [ "$state" -lt 5 ]; then
    IS_ISOLATED=1
  else
    IS_ISOLATED=0
  fi
}

# Calculate percentile
percentile() {
  local p="$1"
  shift
  local values=("$@")
  local sorted count idx

  [ ${#values[@]} -eq 0 ] && { echo "0"; return; }

  # Sort values
  IFS=$'\n' sorted=($(sort -n <<<"${values[*]}")); unset IFS
  count=${#sorted[@]}
  idx=$(( (count * p + 50) / 100 ))
  [ $idx -ge $count ] && idx=$((count - 1))
  echo "${sorted[$idx]}"
}

# Calculate average
average() {
  local values=("$@")
  local sum=0 count=${#values[@]}

  [ $count -eq 0 ] && { echo "0"; return; }

  for v in "${values[@]}"; do
    sum=$((sum + v))
  done
  echo $((sum / count))
}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Flapping Node Resilience Test                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration:"
echo "  Target node:    $TARGET_NODE"
echo "  Cycles:         $CYCLES"
echo "  Interval:       ${INTERVAL}s"
echo "  Baseline:       ${BASELINE_DURATION}s"
echo "  Recovery:       ${RECOVERY_DURATION}s"
echo ""

cd "$PROJECT_ROOT"

# ============================================================
# Phase 1: Baseline (15s)
# ============================================================
echo "=== Phase 1: Baseline (${BASELINE_DURATION}s) ==="
echo "  Measuring read latency under normal conditions..."
echo ""

baseline_samples=$((BASELINE_DURATION / SAMPLE_INTERVAL))
for i in $(seq 1 "$baseline_samples"); do
  latency=$(measure_read_latency)
  [ "$latency" -gt 0 ] && BASELINE_LATENCIES+=("$latency")
  echo "  [baseline $i/$baseline_samples] latency: ${latency}ms"
  sleep "$SAMPLE_INTERVAL"
done

baseline_avg=$(average "${BASELINE_LATENCIES[@]}")
baseline_p50=$(percentile 50 "${BASELINE_LATENCIES[@]}")
baseline_p99=$(percentile 99 "${BASELINE_LATENCIES[@]}")

echo ""
echo "  Baseline stats: avg=${baseline_avg}ms, P50=${baseline_p50}ms, P99=${baseline_p99}ms"
echo ""

# ============================================================
# Phase 2: Flapping (120s) with continuous write load
# ============================================================
echo "=== Phase 2: Flapping Node (${CYCLES} cycles × ${INTERVAL}s × 2) ==="
echo "  Starting continuous write load from yb-2..."
echo "  Starting flapping scenario on $TARGET_NODE..."
echo ""

# Start background write load
(
  for i in $(seq 1 200); do
    docker compose exec -T yb-2 ysqlsh -h yb-2 -c "INSERT INTO perf_test (data) VALUES (repeat('x', 256));" 2>/dev/null || true
    sleep 0.5
  done
) &
WRITE_PID=$!

# Start flapping scenario in background
make chaos CMD="scenario run flapping-node $TARGET_NODE $CYCLES $INTERVAL" >/dev/null 2>&1 &
FLAPPING_PID=$!

# Monitor reads during flapping
flapping_duration=$((CYCLES * INTERVAL * 2))
flapping_samples=$((flapping_duration / SAMPLE_INTERVAL))

for i in $(seq 1 "$flapping_samples"); do
  latency=$(measure_read_latency)
  check_isolation_state

  if [ "$latency" -gt 0 ]; then
    if [ "$IS_ISOLATED" -eq 1 ]; then
      FLAPPING_ISOLATED_LATENCIES+=("$latency")
      echo "  [flapping $i/$flapping_samples] latency: ${latency}ms (ISOLATED)"
    else
      FLAPPING_HEALTHY_LATENCIES+=("$latency")
      echo "  [flapping $i/$flapping_samples] latency: ${latency}ms (healthy)"
    fi
  else
    echo "  [flapping $i/$flapping_samples] latency: TIMEOUT"
  fi

  sleep "$SAMPLE_INTERVAL"
done

# Wait for flapping to complete
wait "$FLAPPING_PID" 2>/dev/null || true
FLAPPING_PID=""
wait "$WRITE_PID" 2>/dev/null || true

echo ""
echo "  Flapping phase complete"
echo ""

# ============================================================
# Phase 3: Recovery (15s)
# ============================================================
echo "=== Phase 3: Recovery (${RECOVERY_DURATION}s) ==="
echo "  Measuring read latency after flapping..."
echo ""

recovery_samples=$((RECOVERY_DURATION / SAMPLE_INTERVAL))
for i in $(seq 1 "$recovery_samples"); do
  latency=$(measure_read_latency)
  [ "$latency" -gt 0 ] && RECOVERY_LATENCIES+=("$latency")
  echo "  [recovery $i/$recovery_samples] latency: ${latency}ms"
  sleep "$SAMPLE_INTERVAL"
done

recovery_avg=$(average "${RECOVERY_LATENCIES[@]}")
recovery_p50=$(percentile 50 "${RECOVERY_LATENCIES[@]}")
recovery_p99=$(percentile 99 "${RECOVERY_LATENCIES[@]}")

echo ""
echo "  Recovery stats: avg=${recovery_avg}ms, P50=${recovery_p50}ms, P99=${recovery_p99}ms"
echo ""

# ============================================================
# Summary
# ============================================================
flapping_healthy_avg=$(average "${FLAPPING_HEALTHY_LATENCIES[@]}")
flapping_healthy_p50=$(percentile 50 "${FLAPPING_HEALTHY_LATENCIES[@]}")
flapping_healthy_p99=$(percentile 99 "${FLAPPING_HEALTHY_LATENCIES[@]}")

flapping_isolated_avg=$(average "${FLAPPING_ISOLATED_LATENCIES[@]}")
flapping_isolated_p50=$(percentile 50 "${FLAPPING_ISOLATED_LATENCIES[@]}")
flapping_isolated_p99=$(percentile 99 "${FLAPPING_ISOLATED_LATENCIES[@]}")

# Combined flapping stats
all_flapping=("${FLAPPING_HEALTHY_LATENCIES[@]}" "${FLAPPING_ISOLATED_LATENCIES[@]}")
flapping_avg=$(average "${all_flapping[@]}")
flapping_p50=$(percentile 50 "${all_flapping[@]}")
flapping_p99=$(percentile 99 "${all_flapping[@]}")

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    TEST SUMMARY                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Phase              | Samples | Avg (ms) | P50 (ms) | P99 (ms)"
echo "-------------------|---------|----------|----------|---------"
printf "Baseline           | %7d | %8d | %8d | %8d\n" "${#BASELINE_LATENCIES[@]}" "$baseline_avg" "$baseline_p50" "$baseline_p99"
printf "Flapping (healthy) | %7d | %8d | %8d | %8d\n" "${#FLAPPING_HEALTHY_LATENCIES[@]}" "$flapping_healthy_avg" "$flapping_healthy_p50" "$flapping_healthy_p99"
printf "Flapping (isolated)| %7d | %8d | %8d | %8d\n" "${#FLAPPING_ISOLATED_LATENCIES[@]}" "$flapping_isolated_avg" "$flapping_isolated_p50" "$flapping_isolated_p99"
printf "Flapping (combined)| %7d | %8d | %8d | %8d\n" "${#all_flapping[@]}" "$flapping_avg" "$flapping_p50" "$flapping_p99"
printf "Recovery           | %7d | %8d | %8d | %8d\n" "${#RECOVERY_LATENCIES[@]}" "$recovery_avg" "$recovery_p50" "$recovery_p99"
echo ""

# Degradation analysis
if [ "$baseline_p99" -gt 0 ] && [ "$flapping_p99" -gt 0 ]; then
  # Use bc for floating point
  degradation=$(echo "scale=1; $flapping_p99 / $baseline_p99" | bc 2>/dev/null || echo "N/A")
  echo "P99 degradation: ${degradation}× vs baseline"
fi

if [ "$baseline_avg" -gt 0 ] && [ "$recovery_avg" -gt 0 ]; then
  recovery_ratio=$(echo "scale=1; $recovery_avg / $baseline_avg" | bc 2>/dev/null || echo "N/A")
  echo "Recovery ratio:  ${recovery_ratio}× vs baseline"
fi

echo ""
echo "Test complete."

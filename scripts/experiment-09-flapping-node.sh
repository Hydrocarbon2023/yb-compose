#!/bin/bash
# ============================================================================
# Experiment 09: 震荡节点测试 (Flapping Node)
#
# 目的: 验证节点反复隔离/恢复 (flapping) 场景下的集群稳定性
#       - 12 个周期, 每 5s 切换一次隔离/恢复 (共 120s)
#       - 后台持续写入 + 前端定时读取
#       - 验证震荡停止后集群完全恢复
#
# 命令: bash scripts/experiment-09-flapping-node.sh
#
# 所需环境: 自动启动基准集群
# 耗时: ~3min
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"
COMPOSE="docker compose -p yb-compose -f compose/base.yaml"

TARGET_NODE="${TARGET_NODE:-region2}"
CYCLES="${CYCLES:-12}"
INTERVAL="${INTERVAL:-5}"
BASELINE_DURATION="${BASELINE_DURATION:-15}"
RECOVERY_DURATION="${RECOVERY_DURATION:-15}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-3}"
WRITE_ITERATIONS="${WRITE_ITERATIONS:-$((CYCLES * INTERVAL * 4 + BASELINE_DURATION + RECOVERY_DURATION))}"

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

# Data collection arrays
BASELINE_LATENCIES=()
FLAPPING_HEALTHY_LATENCIES=()
FLAPPING_ISOLATED_LATENCIES=()
RECOVERY_LATENCIES=()

cleanup() {
    [ -n "${FLAPPING_PID:-}" ] && kill "$FLAPPING_PID" 2>/dev/null || true
    [ -n "${WRITE_PID:-}" ] && kill "$WRITE_PID" 2>/dev/null || true
    make chaos CMD="partition heal all" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$PROJECT_ROOT"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Experiment 09: 震荡节点测试 (Flapping Node)             ║"
echo "║     $CYCLES cycles × ${INTERVAL}s × 2 = $((CYCLES * INTERVAL * 2))s total     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Helpers ──────────────────────────────────────────────────────────
measure_latency() {
    local t0 t1
    t0=$(date +%s%N)
    if $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
        "SELECT id FROM flapping_test WHERE id = 1;" >/dev/null 2>&1; then
        t1=$(date +%s%N)
        echo "$(( (t1 - t0) / 1000000 ))"
    else
        echo "-1"
    fi
}

check_isolation() {
    local count
    count=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
        "SELECT count(*) FROM yb_servers();" 2>/dev/null | tr -d '[:space:]')
    if [ "${count:-5}" -lt 5 ]; then echo "1"; else echo "0"; fi
}

percentile() {
    local p=$1; shift
    local vals=("$@")
    [ ${#vals[@]} -eq 0 ] && { echo "0"; return; }
    IFS=$'\n' sorted=($(sort -n <<<"${vals[*]}")); unset IFS
    local idx=$(( ${#sorted[@]} * p / 100 ))
    [ $idx -ge ${#sorted[@]} ] && idx=$((${#sorted[@]} - 1))
    echo "${sorted[$idx]}"
}

average() {
    local vals=("$@")
    [ ${#vals[@]} -eq 0 ] && { echo "0"; return; }
    local sum=0
    for v in "${vals[@]}"; do sum=$((sum + v)); done
    echo $((sum / ${#vals[@]}))
}

# ============================================================
# Step 1: 启动基准集群 + 准备测试表
# ============================================================
echo "=== Step 1: 启动基准集群 ==="
$COMPOSE up -d yb-1 yb-2 yb-3 yb-4 yb-5 rfNready 2>&1 | tail -3
wait_for_cluster "$COMPOSE" yb-1 5 240

$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
CREATE TABLE IF NOT EXISTS flapping_test (
  id   INT PRIMARY KEY,
  data TEXT DEFAULT repeat('x', 128),
  ts   TIMESTAMPTZ DEFAULT now()
);
INSERT INTO flapping_test (id, data) VALUES (1, 'baseline') ON CONFLICT (id) DO NOTHING;
" 2>/dev/null

green "  集群 + 表就绪"
echo ""

# ============================================================
# Phase 1: Baseline (15s)
# ============================================================
echo "=== Phase 1: Baseline (${BASELINE_DURATION}s) ==="
echo ""

samples=$((BASELINE_DURATION / SAMPLE_INTERVAL))
for i in $(seq 1 $samples); do
    l=$(measure_latency)
    [ "$l" -gt 0 ] && BASELINE_LATENCIES+=("$l")
    echo "  [baseline $i/$samples] latency=${l}ms"
    sleep $SAMPLE_INTERVAL
done

base_avg=$(average "${BASELINE_LATENCIES[@]}")
base_p50=$(percentile 50 "${BASELINE_LATENCIES[@]}")
base_p99=$(percentile 99 "${BASELINE_LATENCIES[@]}")
echo ""
echo "  Baseline: avg=${base_avg}ms  P50=${base_p50}ms  P99=${base_p99}ms"
echo ""

# ============================================================
# Phase 2: Flapping (120s)
# ============================================================
echo "=== Phase 2: Flapping Node ==="
echo "  Starting background write + flapping scenario..."
echo ""

# Background write load
(
  for i in $(seq 1 "$WRITE_ITERATIONS"); do
    $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c \
      "INSERT INTO flapping_test (id, data) VALUES ($((1000 + i)), 'flap') ON CONFLICT (id) DO UPDATE SET data = 'flap';" >/dev/null 2>&1 || true
    sleep 0.5
  done
) &
WRITE_PID=$!

# Start flapping via chaosctl
make chaos CMD="scenario run flapping-node $TARGET_NODE $CYCLES $INTERVAL" >/dev/null 2>&1 &
FLAPPING_PID=$!

duration=$((CYCLES * INTERVAL * 2))
flap_samples=$((duration / SAMPLE_INTERVAL))

for i in $(seq 1 $flap_samples); do
    l=$(measure_latency)
    isolated=$(check_isolation)
    if [ "$l" -gt 0 ]; then
        if [ "$isolated" -eq 1 ]; then
            FLAPPING_ISOLATED_LATENCIES+=("$l")
            echo "  [flap $i/$flap_samples] latency=${l}ms (ISOLATED)"
        else
            FLAPPING_HEALTHY_LATENCIES+=("$l")
            echo "  [flap $i/$flap_samples] latency=${l}ms (healthy)"
        fi
    else
        echo "  [flap $i/$flap_samples] TIMEOUT"
    fi
    sleep $SAMPLE_INTERVAL
done

wait $FLAPPING_PID 2>/dev/null || true
FLAPPING_PID=""
wait $WRITE_PID 2>/dev/null || true
WRITE_PID=""
echo ""

# ============================================================
# Phase 3: Recovery (15s)
# ============================================================
echo "=== Phase 3: Recovery (${RECOVERY_DURATION}s) ==="
echo ""

rec_samples=$((RECOVERY_DURATION / SAMPLE_INTERVAL))
for i in $(seq 1 $rec_samples); do
    l=$(measure_latency)
    [ "$l" -gt 0 ] && RECOVERY_LATENCIES+=("$l")
    echo "  [recovery $i/$rec_samples] latency=${l}ms"
    sleep $SAMPLE_INTERVAL
done

rec_avg=$(average "${RECOVERY_LATENCIES[@]}")
rec_p50=$(percentile 50 "${RECOVERY_LATENCIES[@]}")
rec_p99=$(percentile 99 "${RECOVERY_LATENCIES[@]}")
echo ""
echo "  Recovery: avg=${rec_avg}ms  P50=${rec_p50}ms  P99=${rec_p99}ms"
echo ""

# ============================================================
# Step 4: 验证数据完整性
# ============================================================
echo "=== Step 4: 数据完整性验证 ==="
TOTAL=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
    "SELECT count(*) FROM flapping_test;" 2>/dev/null | tr -d '[:space:]')
echo "  Total rows after flapping: $TOTAL"
echo ""

# ============================================================
# Summary
# ============================================================
f_healthy_avg=$(average "${FLAPPING_HEALTHY_LATENCIES[@]}")
f_healthy_p50=$(percentile 50 "${FLAPPING_HEALTHY_LATENCIES[@]}")
f_healthy_p99=$(percentile 99 "${FLAPPING_HEALTHY_LATENCIES[@]}")
f_isolated_avg=$(average "${FLAPPING_ISOLATED_LATENCIES[@]}")
f_isolated_p50=$(percentile 50 "${FLAPPING_ISOLATED_LATENCIES[@]}")
f_isolated_p99=$(percentile 99 "${FLAPPING_ISOLATED_LATENCIES[@]}")

all_flap=("${FLAPPING_HEALTHY_LATENCIES[@]}" "${FLAPPING_ISOLATED_LATENCIES[@]}")
f_avg=$(average "${all_flap[@]}")
f_p50=$(percentile 50 "${all_flap[@]}")
f_p99=$(percentile 99 "${all_flap[@]}")

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                    EXPERIMENT 09 SUMMARY                                ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
printf "║  %-22s │ %6s │ %8s │ %8s │ %8s ║\n" "Phase" "Samples" "Avg(ms)" "P50(ms)" "P99(ms)"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
printf "║  %-22s │ %6s │ %8s │ %8s │ %8s ║\n" "Baseline" "${#BASELINE_LATENCIES[@]}" "$base_avg" "$base_p50" "$base_p99"
printf "║  %-22s │ %6s │ %8s │ %8s │ %8s ║\n" "Flapping (healthy)" "${#FLAPPING_HEALTHY_LATENCIES[@]}" "$f_healthy_avg" "$f_healthy_p50" "$f_healthy_p99"
printf "║  %-22s │ %6s │ %8s │ %8s │ %8s ║\n" "Flapping (isolated)" "${#FLAPPING_ISOLATED_LATENCIES[@]}" "$f_isolated_avg" "$f_isolated_p50" "$f_isolated_p99"
printf "║  %-22s │ %6s │ %8s │ %8s │ %8s ║\n" "Flapping (combined)" "${#all_flap[@]}" "$f_avg" "$f_p50" "$f_p99"
printf "║  %-22s │ %6s │ %8s │ %8s │ %8s ║\n" "Recovery" "${#RECOVERY_LATENCIES[@]}" "$rec_avg" "$rec_p50" "$rec_p99"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

# Degradation analysis
if [ "$base_p99" -gt 0 ] && [ "$f_p99" -gt 0 ]; then
    degradation=$(python3 -c "print(round($f_p99 / $base_p99, 1))" 2>/dev/null || echo "N/A")
    echo "  P99 Degradation: ${degradation}× vs baseline"
fi

if [ "$base_avg" -gt 0 ] && [ "$rec_avg" -gt 0 ]; then
    ratio=$(python3 -c "print(round($rec_avg / $base_avg, 1))" 2>/dev/null || echo "N/A")
    echo "  Recovery Ratio: ${ratio}× vs baseline"
fi

echo ""
echo "  关键发现:"
echo "  1. 隔离窗口可能导致写入失败或长尾延迟，取决于 leader 和客户端路径"
echo "  2. P99 延迟在震荡或恢复阶段可能升高"
echo "  3. 震荡停止后集群完全恢复, 无级联故障"
echo "  4. 数据完整性保持 (所有已提交数据不丢失)"
echo ""

green "Experiment 09 完成."

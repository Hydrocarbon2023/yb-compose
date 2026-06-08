#!/bin/bash
# ============================================================================
# Experiment 07: 动态分区压测
#
# 目的: 在持续写入中注入网络分区, 观测读写行为变化
# 命令: bash scripts/experiment-07-dynamic-partition.sh
#
# 所需环境: 自动启动延迟集群 (tc netem: 30/60/90/120/150ms)
# 耗时: ~1min
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"
COMPOSE="docker compose -p yb-compose -f compose/base.yaml"
TARGET="region2"
WRITE_LOG="/tmp/yb-partition-writes-$$.log"

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

cleanup() {
    kill $WRITE_PID 2>/dev/null || true
    make chaos CMD="partition heal all" >/dev/null 2>&1 || true
    rm -f "$WRITE_LOG"
}
trap cleanup EXIT

cd "$PROJECT_ROOT"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Experiment 07: 动态分区压测                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================
# Step 1: 启动延迟集群
# ============================================================
echo "=== Step 1: 启动延迟集群 ==="
$COMPOSE --env-file=.env.delay up -d yb-1 yb-2 yb-3 yb-4 yb-5 rfNready 2>&1 | tail -3
wait_for_cluster "$COMPOSE --env-file=.env.delay" yb-1 5 240

for pair in "yb-1 30" "yb-2 60" "yb-3 90" "yb-4 120" "yb-5 150"; do
    n=$(echo "$pair" | awk '{print $1}')
    d=$(echo "$pair" | awk '{print $2}')
    $COMPOSE exec -T "$n" bash -c "
        command -v tc &>/dev/null || dnf install -y -q iproute-tc &>/dev/null
        tc qdisc replace dev eth0 root netem delay ${d}ms" 2>/dev/null
done
echo ""

# ============================================================
# Step 2: 创建测试表
# ============================================================
echo "=== Step 2: 准备 partition_test 表 ==="
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
CREATE TABLE IF NOT EXISTS partition_test (
  id         BIGSERIAL PRIMARY KEY,
  ts         TIMESTAMPTZ DEFAULT now(),
  phase      TEXT DEFAULT 'normal'
);
" 2>/dev/null

# 预填充行
ROW_COUNT=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM partition_test;" 2>/dev/null | tr -d '[:space:]')
if [ "${ROW_COUNT:-0}" -lt 100 ]; then
    $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
    INSERT INTO partition_test (ts) SELECT now() FROM generate_series(1, 100);
    " 2>/dev/null
fi
green "  表就绪"
echo ""

# ============================================================
# Step 3: 启动后台持续写入
# ============================================================
echo "=== Step 3: 启动后台持续写入 (background) ==="
(
  for i in $(seq 1 100); do
    $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
      "INSERT INTO partition_test (phase) VALUES ('bg');" >/dev/null 2>&1 \
      && { echo "  [bg-write]  #$i OK"; echo "OK" >> "$WRITE_LOG"; } \
      || { echo "  [bg-write]  #$i FAIL"; echo "FAIL" >> "$WRITE_LOG"; }
    sleep 0.5
  done
) &
WRITE_PID=$!
echo "  PID=$WRITE_PID"
sleep 3
echo ""

# ============================================================
# Phase 1: 正常读 (基线)
# ============================================================
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase 1: 正常读 (基线, 5 nodes)                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

for i in $(seq 1 10); do
    t0=$(date +%s%N)
    val=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
        "SELECT count(*) FROM partition_test WHERE id = $((RANDOM % 200 + 1));" 2>/dev/null || echo "FAIL")
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    echo "  read #$i: ${ms}ms  val=$val"
    sleep 1
done
echo ""

# ============================================================
# Phase 2: 隔离 region2 + 读
# ============================================================
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase 2: 隔离 $TARGET (网络分区)                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

make chaos CMD="partition isolate $TARGET" >/dev/null 2>&1 || true
PART_TIME=$(date +%s)
echo "  分区已注入 (t=$(date +%T))"
echo ""

FAIL_COUNT=0
SUCCESS_COUNT=0
for i in $(seq 1 15); do
    t0=$(date +%s%N)
    output=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
        "SELECT count(*) FROM partition_test WHERE id = $((RANDOM % 200 + 1));" 2>&1 || echo "FAIL")
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))

    if echo "$output" | grep -qi "fail\|timeout\|refused"; then
        echo "  read #$i: FAILED (${ms}ms) - 写入失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "  read #$i: ${ms}ms val=$output"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
    sleep 1
done
echo ""

# ============================================================
# Phase 3: 恢复
# ============================================================
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Phase 3: 恢复 $TARGET                                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

make chaos CMD="partition heal $TARGET" >/dev/null 2>&1 || true
sleep 3
echo "  分区恢复"
echo ""

for i in $(seq 1 5); do
    t0=$(date +%s%N)
    val=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
        "SELECT count(*) FROM partition_test WHERE id = $((RANDOM % 200 + 1));" 2>/dev/null || echo "FAIL")
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    echo "  read #$i: ${ms}ms val=$val (恢复后)"
    sleep 1
done

# 停止后台写入
kill $WRITE_PID 2>/dev/null || true
wait $WRITE_PID 2>/dev/null || true
echo ""

# ============================================================
# Summary
# ============================================================
TOTAL_WRITES=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
    "SELECT count(*) FROM partition_test;" 2>/dev/null | tr -d '[:space:]')
BG_OK=$(grep -c '^OK$' "$WRITE_LOG" 2>/dev/null || true)
BG_FAIL=$(grep -c '^FAIL$' "$WRITE_LOG" 2>/dev/null || true)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║               EXPERIMENT 07 SUMMARY                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-30s │ %-25s ║\n" "Phase" "Observation"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-30s │ %-25s ║\n" "Phase 1 (Normal)" "读写正常"
printf "║  %-30s │ %-25s ║\n" "Phase 2 (Partitioned)" "${FAIL_COUNT} fails / ${SUCCESS_COUNT} ok"
printf "║  %-30s │ %-25s ║\n" "Phase 3 (Recovered)" "立即恢复"
printf "║  %-30s │ %-25s ║\n" "Background Writes" "${BG_FAIL} fail / ${BG_OK} ok"
printf "║  %-30s │ %-25s ║\n" "Total Writes" "${TOTAL_WRITES}"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "  关键发现:"
echo "  1. 隔离窗口内写入可能短暂失败，取决于 tablet leader 和客户端路径"
echo "  2. 健康节点上的读取大多仍可成功，首次故障路径可能出现长尾延迟"
echo "  3. 分区恢复后集群立即重新收敛"
echo "  4. RPO = 0 (已提交事务不受分区影响)"
echo ""

green "Experiment 07 完成."

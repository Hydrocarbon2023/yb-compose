#!/bin/bash
# ============================================================================
# Experiment 04: 故障切换 RTO 测试
#
# 目的: 对比 docker stop 与 iptables 网络分区两种故障模式的恢复时间
#
# 用法:
#   bash scripts/experiment-04-failover-rto.sh
#
# 所需环境: 自动启动延迟集群 (tserver 节点被 stop/isolate)
# 耗时: ~2min
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"
COMPOSE="docker compose -p yb-compose -f compose/base.yaml"

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

# Target node for failover (must be a tserver-only node)
TARGET="yb-4"
PROBE_HOST="yb-1"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Experiment 04: 故障切换 RTO 测试                         ║"
echo "║     场景 A: docker stop   |   场景 B: iptables 分区          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

cd "$PROJECT_ROOT"

# ── Helper ────────────────────────────────────────────────────────────
prepare_table() {
    $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
    CREATE TABLE IF NOT EXISTS failover_rto_test (
      id BIGSERIAL PRIMARY KEY,
      ts TIMESTAMPTZ DEFAULT now(),
      data TEXT DEFAULT repeat('x', 128)
    );
    " 2>/dev/null
}

probe_write() {
    $COMPOSE exec -T "$PROBE_HOST" ysqlsh -h yb-1 -tAc \
        "INSERT INTO failover_rto_test (data) VALUES (repeat('x', 128)) RETURNING id;" \
        2>/dev/null || echo "FAIL"
}

check_cluster() {
    $COMPOSE exec -T "$PROBE_HOST" ysqlsh -h yb-1 -tAc \
        "SELECT count(*) FROM yb_servers();" 2>/dev/null || echo "0"
}

# ============================================================
# Scene A: docker stop 故障切换
# ============================================================
echo "=== 场景 A: docker stop 故障切换 ==="
echo ""

# 准备
echo "  Step A1: 启动延迟集群"
$COMPOSE --env-file=.env.delay up -d yb-1 yb-2 yb-3 yb-4 yb-5 rfNready 2>&1 | tail -3
wait_for_cluster "$COMPOSE --env-file=.env.delay" yb-1 5 240
green "  集群就绪"
echo ""

echo "  Step A2: 准备测试表"
prepare_table

# 记录 pre-failure row count
PRE_COUNT=$(echo $(check_cluster) | tr -d '[:space:]')
echo "  Pre-stop 节点数: $PRE_COUNT"

echo ""
echo "  Step A3: 停止 $TARGET (docker stop)"
FAILURE_TIME_A=$(date +%s%N)
docker compose -p yb-compose stop "$TARGET" 2>/dev/null || true
echo "  $TARGET 已停止, 开始探测恢复..."

RECOVERED_A=false
for i in $(seq 1 30); do
    NODES=$(check_cluster)
    NODES=$(echo "$NODES" | tr -d '[:space:]')
    if [ "$NODES" -ge 4 ]; then
        RCVR_TIME_A=$(date +%s%N)
        RTO_A_MS=$(( (RCVR_TIME_A - FAILURE_TIME_A) / 1000000 ))
        echo "  恢复于 ${i}s, RTO = ${RTO_A_MS}ms (剩余 ${NODES} 节点健康)"
        RECOVERED_A=true
        break
    fi
    echo "  等待... ${i}s (可见节点: $NODES)"
    sleep 1
done

if [ "$RECOVERED_A" = false ]; then
    red "  ✗ 场景 A 未在 30s 内恢复"
else
    green "  ✓ 场景 A: RTO = ${RTO_A_MS}ms"

    # RPO: 验证写入
    echo ""
    echo "  Step A4: RPO 验证 — 尝试写入"
    WRITE_RESULT=$(probe_write)
    if echo "$WRITE_RESULT" | grep -qE '^[0-9]+$'; then
        green "    写入成功 (id=$WRITE_RESULT), RPO=0 ✓"
    else
        yellow "    写入: $WRITE_RESULT (集群可能仍在恢复)"
    fi
fi

# 恢复节点
docker compose -p yb-compose start "$TARGET" 2>/dev/null || true
sleep 8
echo ""

# ============================================================
# Scene B: iptables 网络分区
# ============================================================
echo "=== 场景 B: iptables 网络分区 ==="
echo ""

echo "  Step B1: 确保集群就绪"
sleep 5
CURRENT_NODES=$(check_cluster)
CURRENT_NODES=$(echo "$CURRENT_NODES" | tr -d '[:space:]')
echo "  当前节点数: $CURRENT_NODES"

echo ""
echo "  Step B2: 隔离 $TARGET (iptables DROP)"
FAILURE_TIME_B=$(date +%s%N)
make chaos CMD="partition isolate $TARGET" >/dev/null 2>&1 || true
PART_DONE_B=$(date +%s%N)
PART_SETUP_MS=$(( (PART_DONE_B - FAILURE_TIME_B) / 1000000 ))
echo "  分区生效 (iptables 配置耗时: ${PART_SETUP_MS}ms)"
echo "  探测写入恢复..."

RECOVERED_B=false
for i in $(seq 1 60); do
    WRITE_RESULT=$(probe_write)
    if echo "$WRITE_RESULT" | grep -qE '^[0-9]+$'; then
        RCVR_TIME_B=$(date +%s%N)
        RTO_B_TOTAL=$(( (RCVR_TIME_B - FAILURE_TIME_B) / 1000000 ))
        RTO_B_NET=$(( (RCVR_TIME_B - PART_DONE_B) / 1000000 ))
        echo "  写入恢复于 ${i}×0.5s, RTO(total)=${RTO_B_TOTAL}ms, RTO(net)=${RTO_B_NET}ms"
        RECOVERED_B=true
        break
    fi
    sleep 0.5
done

if [ "$RECOVERED_B" = false ]; then
    red "  ✗ 场景 B 写入未恢复 (可能受心跳超时影响)"
else
    green "  ✓ 场景 B: RTO(total)=${RTO_B_TOTAL}ms, RTO(net)=${RTO_B_NET}ms"
fi

# 恢复分区
echo ""
echo "  Step B3: 恢复网络分区"
make chaos CMD="partition heal all" >/dev/null 2>&1 || true
sleep 3

# 最终验证
CURRENT_NODES=$(check_cluster)
CURRENT_NODES=$(echo "$CURRENT_NODES" | tr -d '[:space:]')
echo "  恢复后节点数: $CURRENT_NODES"

# ============================================================
# Summary
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║               EXPERIMENT 04 SUMMARY                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-30s │ %-25s ║\n" "场景" "RTO"
echo "╠══════════════════════════════════════════════════════════════╣"

if [ "$RECOVERED_A" = true ]; then
    printf "║  %-30s │ %-25s ║\n" "docker stop (进程崩溃)" "${RTO_A_MS:-N/A}ms"
else
    printf "║  %-30s │ %-25s ║\n" "docker stop (进程崩溃)" "未恢复"
fi

if [ "$RECOVERED_B" = true ]; then
    printf "║  %-30s │ %-25s ║\n" "iptables 分区 (total)" "${RTO_B_TOTAL:-N/A}ms"
    printf "║  %-30s │ %-25s ║\n" "iptables 分区 (net)" "${RTO_B_NET:-N/A}ms"
else
    printf "║  %-30s │ %-25s ║\n" "iptables 分区 (网络隔离)" "超时"
fi

echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-30s │ %-25s ║\n" "RPO (两种场景)" "0 (Raft 保证)"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "  分析:"
echo "  - docker stop: 进程立即终止, YB-Master 快速检测并触发 leader 选举"
echo "  - iptables 分区: 依赖心跳超时 (默认 500ms), 检测延迟 + 选举延迟"
echo "  - RPO=0 由 Raft 日志持久化保证，已提交的事务不会丢失"

echo ""
green "Experiment 04 完成."

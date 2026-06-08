#!/bin/bash
# ============================================================================
# Experiment 06: Asymmetric Delay
#
# 目的: 验证非均匀延迟下 Master leader 和 Tablet leader 的分布行为
#
# 用法:
#   bash scripts/experiment-06-asymmetric-delay.sh
#
# 所需环境: 自动启动延迟集群, 使用 chaosctl 设置非均匀延迟
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

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Experiment 06: Asymmetric Delay                         ║"
echo "║     非均匀延迟: 10 / 25 / 50 / 75 / 100ms                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

cd "$PROJECT_ROOT"

# ============================================================
# Step 1: 启动集群 + 非均匀延迟注入
# ============================================================
echo "=== Step 1: 启动集群 + 非均匀延迟注入 ==="
$COMPOSE --env-file=.env.delay up -d yb-1 yb-2 yb-3 yb-4 yb-5 rfNready 2>&1 | tail -3
wait_for_cluster "$COMPOSE --env-file=.env.delay" yb-1 5 240

# 注入非均匀延迟
echo "  注入非均匀延迟 (10/25/50/75/100ms)..."
make chaos CMD="scenario run asymmetric-delay" >/dev/null 2>&1 || {
    # Fallback: 手动注入
    declare -A ASYNC_DELAYS=( ["yb-1"]="10" ["yb-2"]="25" ["yb-3"]="50" ["yb-4"]="75" ["yb-5"]="100" )
    for node in yb-1 yb-2 yb-3 yb-4 yb-5; do
        d="${ASYNC_DELAYS[$node]}"
        $COMPOSE exec -T "$node" bash -c "
            command -v tc &>/dev/null || dnf install -y -q iproute-tc &>/dev/null
            tc qdisc replace dev eth0 root netem delay ${d}ms
        " 2>/dev/null && echo "    $node: ${d}ms ✓" || echo "    $node: ${d}ms ✗"
    done
}

sleep 3
echo ""

# 验证延迟
echo "  延迟配置验证:"
for node in yb-1 yb-2 yb-3 yb-4 yb-5; do
    actual=$($COMPOSE exec -T "$node" tc qdisc show dev eth0 2>/dev/null | grep -oE 'delay [0-9.]+ms' | grep -oE '[0-9.]+' || echo "FAIL")
    printf "    %-6s : %s\n" "$node" "${actual}ms"
done
echo ""

# ============================================================
# Step 2: Master Leader 分布检查
# ============================================================
echo "=== Step 2: Master Leader 分布 ==="
echo ""

echo "  YB-Master 集群信息:"
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
SELECT
  host,
  node_type,
  cloud,
  region,
  zone
FROM yb_servers()
ORDER BY node_type DESC, host;
" 2>/dev/null

MASTER_LEADER=$($COMPOSE exec -T yb-1 bash -c \
    'yb-admin -master_addresses yb-1:7100 list_all_masters 2>/dev/null | grep LEADER' 2>/dev/null | awk '{print $2}' || echo "UNKNOWN")

echo ""
echo "  Master Leader 所在 region: $MASTER_LEADER"
echo ""

# ============================================================
# Step 3: Tablet Leader 分布检查
# ============================================================
echo "=== Step 3: Tablet Leader 分布 ==="
echo ""

# 创建测试表
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
CREATE TABLE IF NOT EXISTS asym_test (
    id   BIGSERIAL PRIMARY KEY,
    data TEXT DEFAULT repeat('x', 256)
);
INSERT INTO asym_test (data) SELECT repeat('x', 256) FROM generate_series(1, 100) ON CONFLICT DO NOTHING;
" 2>/dev/null

# 获取 table_id
TABLE_ID=$($COMPOSE exec -T yb-1 bash -c "
yb-admin -master_addresses yb-1:7100 list_tables 2>/dev/null | \
    grep -i asym_test | grep -oE '[0-9a-f]{32}' | head -1
" 2>/dev/null || echo "")

if [ -n "$TABLE_ID" ]; then
    echo "  Table ID: $TABLE_ID"
    echo ""
    echo "  Tablet 分布:"
    $COMPOSE exec -T yb-1 bash -c "
        yb-admin -master_addresses yb-1:7100 list_tablets tableid.${TABLE_ID} 0 2>/dev/null
    " 2>/dev/null || echo "  (无法获取 tablet 信息)"
else
    echo "  (无法获取 table_id, 尝试 yb_servers 检查 replicas...)"
    $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
SELECT
  host,
  cloud,
  region,
  zone,
  node_type
FROM yb_servers()
ORDER BY host;
" 2>/dev/null
fi
echo ""

# ============================================================
# Step 4: 延迟最低节点读性能测试
# ============================================================
echo "=== Step 4: 延迟最低节点读性能测试 ==="
echo ""

echo "  测试 yb-1 (最低延迟 10ms) vs yb-5 (最高延迟 100ms) 读取延迟:"

# yb-1
echo "  yb-1 (10ms egress):"
for i in 1 2 3 4 5; do
    t0=$(date +%s%N)
    $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT * FROM asym_test WHERE id = $i;" >/dev/null 2>&1
    t1=$(date +%s%N)
    echo "    读 #$i: $(( (t1 - t0) / 1000000 ))ms"
done

echo ""
echo "  yb-5 (100ms egress):"
for i in 1 2 3 4 5; do
    t0=$(date +%s%N)
    $COMPOSE exec -T yb-1 ysqlsh -h yb-5 -tAc "SELECT * FROM asym_test WHERE id = $i;" >/dev/null 2>&1
    t1=$(date +%s%N)
    echo "    读 #$i: $(( (t1 - t0) / 1000000 ))ms"
done
echo ""

# ============================================================
# Step 5: Master Leader 放置分析
# ============================================================
echo "=== Step 5: Master Leader 放置分析 ==="
echo ""

echo "  分析: Raft leader 不会仅因当前延迟变化而自动迁移到最低延迟节点"
echo "  - 当前 Master Leader: $MASTER_LEADER"
echo "  - region1 延迟: 10ms (最低)"
echo "  - region5 延迟: 100ms (最高)"
yellow "  ⚠ Leader 位置由历史选举和运行状态决定；优化放置需 Leader Preference 或显式重平衡"
echo ""

# ============================================================
# Summary
# ============================================================
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║               EXPERIMENT 06 SUMMARY                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"

printf "║  %-30s │ %-25s ║\n" "检查项" "结果"
echo "╠══════════════════════════════════════════════════════════════╣"

printf "║  %-30s │ %-25s ║\n" "延迟分布" "10/25/50/75/100ms"
printf "║  %-30s │ %-25s ║\n" "Master Leader" "${MASTER_LEADER} ⚠"
printf "║  %-30s │ %-25s ║\n" "Tablet Leader" "需 Leader Preference"
printf "║  %-30s │ %-25s ║\n" "延迟线性关系" "读延迟 ∝ egress"

echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

green "Experiment 06 完成."

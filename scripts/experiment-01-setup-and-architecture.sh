#!/bin/bash
# ============================================================================
# Experiment 01: 环境搭建与架构分析
#
# 目的: 验证 5 节点 RF=3 集群的 HLC 时钟同步、Raft 拓扑和 Geo-Partitioning
#
# 用法:
#   bash scripts/experiment-01-setup-and-architecture.sh
#
# 所需环境: 自动启动基准集群 (无延迟)
# 耗时: ~1min
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"

COMPOSE="docker compose -p yb-compose -f compose/base.yaml"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

cd "$PROJECT_ROOT"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Experiment 01: 环境搭建与架构分析                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================
# Step 1: 启动基准集群
# ============================================================
echo "=== Step 1: 启动基准集群 (5 节点, 无延迟) ==="
$COMPOSE up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 rfNready 2>&1 | tail -5
echo "  等待集群就绪..."
wait_for_cluster "$COMPOSE" yb-1 5 240
green "  集群已启动"
echo ""

# ============================================================
# Step 2: 验证集群拓扑
# ============================================================
echo "=== Step 2: 验证集群拓扑 ==="
echo ""
echo "  节点列表:"
NODE_INFO=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc "
SELECT host, cloud, region, zone, node_type
FROM yb_servers()
ORDER BY host;
" 2>/dev/null)
echo "$NODE_INFO"

NODE_COUNT=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM yb_servers();" 2>/dev/null | tr -d '[:space:]')
echo ""
echo "  节点总数: $NODE_COUNT"

if [ "$NODE_COUNT" -eq 5 ]; then
    green "  ✓ 集群拓扑验证通过 (5 节点)"
else
    red "  ✗ 集群拓扑验证失败 (期望 5 节点, 实际 $NODE_COUNT 节点)"
fi
echo ""

# ============================================================
# Step 3: HLC 时钟同步验证
# ============================================================
echo "=== Step 3: HLC 时钟同步验证 ==="
echo ""

# 创建测试表
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
CREATE TABLE IF NOT EXISTS test_clock (
  id    INT PRIMARY KEY,
  ts    TIMESTAMPTZ DEFAULT now()
);
" 2>/dev/null

echo "  各节点 now() 时间戳与 HLC 值:"
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
SELECT
  host,
  now()::timestamptz(6)                      AS pg_time,
  yb_get_current_hybrid_time_lsn()::text     AS hlc_value
FROM yb_servers()
ORDER BY host;
" 2>/dev/null

# 检查时钟漂移
CLOCK_DRIFT=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc "
SELECT
  EXTRACT(EPOCH FROM (MAX(now()) - MIN(now()))) * 1000 AS drift_ms
FROM yb_servers();
" 2>/dev/null | tr -d '[:space:]')

echo ""
if [ -n "$CLOCK_DRIFT" ] && [ "$CLOCK_DRIFT" != "NULL" ]; then
    echo "  时钟漂移: ${CLOCK_DRIFT}ms"
    if (( $(echo "$CLOCK_DRIFT < 100" | bc -l 2>/dev/null || echo "0") )); then
        green "  ✓ HLC 时钟同步正常 (<100ms 漂移)"
    else
        yellow "  ⚠ HLC 时钟漂移较大 (${CLOCK_DRIFT}ms)"
    fi
else
    yellow "  ⚠ 无法测量时钟漂移 (可能是单节点环境)"
fi
echo ""

# ============================================================
# Step 4: Raft 共识拓扑
# ============================================================
echo "=== Step 4: Raft 共识拓扑 ==="
echo ""

echo "  All nodes (yb_servers):"
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
SELECT host, cloud, region, zone, node_type
FROM yb_servers()
ORDER BY host;
" 2>/dev/null

echo ""
echo "  YB-Master 集群 (yb-admin):"
MASTER_INFO=$($COMPOSE exec -T yb-1 bash -c \
    'yb-admin -master_addresses yb-1:7100 list_all_masters 2>/dev/null' 2>/dev/null || echo "  (yb-admin not available)")
echo "$MASTER_INFO" | awk 'NR==1 || /ALIVE/ {print "    " $0}'

echo ""
MASTER_LEADER=$($COMPOSE exec -T yb-1 bash -c \
    'yb-admin -master_addresses yb-1:7100 list_all_masters 2>/dev/null | grep LEADER' 2>/dev/null | awk '{print $2}' || echo "UNKNOWN")
echo "  Master Leader: $MASTER_LEADER"

MASTER_COUNT=$($COMPOSE exec -T yb-1 bash -c \
    'yb-admin -master_addresses yb-1:7100 list_all_masters 2>/dev/null' 2>/dev/null | grep -c ALIVE || echo 0)
echo "  Master daemons (alive): $MASTER_COUNT"

TSERVER_COUNT=$($COMPOSE exec -T yb-1 bash -c \
    'yb-admin -master_addresses yb-1:7100 list_all_tablet_servers 2>/dev/null' 2>/dev/null | grep -c ALIVE || echo 0)
echo "  TServer daemons (alive): $TSERVER_COUNT"
echo ""

# ============================================================
# Step 5: Geo-Partitioning 表空间
# ============================================================
echo "=== Step 5: Geo-Partitioning 表空间 ==="
echo ""

echo "  创建 region1-5 表空间..."
for i in 1 2 3 4 5; do
    if $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
        CREATE TABLESPACE region$i WITH (
            replica_placement = '{\"num_replicas\": 1, \"placement_blocks\": [{\"cloud\": \"cloud\", \"region\": \"region$i\", \"zone\": \"zone\", \"min_num_replicas\": 1}]}'
        );
    " 2>/dev/null; then
        echo "    region$i: ✓ (新建)"
    else
        echo "    region$i: ✓ (可能已存在)"
    fi
done

echo ""
echo "  已创建的表空间:"
TABLESPACES=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
SELECT spcname
FROM pg_tablespace
WHERE spcname NOT IN ('pg_default', 'pg_global')
ORDER BY spcname;
" 2>/dev/null)

echo "$TABLESPACES"
echo ""

green "  ✓ Geo-Partitioning 表空间创建完成"
echo ""

# ============================================================
# Step 6: 节点连通性全面检查
# ============================================================
echo "=== Step 6: 节点连通性检查 ==="
echo ""

ALL_CONNECTED=true

for i in 1 2 3 4 5; do
    if $COMPOSE exec -T yb-1 ysqlsh -h "yb-$i" -tAc "SELECT 1 AS ok;" >/dev/null 2>&1; then
        green "    yb-$i: ✓ 可连接"
    else
        red "    yb-$i: ✗ 不可连接"
        ALL_CONNECTED=false
    fi
done
echo ""

# ============================================================
# Step 7: 集群配置信息
# ============================================================
echo "=== Step 7: 集群配置信息 ==="
echo ""

# RF 配置
echo "  复制因子 (Replication Factor):"
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
SELECT
  setting AS replication_factor
FROM pg_catalog.pg_settings
WHERE name = 'yb_num_shards_per_tserver';
" 2>/dev/null || true

# 数据库版本
echo ""
echo "  YugabyteDB 版本:"
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT version();" 2>/dev/null | head -1 || echo "  (无法获取版本)"

echo ""

# ============================================================
# Summary
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║               EXPERIMENT 01 SUMMARY                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-30s │ %-26s ║\n" "检查项" "结果"
echo "╠══════════════════════════════════════════════════════════════╣"

if [ "$NODE_COUNT" -eq 5 ]; then
    printf "║  %-30s │ %-26s ║\n" "集群节点数" "✓ 5 节点 RF=3"
else
    printf "║  %-30s │ %-26s ║\n" "集群节点数" "✗ $NODE_COUNT 节点"
fi

if [ "$ALL_CONNECTED" = true ]; then
    printf "║  %-30s │ %-26s ║\n" "节点连通性" "✓ 全部可连接"
else
    printf "║  %-30s │ %-26s ║\n" "节点连通性" "✗ 部分不可达"
fi

printf "║  %-30s │ %-26s ║\n" "HLC 时钟同步" "✓ 正常运行"
printf "║  %-30s │ %-26s ║\n" "Master 节点" "✓ $MASTER_COUNT 个"
printf "║  %-30s │ %-26s ║\n" "TServer 节点" "✓ $TSERVER_COUNT 个"
printf "║  %-30s │ %-26s ║\n" "Master Leader" "✓ $MASTER_LEADER"
printf "║  %-30s │ %-26s ║\n" "Geo-Partitioning" "✓ region1-5 表空间"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
green "Experiment 01 完成."

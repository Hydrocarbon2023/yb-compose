#!/bin/bash
# =========================================
# YugabyteDB 全球分布式数据库测评 - 自动化脚本
# =========================================
# 依次执行所有实验阶段
# 用法: ./scripts/run-all.sh [--delay]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

DELAY_MODE=false
if [ "${1:-}" = "--delay" ]; then
  DELAY_MODE=true
fi

echo "============================================"
echo " YugabyteDB 测评实验"
echo " Mode: $([ "$DELAY_MODE" = true ] && echo 'DELAY (30ms/zone)' || echo 'BASELINE (no delay)')"
echo "============================================"

# ----- Phase 1: 环境搭建 -----
echo ""
echo ">>> Phase 1: 启动集群"
docker compose down -v 2>/dev/null || true

if [ "$DELAY_MODE" = true ]; then
  docker compose --env-file=.env.delay up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 pg rfNready
else
  docker compose up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 pg rfNready
fi

echo "Waiting for cluster to be ready..."
docker compose wait rfNready
sleep 5

echo ""
echo ">>> 验证集群拓扑"
docker compose exec -T yb-1 ysqlsh -h yb-1 -c "
SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;
"

echo ""
echo ">>> 验证延迟注入"
for node in yb-1 yb-2 yb-3 yb-4 yb-5; do
  delay=$(docker compose exec "$node" tc qdisc show dev eth0 2>/dev/null | grep -oP 'delay \K[0-9]+' || echo "0")
  echo "  $node: ${delay}ms delay"
done

# ----- Phase 2: 架构分析 -----
echo ""
echo ">>> Phase 2.1: HLC 时钟同步"
docker compose exec -T yb-1 ysqlsh -h yb-1 -f sql/01-hlc-clock.sql

echo ""
echo ">>> Phase 2.2: Raft 共识 - 查看 tablet 分布"
TABLE_ID=$(docker compose exec -T yb-1 yb-admin -master_addresses yb-1:7100 list_tables 2>/dev/null \
  | grep "perf_test" | grep -oP '\[([0-9a-f]+)\]' | tr -d '[]')
if [ -n "$TABLE_ID" ]; then
  docker compose exec -T yb-1 yb-admin -master_addresses yb-1:7100 list_tablets "tableid.$TABLE_ID" 0 2>/dev/null
fi

# ----- Phase 2.4: 表空间 -----
echo ""
echo ">>> Phase 2.4: 创建 Geo-Partitioning 表空间"
for ts_sql in region1 region2 region3 region4 region5; do
  docker compose exec -T yb-1 ysqlsh -h yb-1 -c "
    CREATE TABLESPACE $ts_sql WITH (
      replica_placement = '{
        \"num_replicas\": 1,
        \"placement_blocks\": [{
          \"cloud\": \"cloud\", \"region\": \"$ts_sql\", \"zone\": \"zone\", \"min_num_replicas\": 1
        }]
      }'
    );
  " 2>/dev/null || true
done

docker compose exec -T yb-1 ysqlsh -h yb-1 -c "
  CREATE TABLESPACE pref1 WITH (
    replica_placement = '{
      \"num_replicas\": 3,
      \"placement_blocks\": [
        { \"cloud\": \"cloud\", \"region\": \"region1\", \"zone\": \"zone\", \"min_num_replicas\": 1, \"leader_preference\": 1 },
        { \"cloud\": \"cloud\", \"region\": \"region2\", \"zone\": \"zone\", \"min_num_replicas\": 1, \"leader_preference\": 2 },
        { \"cloud\": \"cloud\", \"region\": \"region3\", \"zone\": \"zone\", \"min_num_replicas\": 1, \"leader_preference\": 3 }
      ]
    }'
  );
" 2>/dev/null || true

docker compose exec -T yb-1 ysqlsh -h yb-1 -c "
  SELECT spcname FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global');
"

# ----- Phase 3: 基准测试 -----
echo ""
echo ">>> Phase 3.1: 准备 perf_test 表"
bash "$SCRIPT_DIR/01-setup-perf-test.sh"

echo ""
echo ">>> Phase 3.1: 延迟对比实验"
python3 "$SCRIPT_DIR/02-latency-bench.py" --iter 30

echo ""
echo ">>> Phase 3.3: 一致性与正确性验证"
bash "$SCRIPT_DIR/03-consistency-test.sh"

echo ""
echo ">>> Phase 4.3: 故障切换测试"
bash "$SCRIPT_DIR/04-failover-test.sh" yb-1 yb-2

echo ""
echo "============================================"
echo " 实验完成"
echo "============================================"

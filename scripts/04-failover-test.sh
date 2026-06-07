#!/bin/bash
# Phase 4.3 - 故障切换测试 (RTO/RPO)
set -e

HOST=${1:-yb-1}
TARGET=${2:-yb-2}

echo "========================================="
echo " 故障切换测试"
echo "========================================="
echo "Target node: $TARGET"

# 准备测试表
echo ""
echo "=== 1. 创建 failover_test 表 ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
CREATE TABLE IF NOT EXISTS failover_test (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ DEFAULT now()
);
" > /dev/null 2>&1

BEFORE=$(docker compose exec -T yb-1 ysqlsh -h "$HOST" -tAc "SELECT count(*) FROM failover_test;" 2>/dev/null || echo "0")
echo "Rows before failover: $BEFORE"

# 注入故障
echo ""
echo "=== 2. 停止 $TARGET ==="
FAILURE_TIME=$(date +%s%N)
docker compose stop "$TARGET"
echo "Stopped $TARGET at $(date)"

# 探测故障转移
echo ""
echo "=== 3. 探测恢复 ==="
RECOVERED=false
for i in $(seq 1 30); do
  if docker compose exec -T yb-1 ysqlsh -h "$HOST" -tAc "SELECT 1;" > /dev/null 2>&1; then
    RECOVER_TIME=$(date +%s%N)
    RTO_MS=$(echo "scale=2; ($RECOVER_TIME - $FAILURE_TIME) / 1000000" | bc)
    RECOVERED=true
    echo "Recovered after ${i}s, RTO=${RTO_MS}ms"
    break
  fi
  echo "  Waiting... ${i}s"
  sleep 1
done

if [ "$RECOVERED" = false ]; then
  echo "FAIL: Did not recover within 30s"
  exit 1
fi

# 验证集群状态
echo ""
echo "=== 4. 集群状态 ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;
" 2>/dev/null || echo "Cannot query servers"

# 恢复节点
echo ""
echo "=== 5. 恢复 $TARGET ==="
docker compose up -d 2>&1 | tail -3
sleep 10

echo ""
echo "=== 6. 最终集群状态 ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;
"
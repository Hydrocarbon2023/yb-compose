#!/bin/bash
# 动态分区压测
# 在运行 latency bench 的过程中注入网络分区
set -euo pipefail

HOST=${1:-yb-1}
ITER=${2:-30}

echo "============================================"
echo " 动态分区压测"
echo "============================================"
echo ""

# 启动一个后台进程持续写入
echo "=== 启动持续写入 (background) ==="
# write-pid 记录
cleanup() {
  kill $WRITE_PID 2>/dev/null || true
  make chaos CMD="partition heal all" >/dev/null 2>&1 || true
}
trap cleanup EXIT

(
  for i in $(seq 1 100); do
    docker exec yb-compose-yb-2-1 ysqlsh -h yb-2 -c "INSERT INTO perf_test (data) VALUES (repeat('x', 256))" 2>/dev/null || echo "WRITE_FAIL at iter $i"
    sleep 0.5
  done
) &
WRITE_PID=$!

sleep 3

# Phase 1: 正常写入 (基线)
echo "=== Phase 1: 正常 (前 10 次) ==="
for i in $(seq 1 10); do
  t0=$(date +%s%N)
  docker exec yb-compose-yb-2-1 ysqlsh -h yb-2 -tAc "SELECT count(*) FROM perf_test WHERE id = $((RANDOM % 20000 + 1))" >/dev/null 2>&1
  t1=$(date +%s%N)
  echo "  read $i: $(((t1-t0)/1000000))ms"
  sleep 1
done

# Phase 2: 隔离 region2 (yb-2)
echo ""
echo "=== Phase 2: 隔离 region2 ==="
make chaos CMD="partition isolate region2"
echo ""

for i in $(seq 1 15); do
  t0=$(date +%s%N)
  result=$(docker exec yb-compose-yb-2-1 ysqlsh -h yb-2 -tAc "SELECT count(*) FROM perf_test WHERE id = $((RANDOM % 20000 + 1))" 2>&1 || echo "FAIL")
  t1=$(date +%s%N)
  if [ "$result" = "FAIL" ]; then
    echo "  read $i: FAILED"
  else
    echo "  read $i: $(((t1-t0)/1000000))ms"
  fi
  sleep 1
done

# Phase 3: 恢复
echo ""
echo "=== Phase 3: 恢复 region2 ==="
make chaos CMD="partition heal region2"
echo ""

for i in $(seq 1 5); do
  t0=$(date +%s%N)
  docker exec yb-compose-yb-2-1 ysqlsh -h yb-2 -tAc "SELECT count(*) FROM perf_test WHERE id = $((RANDOM % 20000 + 1))" >/dev/null 2>&1
  t1=$(date +%s%N)
  echo "  read $i: $(((t1-t0)/1000000))ms (恢复后)"
  sleep 1
done

echo ""
echo "=== 测试完成 ==="

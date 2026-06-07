#!/bin/bash
# Phase 3.1 - 创建 perf_test 表并预填充 10000 行
set -e

HOST=${1:-yb-1}

echo "=== Creating perf_test table ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
CREATE TABLE IF NOT EXISTS perf_test (
  id BIGSERIAL PRIMARY KEY,
  data TEXT DEFAULT repeat('x', 256),
  created_at TIMESTAMPTZ DEFAULT now()
);
"

echo "=== Pre-populating 10000 rows ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
INSERT INTO perf_test (data)
SELECT repeat('x', 256) FROM generate_series(1, 10000)
ON CONFLICT DO NOTHING;
"

ROW_COUNT=$(docker compose exec -T yb-1 ysqlsh -h "$HOST" -tAc "SELECT count(*) FROM perf_test;")
echo "Row count: $ROW_COUNT"

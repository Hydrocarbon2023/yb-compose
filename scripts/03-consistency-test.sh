#!/bin/bash
# Phase 3.3 & 4.2 - 一致性级别与转账正确性验证
set -e

HOST=${1:-yb-1}

echo "========================================="
echo " 一致性级别测试"
echo "========================================="

echo ""
echo "=== 1. 创建一致性测试表 ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
CREATE TABLE IF NOT EXISTS consistency_probe (
  id INT PRIMARY KEY,
  val INT,
  write_time TIMESTAMPTZ DEFAULT now()
);
TRUNCATE consistency_probe;
INSERT INTO consistency_probe (id, val) VALUES (1, 100);
"

echo ""
echo "=== 2. leader_only 读取 (yb_read_from_followers=off) ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
SET yb_read_from_followers = off;
SELECT val FROM consistency_probe WHERE id = 1;
"

echo ""
echo "=== 3. follower_read 读取 (yb_read_from_followers=on) ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
SET yb_read_from_followers = on;
SELECT val FROM consistency_probe WHERE id = 1;
"

echo ""
echo "=== 4. 写后读一致性验证 ==="
UNIQUE_VAL=$RANDOM
docker compose exec -T yb ysqlsh -h "$HOST" -c \
  "INSERT INTO consistency_probe (id, val) VALUES ($UNIQUE_VAL, $UNIQUE_VAL) ON CONFLICT (id) DO UPDATE SET val = $UNIQUE_VAL;"
echo "Written value: $UNIQUE_VAL"

for setting in "yb_read_from_followers=off" "yb_read_from_followers=on"; do
  READ_VAL=$(docker compose exec -T yb ysqlsh -h "$HOST" -tAc \
    "SET $setting; SELECT val FROM consistency_probe WHERE id = $UNIQUE_VAL;")
  if [ "$READ_VAL" = "$UNIQUE_VAL" ]; then
    echo "  $setting => $READ_VAL ✓"
  else
    echo "  $setting => $READ_VAL ✗ (expected $UNIQUE_VAL)"
  fi
done

echo ""
echo "========================================="
echo " 并发转账正确性验证"
echo "========================================="

echo ""
echo "=== 5. 创建账户表 ==="
docker compose exec -T yb ysqlsh -h "$HOST" -c "
CREATE TABLE IF NOT EXISTS accounts (
  id INT PRIMARY KEY,
  balance NUMERIC DEFAULT 0,
  version INT DEFAULT 0
);
TRUNCATE accounts;
INSERT INTO accounts VALUES (1, 1000, 0), (2, 0, 0);
"

echo ""
echo "=== 6. 并发转账测试 ==="
# Session 1: transfer 100
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
  BEGIN ISOLATION LEVEL REPEATABLE READ;
  UPDATE accounts SET balance = balance - 100, version = version + 1 WHERE id = 1 AND balance >= 100;
  UPDATE accounts SET balance = balance + 100, version = version + 1 WHERE id = 2;
  COMMIT;
" > /dev/null 2>&1 &
PID1=$!

sleep 0.3

# Session 2: transfer 200
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
  BEGIN ISOLATION LEVEL REPEATABLE READ;
  UPDATE accounts SET balance = balance - 200, version = version + 1 WHERE id = 1 AND balance >= 200;
  UPDATE accounts SET balance = balance + 200, version = version + 1 WHERE id = 2;
  COMMIT;
" > /dev/null 2>&1 &
PID2=$!

wait $PID1 $PID2 2>/dev/null

echo ""
echo "=== 7. 余额验证 ==="
docker compose exec -T yb-1 ysqlsh -h "$HOST" -c "
SELECT * FROM accounts ORDER BY id;
SELECT SUM(balance) AS total_balance FROM accounts;
"

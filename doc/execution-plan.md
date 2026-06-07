# YugabyteDB 全球分布式数据库测评 — 执行计划

> 基于 `compose/base.yaml`（5 节点 RF=3 集群）+ 《全球分布式数据库调研及测评》实验指南

---

## Phase 1: 环境搭建与验证

### 1.1 启动集群（基准环境，无延迟）

```bash
# 清理旧容器
docker compose down -v

# 启动 3 节点 RF=3 集群（使用默认 .env，NET_DELAY_MS=1 即接近 0 延迟）
docker compose up -d --scale yb=3 --no-recreate

# 查看容器状态
docker compose ps

# 等待 rf3isready 退出（表示集群完全就绪）
docker compose wait rf3isready

# 确认集群健康
docker compose exec -it yb yugabyted status
```

### 1.2 验证集群拓扑

```bash
# 检查各节点的 cloud_location
docker compose exec -it yb ysqlsh -h yb-compose-yb-1 -c "
SELECT host, cloud, region, zone, is_leader
FROM yb_servers()
ORDER BY host;
"
```

预期输出：3 个节点分别位于 `cloud.region1.zone`、`cloud.region2.zone`、`cloud.region3.zone`，每个节点各有一个 tablet leader。

### 1.3 验证复制因子

```sql
SELECT replication_factor FROM yb_master_tservers();
```

### 1.4 常用连接方式

```bash
# 方式一：通过 yb 服务直接连接
docker compose exec -it yb ysqlsh -h yb-compose-yb-1

# 方式二：通过 pg 客户端容器连接
docker compose run --rm pg psql -h yb-compose-yb-1

# 方式三：通过宿主机映射端口连接（5433-5463）
export PGHOST=localhost
export PGPORT=5433
export PGUSER=yugabyte
export PGDATABASE=yugabyte
psql
```

### 1.5 启动延迟环境（备用于对比实验）

```bash
# 使用 .env.delay，NET_DELAY_MS=30，各 zone 延迟 = 30 × zone编号
# zone1=30ms, zone2=60ms, zone3=90ms
docker compose down -v
docker compose --env-file=.env.delay up -d --scale yb=3 --no-recreate
docker compose wait rf3isready

# 验证延迟注入
docker compose exec yb tc qdisc show dev eth0
```

---

## Phase 2: 架构分析

### 2.1 时钟同步机制（YugabyteDB Hybrid Time）

在集群中执行以下查询，观察 timestamp 分配行为：

```sql
-- 查看当前事务的 hybrid time
CREATE TABLE IF NOT EXISTS test_clock (id INT PRIMARY KEY, ts TEXT);

-- 写入并观察 hybrid time (HLC -> physical + logical)
INSERT INTO test_clock VALUES (1, to_char(current_timestamp, 'YYYY-MM-DD HH24:MI:SS.US'));

-- 对比不同节点上的 now() 差异
SELECT host, now()::timestamptz(6) - now()::timestamptz(6) AS clock_drift
FROM yb_servers();
```

**记录要点**：
- YugabyteDB 使用 Hybrid Logical Clock (HLC) 而非 TrueTime
- HLC 由物理时钟 + 逻辑计数器组成，无需特殊硬件
- 跨区域时通过 Raft 附加的 `ht` 元数据保障全局序

### 2.2 共识协议（Raft）

```sql
-- 查看 tablet 分布与 leader 位置
SELECT tablet_id, table_name, tablet_leader_host, num_sstable_files
FROM yb_master_metrics();

-- 查看 Raft 角色
SELECT node_type, cloud, region, zone
FROM yb_servers();
```

### 2.3 并发控制与隔离级别

```sql
-- 验证 Read Committed（已在 .env 中通过 TSERVER_FLAGS 启用）
SHOW default_transaction_isolation;

-- 测试冲突事务
-- Session 1:
BEGIN ISOLATION LEVEL READ COMMITTED;
UPDATE test_clock SET ts = now() WHERE id = 1;

-- Session 2 (在另一个连接中运行):
BEGIN ISOLATION LEVEL READ COMMITTED;
UPDATE test_clock SET ts = now() WHERE id = 1;
-- 观察：等待超时还是立即冲突报错？
```

### 2.4 Geo-Partitioning 表空间

```sql
-- 创建分区表空间（按 README）
CREATE TABLESPACE "region1" WITH (
  replica_placement = '{
    "num_replicas": 1,
    "placement_blocks": [{
      "cloud": "cloud", "region": "region1", "zone": "zone", "min_num_replicas": 1
    }]
  }'
);

CREATE TABLESPACE "region2" WITH (
  replica_placement = '{
    "num_replicas": 1,
    "placement_blocks": [{
      "cloud": "cloud", "region": "region2", "zone": "zone", "min_num_replicas": 1
    }]
  }'
);

CREATE TABLESPACE "region3" WITH (
  replica_placement = '{
    "num_replicas": 1,
    "placement_blocks": [{
      "cloud": "cloud", "region": "region3", "zone": "zone", "min_num_replicas": 1
    }]
  }'
);

-- 创建 Leader Preference 表空间（读取优先 region1）
CREATE TABLESPACE "pref1" WITH (
  replica_placement = '{
    "num_replicas": 3,
    "placement_blocks": [
      { "cloud": "cloud", "region": "region1", "zone": "zone", "min_num_replicas": 1, "leader_preference": 1 },
      { "cloud": "cloud", "region": "region2", "zone": "zone", "min_num_replicas": 1, "leader_preference": 2 },
      { "cloud": "cloud", "region": "region3", "zone": "zone", "min_num_replicas": 1, "leader_preference": 3 }
    ]
  }'
);

-- 验证表空间
SELECT * FROM pg_tablespace;

-- 创建分区表示例
CREATE TABLE user_eu (id INT PRIMARY KEY, data TEXT) TABLESPACE region1;
CREATE TABLE user_us (id INT PRIMARY KEY, data TEXT) TABLESPACE region2;
CREATE TABLE user_asia (id INT PRIMARY KEY, data TEXT) TABLESPACE region3;
```

---

## Phase 3: 基准测试

### 3.1 延迟对比实验

**目标**：对比基准环境 vs 延迟环境下读写事务的平均延迟与 P99

**前置准备**：

```sql
CREATE TABLE perf_test (
  id BIGSERIAL PRIMARY KEY,
  data TEXT DEFAULT repeat('x', 256),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 预填充 10000 行
INSERT INTO perf_test (data)
SELECT repeat('x', 256) FROM generate_series(1, 10000);
```

#### 实验 A：无延迟基准（.env）

```bash
# 确保运行在基准环境
docker compose down -v
docker compose up -d --scale yb=3 --no-recreate
docker compose wait rf3isready
```

执行延迟采集脚本 `latency_test.sh`：

```bash
#!/bin/bash
# latency_test.sh - 测量读写延迟
# 用法: ./latency_test.sh [主机] [端口] [迭代次数] [标签]

HOST=${1:-yb-compose-yb-1}
PORT=${2:-5433}
ITER=${3:-1000}
TAG=${4:-baseline}

echo "{\"tag\":\"$TAG\",\"reads\":["
for i in $(seq 1 $ITER); do
  t_start=$(date +%s%N)
  docker compose exec -T pg psql -h $HOST -p $PORT -tAc "SELECT * FROM perf_test WHERE id = $((RANDOM % 10000 + 1))" > /dev/null 2>&1
  t_end=$(date +%s%N)
  latency_ns=$((t_end - t_start))
  if [ $i -gt 1 ]; then echo ","; fi
  echo "{\"latency_ms\":$(echo "scale=3; $latency_ns / 1000000" | bc)}"
done
echo "],\"writes\":["
for i in $(seq 1 $ITER); do
  t_start=$(date +%s%N)
  docker compose exec -T pg psql -h $HOST -p $PORT -tAc "INSERT INTO perf_test (data) VALUES (repeat('x', 256))" > /dev/null 2>&1
  t_end=$(date +%s%N)
  latency_ns=$((t_end - t_start))
  if [ $i -gt 1 ]; then echo ","; fi
  echo "{\"latency_ms\":$(echo "scale=3; $latency_ns / 1000000" | bc)}"
done
echo "]}"
```

```bash
# 采集基准数据
chmod +x latency_test.sh
./latency_test.sh yb-compose-yb-1 5433 1000 baseline > result_baseline.json

# 计算延迟统计（PG 分析查询）
docker compose exec -T pg psql -h yb-compose-yb-1 -c "
WITH reads AS (
  SELECT id, (random() * 9 + 1)::int AS bucket
  FROM generate_series(1,10) id
)
SELECT 'Read Avg' as metric, avg(latency_ms)::numeric(10,2),
       percentile_cont(0.50) WITHIN GROUP (ORDER BY latency_ms) as p50,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY latency_ms) as p99
FROM (
  SELECT extract('ms' FROM clock_timestamp() - clock_timestamp()) AS latency_ms
  FROM perf_test TABLESAMPLE BERNOULLI(1)
  LIMIT 1000
) t;
"
```

#### 实验 B：有延迟环境（.env.delay）

```bash
docker compose down -v
docker compose --env-file=.env.delay up -d --scale yb=3 --no-recreate
docker compose wait rf3isready

# 采集合延迟数据
./latency_test.sh yb-compose-yb-1 5433 1000 delay_30ms > result_delay.json
```

#### 实验 C：跨节点读取（模拟就近读）

```bash
# 从 region3 节点读取 region1 leader 的数据（对比延迟差异）
./latency_test.sh yb-compose-yb-3 5433 1000 cross_region > result_cross.json
```

**数据汇总表**：

| 场景 | 读平均(ms) | 读P50(ms) | 读P99(ms) | 写平均(ms) | 写P50(ms) | 写P99(ms) |
|------|-----------|----------|----------|-----------|----------|----------|
| 基准(无延迟) | | | | | | |
| delay=30ms/zone | | | | | | |
| 跨region读取 | | | | | | |

---

### 3.2 吞吐量实验（TPC-C）

**工具选择**：使用 go-tpc（https://github.com/pingcap/go-tpc）

```bash
# 安装 go-tpc（或在 pg 容器内编译）
docker compose run --rm pg bash -c "
  apk add --no-cache go git
  git clone https://github.com/pingcap/go-tpc /tmp/go-tpc
  cd /tmp/go-tpc && go build -o /usr/local/bin/go-tpc
"

# 初始化 TPC-C 数据（仓库数=10，数据量约 1GB）
docker compose run --rm pg \
  go-tpc tpcc prepare -H yb-compose-yb-1 -P 5433 -D yugabyte \
  --warehouses 10 --threads 4 --ignore-error

# 运行 TPC-C 压测（并发线程数分别设为 4, 8, 16, 32, 64）
for threads in 4 8 16 32 64; do
  echo "===== Threads: $threads ====="
  docker compose run --rm pg \
    go-tpc tpcc run -H yb-compose-yb-1 -P 5433 -D yugabyte \
    --warehouses 10 --threads $threads \
    --time 60 --ignore-error \
    --output result_tpcc_t${threads}.json
done

# 清理 TPC-C 数据
docker compose run --rm pg \
  go-tpc tpcc cleanup -H yb-compose-yb-1 -P 5433 -D yugabyte
```

**数据汇总表**：

| 并发线程数 | tpmC | 平均延迟(ms) | 90%延迟(ms) | 99%延迟(ms) |
|-----------|------|-------------|------------|------------|
| 4 | | | | |
| 8 | | | | |
| 16 | | | | |
| 32 | | | | |
| 64 | | | | |

**备选方案**（如果 go-tpc 兼容性有问题）：
使用 BenchmarkSQL（https://github.com/pgspider/benchmarksql）：

```bash
docker compose run --rm pg bash -c "
  apk add --no-cache openjdk17 git ant
  git clone https://github.com/pgspider/benchmarksql /tmp/benchmarksql
  cd /tmp/benchmarksql && ant
  # 修改配置文件指向 yb-compose-yb-1:5433
  sed -i 's/localhost/yb-compose-yb-1/g' run/props.pg
  sed -i 's/5432/5433/g' run/props.pg
  sed -i 's/pg_yugabyte/yugabyte/g' run/props.pg
  # 修改 warehouses=10
  sed -i 's/warehouses=.*/warehouses=10/' run/props.pg
  # 运行
  cd run && java -jar BenchmarkSQL.jar -p pg -c props.pg
"
```

---

### 3.3 一致性开销实验

**目标**：对比不同读取一致性级别下的延迟与 Staleness

YugabyteDB 支持三种读取模式：
- `leader_only`（默认）：强一致，读 leader
- `follower_read`：可能读 follower，延迟更低，可能有写后读不一致
- `eventual_read`：最终一致，延迟最低

```bash
# 创建测试脚本 consistency_test.sh
cat > consistency_test.sh << 'SCRIPT'
#!/bin/bash
# 参数: $1=一致性级别, $2=迭代次数

LEVEL=${1:-leader_only}
ITER=${2:-500}
TABLE="perf_test"
HOST="yb-compose-yb-1"

echo "{" > /tmp/result_${LEVEL}.json
echo "\"level\":\"$LEVEL\"," >> /tmp/result_${LEVEL}.json
echo "\"results\":[" >> /tmp/result_${LEVEL}.json

for i in $(seq 1 $ITER); do
  t_start=$(date +%s%N)

  docker compose exec -T pg psql -h $HOST -tAc \
    "SET yb_read_preference='$LEVEL';
     SELECT count(*) FROM $TABLE WHERE id = $((RANDOM % 10000 + 1));" > /dev/null 2>&1

  t_end=$(date +%s%N)
  latency_ms=$(echo "scale=3; ($t_end - $t_start) / 1000000" | bc)

  if [ $i -gt 1 ]; then echo "," >> /tmp/result_${LEVEL}.json; fi
  echo "{\"iter\":$i,\"latency_ms\":$latency_ms}" >> /tmp/result_${LEVEL}.json
done

echo "]}" >> /tmp/result_${LEVEL}.json
SCRIPT

chmod +x consistency_test.sh

# 测试三种级别
for level in leader_only follower_read eventual_read; do
  ./consistency_test.sh $level 500
done
```

**分析查询**：

```sql
-- 验证 follower_read 的 staleness
CREATE TABLE IF NOT EXISTS consistency_probe (
  id INT PRIMARY KEY,
  val INT,
  write_time TIMESTAMPTZ DEFAULT now()
);

-- 写入后立即读取（测试写后读一致性）
TRUNCATE consistency_probe;
INSERT INTO consistency_probe (id, val) VALUES (1, 100);

-- 使用不同级别读取
SET yb_read_preference = 'leader_only';
SELECT val FROM consistency_probe WHERE id = 1;

SET yb_read_preference = 'follower_read';
SELECT val FROM consistency_probe WHERE id = 1;

SET yb_read_preference = 'eventual_read';
SELECT val FROM consistency_probe WHERE id = 1;
```

**数据汇总表**：

| 一致性级别 | 读平均延迟(ms) | P99(ms) | 是否保证写后读 |
|------------|---------------|--------|--------------|
| leader_only | | | 是 |
| follower_read | | | 取决于 |
| eventual_read | | | 否 |

---

### 3.4 扩展性实验

**目标**：从 1 节点扩展到 3 节点，测量吞吐量变化

```bash
# 基准环境
docker compose down -v
docker compose up -d --scale yb=1 --no-recreate
docker compose wait rf3isready 2>/dev/null || echo "单节点无 rf3isready"

# 准备数据
docker compose run --rm pg \
  go-tpc tpcc prepare -H yb-compose-yb-1 -P 5433 -D yugabyte \
  --warehouses 10 --threads 4 --ignore-error

# 测试 1 节点吞吐
docker compose run --rm pg \
  go-tpc tpcc run -H yb-compose-yb-1 -P 5433 -D yugabyte \
  --warehouses 10 --threads 16 --time 60 --ignore-error \
  --output result_scale_1node.json

# 扩展至 2 节点
docker compose up -d --scale yb=2 --no-recreate
sleep 30  # 等待 rebalance
docker compose run --rm pg \
  go-tpc tpcc run -H yb-compose-yb-1 -P 5433 -D yugabyte \
  --warehouses 10 --threads 16 --time 60 --ignore-error \
  --output result_scale_2node.json

# 扩展至 3 节点
docker compose up -d --scale yb=3 --no-recreate
sleep 30
docker compose run --rm pg \
  go-tpc tpcc run -H yb-compose-yb-1 -P 5433 -D yugabyte \
  --warehouses 10 --threads 16 --time 60 --ignore-error \
  --output result_scale_3node.json

# 清理
docker compose run --rm pg \
  go-tpc tpcc cleanup -H yb-compose-yb-1 -P 5433 -D yugabyte
```

**数据汇总表**：

| 节点数 | tpmC | 与 1 节点比值 | 理想线性 |
|-------|------|--------------|---------|
| 1 | | 1.0x | 1.0x |
| 2 | | | 2.0x |
| 3 | | | 3.0x |

---

## Phase 4: 进阶实验

### 4.1 Commit Wait 开销量化

**目标**：测量 YugabyteDB 在跨区域事务中等待时钟不确定性消除的时间占比。

```sql
-- 创建用于观测的事务日志表
CREATE TABLE commit_wait_log (
  id BIGSERIAL PRIMARY KEY,
  start_ht BIGINT,          -- 事务开始的 Hybrid Time
  end_ht BIGINT,            -- 事务提交的 Hybrid Time
  wait_duration_ms NUMERIC, -- Commit Wait 等待时间（推算）
  node_host TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 使用 pg_stat_statements 或 EXPLAIN ANALYZE 观察提交时间
-- 方法：对比本地事务 vs 跨 region 事务的提交耗时
```

**测试脚本**：

```sql
-- 测试 1：同一 region 的事务提交时间
\timing on

BEGIN;
UPDATE perf_test SET data = 'local_txn' WHERE id = 1;
COMMIT;

-- 测试 2：跨 region 事务（表使用 pref1 表空间，leader 在 region1）
BEGIN;
UPDATE user_us SET data = 'cross_txn' WHERE id = 1; -- region2 上的表
UPDATE user_asia SET data = 'cross_txn' WHERE id = 1; -- region3 上的表
COMMIT;
```

```bash
# 自动化采集
cat > commit_wait_test.sh << 'SCRIPT'
#!/bin/bash
HOST=$1
ITER=${2:-100}
TAG=${3:-local}

echo "{\"tag\":\"$TAG\",\"txns\":["
for i in $(seq 1 $ITER); do
  # 执行 100 次事务，记录每次提交耗时
  result=$(docker compose exec -T pg psql -h $HOST -tAc \
    "SELECT extract('ms' FROM clock_timestamp() - clock_timestamp()) AS commit_ms
     FROM (SELECT clock_timestamp() AS start FROM perf_test WHERE id=1) s,
          LATERAL (UPDATE perf_test SET data='x' WHERE id=1 RETURNING clock_timestamp() AS mid) m,
          LATERAL (SELECT clock_timestamp() AS end) e;" 2>/dev/null)

  if [ $i -gt 1 ]; then echo ","; fi
  echo "{\"iter\":$i,\"commit_latency_ms\":$result}"
done
echo "]}"
SCRIPT
```

**分析**：与 Spanner 论文对比，Spanner 的 Commit Wait ≈ 2 × clock_uncertainty（TrueTime 下通常 1-7ms），YugabyteDB 使用 HLC 无需显式 Commit Wait，但 Raft 日志复制本身会引入跨 region 的网络延迟。

### 4.2 正确性验证

#### 实验 A：写后读一致性

```bash
cat > read_after_write_test.sh << 'SCRIPT'
#!/bin/bash
echo "Test: Read-After-Write consistency"
FAILURES=0
TOTAL=1000

for i in $(seq 1 $TOTAL); do
  # 写入一个唯一值
  UNIQ="val_$(date +%s%N)"
  docker compose exec -T pg psql -h yb-compose-yb-1 -tAc \
    "INSERT INTO consistency_probe (id, val) VALUES ($i, $i) ON CONFLICT (id) DO UPDATE SET val = $i;" > /dev/null 2>&1

  # 立即从不同节点读取 — 确保读到自己写入的值
  for node in yb-compose-yb-1 yb-compose-yb-2 yb-compose-yb-3; do
    READ_VAL=$(docker compose exec -T pg psql -h $node -tAc \
      "SET yb_read_preference = 'leader_only'; SELECT val FROM consistency_probe WHERE id = $i;" 2>/dev/null)

    if [ "$READ_VAL" != "$i" ]; then
      echo "FAIL: wrote=$i, read from $node=$READ_VAL"
      FAILURES=$((FAILURES + 1))
    fi
  done
done

echo "Total: $TOTAL, Failures: $FAILURES"
if [ $FAILURES -eq 0 ]; then echo "PASS: Read-After-Write consistency holds"; fi
SCRIPT
```

#### 实验 B：跨节点转账（外部一致性验证）

```sql
-- 创建账户表
CREATE TABLE accounts (
  id INT PRIMARY KEY,
  balance NUMERIC DEFAULT 0,
  version INT DEFAULT 0
);

-- 预充值
INSERT INTO accounts VALUES (1, 1000, 0), (2, 0, 0);
```

```bash
cat > transfer_test.sh << 'SCRIPT'
#!/bin/bash
# 在两个并发 session 中执行转账，验证余额守恒

docker compose exec -T pg psql -h yb-compose-yb-1 -c "
  BEGIN ISOLATION LEVEL REPEATABLE READ;
  UPDATE accounts SET balance = balance - 100, version = version + 1 WHERE id = 1 AND balance >= 100;
  UPDATE accounts SET balance = balance + 100, version = version + 1 WHERE id = 2;
  COMMIT;
" &

docker compose exec -T pg psql -h yb-compose-yb-2 -c "
  BEGIN ISOLATION LEVEL REPEATABLE READ;
  UPDATE accounts SET balance = balance - 200, version = version + 1 WHERE id = 1 AND balance >= 200;
  UPDATE accounts SET balance = balance + 200, version = version + 1 WHERE id = 2;
  COMMIT;
" &

wait

# 验证余额守恒
docker compose exec -T pg psql -h yb-compose-yb-1 -c "
  SELECT SUM(balance) AS total_balance FROM accounts;
  -- 应始终等于 1000
"
SCRIPT
```

#### 实验 C：网络分区下的正确性（进阶 → Jepsen）

Jepsen 框架的搭建较复杂，作为进阶选项：

```bash
# 在独立机器上部署 Jepsen
git clone https://github.com/jepsen-io/jepsen
cd jepsen
# 编写 YugabyteDB 客户端与 nemesis（kill node, partition）
# 运行
lein run test --workload bank --nemesis partition
```

---

### 4.3 自动故障切换测试

**目标**：测量 RTO（恢复时间）和 RPO（数据丢失量）

```bash
cat > failover_test.sh << 'SCRIPT'
#!/bin/bash
set -e

HOST=yb-compose-yb-1

echo "=== Failover Test: Kill region1 node (yb-compose-yb-1) ==="

# 1. 启动持续写入
echo "Starting continuous writes..."
cat > /tmp/continuous_write.sql << 'EOSQL'
INSERT INTO failover_test (ts) SELECT now() FROM generate_series(1, 100);
EOSQL

# 2. 创建测试表
docker compose exec -T pg psql -h $HOST -c "
  CREATE TABLE IF NOT EXISTS failover_test (
    id BIGSERIAL PRIMARY KEY,
    ts TIMESTAMPTZ DEFAULT now()
  );
"

# 3. 后台持续写入
for i in $(seq 1 300); do
  docker compose exec -T pg psql -h $HOST \
    -c "INSERT INTO failover_test (ts) VALUES (now());" 2>/dev/null || echo "WRITE_FAIL at iter $i"
  sleep 0.1
done &
WRITER_PID=$!
sleep 2

# 4. 记录故障前最后行数
BEFORE=$(docker compose exec -T pg psql -h $HOST -tAc "SELECT count(*) FROM failover_test;" 2>/dev/null || echo "0")
echo "Rows before failover: $BEFORE"

# 5. 模拟故障：停止 region1 节点
FAILURE_TIME=$(date +%s%N)
echo "Killing yb-compose-yb-1 at $(date)"
docker compose stop yb-compose-yb-1

# 6. 探测故障转移时间
RECOVERED=false
for i in $(seq 1 60); do
  if docker compose exec -T pg psql -h yb-compose-yb-2 \
    -tAc "SELECT count(*) FROM failover_test;" > /dev/null 2>&1; then
    RECOVER_TIME=$(date +%s%N)
    RTO_MS=$(echo "scale=2; ($RECOVER_TIME - $FAILURE_TIME) / 1000000" | bc)
    RECOVERED=true
    ROWS_AFTER=$(docker compose exec -T pg psql -h yb-compose-yb-2 -tAc "SELECT count(*) FROM failover_test;" 2>/dev/null || echo "0")
    echo "Recovered on yb-compose-yb-2 after ${RTO_MS}ms"
    echo "Rows after failover: $ROWS_AFTER"
    echo "RPO (data loss): $((BEFORE - ROWS_AFTER)) rows"
    break
  fi
  sleep 1
done

if [ "$RECOVERED" = false ]; then
  echo "FAIL: Did not recover within 60s"
fi

# 7. 停止写入进程
kill $WRITER_PID 2>/dev/null || true

# 8. 恢复节点
echo "Restarting yb-compose-yb-1..."
docker compose up -d --scale yb=3 --no-recreate

echo "=== Failover Test Complete ==="
echo "RTO: ${RTO_MS:-N/A}ms"
echo "RPO rows lost: $((BEFORE - ROWS_AFTER))"
SCRIPT

chmod +x failover_test.sh
./failover_test.sh
```

**数据记录表**：

| 场景 | RTO (ms) | RPO (行数/字节) | 恢复后数据一致性 |
|------|---------|----------------|----------------|
| 停 region1 节点 | | | |
| 停 region2 节点 | | | |
| 停 region3 节点 | | | |

---

## Phase 5: 数据汇总与报告产出

### 5.1 数据提取脚本

```bash
cat > extract_results.sh << 'SCRIPT'
#!/bin/bash
# 生成结果汇总 JSON

cat << EOF
{
  "cluster": {
    "nodes": 3,
    "replication_factor": 3,
    "regions": ["region1", "region2", "region3"],
    "base_delay_ms": $(grep NET_DELAY_MS .env | cut -d= -f2)
  },
  "latency": $(cat result_baseline.json),
  "latency_delay": $(cat result_delay.json),
  "tpcc": {
    "t4": $(cat result_tpcc_t4.json),
    "t8": $(cat result_tpcc_t8.json),
    "t16": $(cat result_tpcc_t16.json),
    "t32": $(cat result_tpcc_t32.json),
    "t64": $(cat result_tpcc_t64.json)
  },
  "consistency": {
    "leader_only": $(cat /tmp/result_leader_only.json),
    "follower_read": $(cat /tmp/result_follower_read.json),
    "eventual_read": $(cat /tmp/result_eventual_read.json)
  },
  "scalability": {
    "tpmC_1node": N/A,
    "tpmC_2node": N/A,
    "tpmC_3node": N/A
  },
  "failover": {
    "rto_ms": N/A,
    "rpo_rows": N/A
  }
}
EOF
SCRIPT
```

### 5.2 报告结构

最终报告应包含以下章节：

```
1. 背景与目的
2. 环境配置（Docker Compose + 3节点 RF=3 拓扑）
3. 架构分析
   3.1 时钟同步（HLC）
   3.2 共识协议（Raft）
   3.3 并发控制（MVCC + SSI）
   3.4 Geo-Partitioning
4. 基准测试结果
   4.1 延迟对比（无延迟 vs 跨 region）
   4.2 TPC-C 吞吐量
   4.3 一致性开销
   4.4 扩展性
5. 进阶实验
   5.1 Commit Wait 分析
   5.2 正确性验证
   5.3 故障切换（RTO/RPO）
6. 结论与对比（与 Spanner 论文、CockroachDB 对比）
7. 参考文档
```

### 5.3 关键对比维度（与实验指南要求映射）

| 指南要求 | 对应实验 | 指标 |
|---------|---------|------|
| 延迟对比 | 3.1 延迟实验 | avg/P50/P99 延迟 |
| 吞吐量 | 3.2 TPC-C | tpmC |
| 一致性开销 | 3.3 一致性实验 | leader_only vs follower vs eventual |
| 扩展性 | 3.4 扩展性实验 | tpmC vs 节点数 |
| Commit Wait | 4.1 | Commit 耗时占比 |
| 正确性验证 | 4.2 | 外部一致性检验 |
| 故障切换 | 4.3 | RTO/RPO |

---

## 附录 A：常用运维命令

```bash
# 查看节点状态
docker compose exec -t yb yugabyted status

# 查看 YB-Master UI
curl http://localhost:7000

# 查看 YB-TServer UI
curl http://localhost:9000

# 查看 tablet 分布
docker compose exec -T pg psql -h yb-compose-yb-1 -c "SELECT * FROM yb_servers();"

# 查看集群配置
docker compose exec -T pg psql -h yb-compose-yb-1 -c "SELECT * FROM yb_client_config();"

# 动态调整节点数量
docker compose up -d --scale yb=4 --no-recreate  # 增加到 4 节点

# 关闭集群
docker compose down

# 完全清理（包括数据卷）
docker compose down -v
```

## 附录 B：环境变量参考

| 变量 | 默认值 | 说明 |
|------|-------|------|
| `COMPOSE_PROJECT_NAME` | yb-compose | Docker Compose 项目名 |
| `TSERVER_FLAGS` | yb_enable_read_committed_isolation=true | TServer 启动参数 |
| `MASTER_FLAGS` | (空) | Master 启动参数 |
| `NET_DELAY_MS` | 1 | 基础网络延迟(ms)，乘以 zone 编号为实际延迟 |

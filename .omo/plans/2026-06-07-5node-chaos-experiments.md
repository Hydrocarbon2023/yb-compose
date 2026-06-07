# 5 节点混沌工程实验执行计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task.

**Goal:** 在 5 节点 RF=3 集群上完成 WAN 模拟（jitter/loss/带宽）、asymmetric-delay、动态分区压测等混沌工程实验

**前置条件:** docker-compose.yaml 已改为 5 个独立 service（yb-1~yb-5），chaosctl 已支持 5 节点 + 带宽参数

**Tech Stack:** Docker Compose, YugabyteDB, chaosctl, tc netem, iptables, pgbench

---

## Task 1: 验证并启动 5 节点集群 + 更新 Makefile

**Files:**
- Modify: `docker-compose.yaml` — 已重写为 5 独立 service
- Modify: `Makefile` — 适配 yb-1~yb-5 service 名称，去掉 `--scale`
- Verify: `docker-compose.yaml` YAML 合法且服务可启动

- [ ] **Step 1: 清理旧容器并启动 5 节点**

```bash
cd /Users/wangshuo/dev-home/code/yb-compose
docker compose --env-file=.env.delay down -v
docker compose --env-file=.env.delay up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 pg rfNready
```

Expected: 所有 `yb-*` 容器显示 `(healthy)`，`rfNready` 退出码 0

- [ ] **Step 2: 等待集群就绪并验证**

```bash
docker compose wait rfNready
docker compose exec yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM yb_servers();"
# Expected: 5
docker compose exec yb-1 ysqlsh -h yb-1 -tAc "SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;"
# Expected: 5 rows, region1~region5
```

- [ ] **Step 3: 确认延迟已注入**

```bash
for i in 1 2 3 4 5; do
  echo "yb-$i: $(docker compose exec yb-$i tc qdisc show dev eth0 2>/dev/null | grep -oE 'delay [0-9]+ms')"
done
# Expected: 30ms, 60ms, 90ms, 120ms, 150ms
```

- [ ] **Step 4: 更新 Makefile**

当前 Makefile 中有 `--scale yb=5`、`rf3isready` 等对 replica 模式的引用。全部替换为独立 service 命令：

```makefile
# 改动:
# - up: docker compose up -d yb-1 yb-2 yb-3 yb-4 yb-5 ...
# - up-delay: --env-file=.env.delay + 同上
# - wait: docker compose wait rfNready
# - psql: docker compose exec -it yb-1 ysqlsh -h yb-1
# - bench: 所有 ysqlsh -h yb-compose-yb-1 → ysqlsh -h yb-1
# - clean: docker compose down -v
```

关键变化：
- 删除所有 `--scale yb=N`
- 删除 `--no-recreate`
- `rf3isready` → `rfNready`
- `yb-compose-yb-N` → `yb-N`（容器名就是 service 名）
- 延迟验证循环从 1 到 5

- [ ] **Step 5: 确认 Makefile 可工作**

```bash
make status
# Expected: 5 nodes 正常显示
```

---

## Task 2: 更新 chaosctl 适配独立 service + 验证

**Files:**
- Modify: `scripts/chaosctl` — 容器名从 `yb-compose-yb-N` 变为 `yb-N`

- [ ] **Step 1: 检查并更新 chaosctl 容器名适配**

当前 chaosctl 的 NODES 数组是：
```bash
readonly NODES=(
  "${COMPOSE_PROJECT}-yb-1"
  "${COMPOSE_PROJECT}-yb-2"
  "${COMPOSE_PROJECT}-yb-3"
  "${COMPOSE_PROJECT}-yb-4"
  "${COMPOSE_PROJECT}-yb-5"
)
```

在新的独立 service 模式下，容器名就是 `yb-1`, `yb-2` 等（没有 `yb-compose-` 前缀）。COMPOSE_PROJECT_NAME 不再用于容器名。

改为：
```bash
readonly NODES=(
  "yb-1"
  "yb-2"
  "yb-3"
  "yb-4"
  "yb-5"
)
```

resolve_node 和 resolve_node_name 也相应简化。

- [ ] **Step 2: 重建 chaosctl 镜像**

```bash
make chaos-build
```

- [ ] **Step 3: 验证 chaosctl status 可正常工作**

```bash
make chaos CMD="status"
# Expected: 5 nodes, 对应延迟 (30/60/90/120/150ms), ysql accepting
```

---

## Task 3: 实验 1 — WAN 模拟 (Jitter + Loss + Bandwidth)

**目标:** 使用 chaosctl `delay set` 的 jitter/loss/bandwidth 参数模拟不稳定的跨 region 网络

- [ ] **Step 1: 准备 perf_test 表**

```bash
docker exec yb-1 ysqlsh -h yb-1 -c "
CREATE TABLE IF NOT EXISTS perf_test (
  id BIGSERIAL PRIMARY KEY, data TEXT DEFAULT repeat('x', 256), created_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO perf_test (data) SELECT repeat('x', 256) FROM generate_series(1, 10000) ON CONFLICT DO NOTHING;
"
```

- [ ] **Step 2: 基准延迟测量 (无额外 jitter/loss)**

```bash
python3 scripts/02-latency-bench.py --iter 30
```

记录结果到临时文件。

- [ ] **Step 3: 注入 jitter + loss**

```bash
# region2: 60ms + 20ms jitter + 2% loss
make chaos CMD="delay set region2 60 20 2"
# region3: 90ms + 30ms jitter + 5% loss
make chaos CMD="delay set region3 90 30 5"
```

- [ ] **Step 4: 在有损网络下测量延迟**

```bash
python3 scripts/02-latency-bench.py --iter 30
```

观察有损网络下 P99 延迟的变化，对比 Step 2 的结果。

- [ ] **Step 5: 注入带宽限制**

```bash
# region4: 120ms + 10mbit 带宽限制
make chaos CMD="delay set region4 120 0 0 10mbit"
```

- [ ] **Step 6: 带宽限制下测量**

```bash
python3 scripts/02-latency-bench.py --iter 30
```

观察带宽限制对吞吐的影响。

- [ ] **Step 7: 恢复所有节点到初始延迟**

```bash
make chaos CMD="delay clear all"
make chaos CMD="delay set region1 30"
make chaos CMD="delay set region2 60"
make chaos CMD="delay set region3 90"
make chaos CMD="delay set region4 120"
make chaos CMD="delay set region5 150"
```

---

## Task 4: 实验 2 — Asymmetric-Delay 场景

**目标:** 验证 Raft leader 是否会迁移到延迟最低的节点

- [ ] **Step 1: 查看当前 leader 分布**

```bash
docker exec yb-1 ysqlsh -h yb-1 -tAc "SELECT host, region FROM yb_servers() ORDER BY host;"
```

- [ ] **Step 2: 运行 asymmetric-delay 场景 (10/25/50/75/100ms)**

```bash
make chaos CMD="scenario run asymmetric-delay"
```

- [ ] **Step 3: 注入后用 yb-admin 查看 tablet leader 分布**

```bash
# 查看 tablet 分布
docker exec yb-1 yb-admin -master_addresses yb-1:7100 list_tablets | head -20
```

对比 leader 是否分布在低延迟节点上。

- [ ] **Step 4: 恢复** 

```bash
make chaos CMD="delay clear all"
make chaos CMD="delay set region1 30"
make chaos CMD="delay set region2 60"
make chaos CMD="delay set region3 90"
make chaos CMD="delay set region4 120"
make chaos CMD="delay set region5 150"
```

---

## Task 5: 实验 3 — 动态分区压测

**目标:** 在延迟基准测试过程中注入网络分区，观测客户端行为

- [ ] **Step 1: 准备测试**

创建 chaos-bench.sh 脚本 (scripts/chaos-bench.sh)：

```bash
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
    docker exec yb-2 ysqlsh -h yb-2 -c "INSERT INTO perf_test (data) VALUES (repeat('x', 256))" 2>/dev/null || echo "WRITE_FAIL at iter $i"
    sleep 0.5
  done
) &
WRITE_PID=$!

sleep 3

# Phase 1: 正常写入 (基线)
echo "=== Phase 1: 正常 (前 10 次) ==="
for i in $(seq 1 10); do
  t0=$(date +%s%N)
  docker exec yb-2 ysqlsh -h yb-2 -tAc "SELECT count(*) FROM perf_test WHERE id = $((RANDOM % 10000 + 1))" >/dev/null 2>&1
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
  result=$(docker exec yb-2 ysqlsh -h yb-2 -tAc "SELECT count(*) FROM perf_test WHERE id = $((RANDOM % 10000 + 1))" 2>&1 || echo "FAIL")
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
  docker exec yb-2 ysqlsh -h yb-2 -tAc "SELECT count(*) FROM perf_test WHERE id = $((RANDOM % 10000 + 1))" >/dev/null 2>&1
  t1=$(date +%s%N)
  echo "  read $i: $(((t1-t0)/1000000))ms (恢复后)"
  sleep 1
done

echo ""
echo "=== 测试完成 ==="
```

```bash
chmod +x scripts/chaos-bench.sh
```

- [ ] **Step 2: 运行动态分区压测**

```bash
bash scripts/chaos-bench.sh yb-2 30
```

- [ ] **Step 3: 验证恢复后的集群状态**

```bash
make chaos CMD="status"
```

---

## Task 6: 更新实验报告

**Files:**
- Modify: `doc/实验报告.md` — 追加 5 节点实验数据

- [ ] **Step 1: 收集所有实验数据**

从 Task 3, 4, 5 的输出中提取关键指标：
- Task 3: jitter/loss/bandwidth 下的延迟对比表
- Task 4: asymmetric-delay 下 leader 分布
- Task 5: 分区前后读写成功率

- [ ] **Step 2: 更新报告**

追加到 `doc/实验报告.md` 第 5 章「混沌工程实验」之后：

```
### 5.6 5 节点 WAN 模拟 (Jitter + Loss + Bandwidth)
- 对比表格: 基准 vs 有损 vs 带宽限制
- 关键发现: P99 在有损网络下 x 倍增长

### 5.7 Asymmetric Delay 下的 Leader 分布
- 不同延迟配置下 tablet leader 的分布
- 关键发现: Leader Preference 是否自动适配

### 5.8 动态分区压测
- 分区注入前后读写成功率对比
- 分区期间平均延迟和失败率
- 恢复后的收敛时间
```

- [ ] **Step 3: 更新 README.md 中的配置步骤**

README.md 中的 `--scale yb=5` → 直接启动所有 service，更新配置步骤。

---

## 关键指标对比表 (待填充)

| 实验 | 指标 | 基准 | 有损/延迟 | 恢复后 |
|------|------|------|----------|--------|
| Jitter+Loss 延迟 | 读平均(ms) | TBD | TBD | TBD |
| Jitter+Loss 延迟 | 读 P99(ms) | TBD | TBD | TBD |
| Bandwidth 限制 | 读平均(ms) | TBD | TBD | TBD |
| 动态分区 | 写入成功率 | 100% | TBD | 100% |
| 动态分区 | 平均延迟(ms) | TBD | TBD | TBD |

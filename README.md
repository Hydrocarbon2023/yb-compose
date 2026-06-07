# yblab — YugabyteDB 全球分布式数据库测评

在单机 Docker 上搭建 5 节点 RF=3 的 YugabyteDB 集群，通过 tc netem 模拟跨 region 网络延迟、iptables 模拟网络分区，完成完整的分布式数据库测评与混沌工程实验。

## ⚡ 一键复现全部实验

```bash
# 只需两步
make chaos-build
make experiment-all        # 自动依次执行全部实验
```

`experiment-all` 自动执行：清理旧环境 → 架构分析 → 基准测试 → 延迟测试 → 故障切换 → WAN 模拟 → 时钟偏移 → 震荡测试。全程约 30-40 分钟。

## 仓库结构

```
.
├── .env                         # 基准环境配置 (NET_DELAY_MS=1)
├── .env.delay                   # 延迟环境配置 (NET_DELAY_MS=30)
├── .gitignore
├── Makefile                     # 一键实验入口
├── compose/                     # Docker Compose 文件
│   ├── base.yaml                # 集群定义 (5 yb + rfNready)
│   ├── bench.yaml               # 压测扩展 (pgbench)
│   ├── chaos.yaml               # 混沌工程控制器
│   ├── dev.yaml                 # 开发容器
│   └── tpcc.yaml                # TPC-C 压测 (go-tpc)
├── docker/                      # Dockerfile
│   ├── Dockerfile.chaosctl      # 混沌控制器镜像
│   ├── Dockerfile.pg            # 自定义 pgbench 客户端镜像
│   └── Dockerfile.tpcc          # TPC-C 基准测试镜像
├── cmd/                         # 独立工具
│   └── chaosctl/chaosctl        # 混沌工程控制器 CLI
├── README.md
├── scripts/                     # 实验脚本
│   ├── 01-setup-perf-test.sh    # 创建 perf_test 表并填充
│   ├── 02-latency-bench.py      # 跨节点延迟基准测试
│   ├── 02-latency-bench-persist.py  # 延迟基准测试 (持久连接版)
│   ├── 03-consistency-test.sh   # 一致性级别 + 转账正确性
│   ├── 04-failover-test.sh      # 故障切换 RTO/RPO
│   ├── 05-clock-skew-partition.sh   # 时钟偏移 + 分区组合实验
│   ├── 06-flapping-node-test.sh # 震荡节点测试
│   ├── 07-chaos-bench.sh        # 动态分区压测脚本
│   ├── 08-tpcc-benchmark.sh     # TPC-C 基准测试
│   └── 09-scalability-test.sh   # 扩展性测试
└── sql/
    ├── 01-hlc-clock.sql         # HLC 时钟同步实验
    ├── 02-tablespaces.sql       # Geo-Partitioning 表空间
    └── 03-isolation-test.sql    # 隔离级别测试
```

## 环境要求

| 项目 | 规格 |
|------|------|
| 容器运行时 | Docker Desktop / Docker Engine |
| Docker Compose | v2.x+ |
| 所需镜像 | 自动拉取: yugabytedb/yugabyte, caddy:2-alpine, alpine:latest |
| 本地构建 | `yb-compose-chaosctl` (make chaos-build) |

## 在容器内运行实验（可选）

不想在宿主机装依赖？可以直接在 Docker 容器内跑实验：

```bash
# 一键复现全部实验（容器内自动安装 make + python3）
docker compose -f compose/dev.yaml run --rm yblab make experiment-all

# 运行单项实验
docker compose -f compose/dev.yaml run --rm yblab make experiment-wan
docker compose -f compose/dev.yaml run --rm yblab make experiment-failover-docker

# 进入交互式 Shell（调试用）
docker compose -f compose/dev.yaml run --rm yblab bash
```

原理：将宿主机的 Docker socket (`/var/run/docker.sock`) 挂载到容器内，容器中的 docker CLI 直接操作宿主机的 Docker 守护进程，相当于在宿主机上运行。无需嵌套 Docker 或特权模式。

---

## 实验操作指南

每个实验均可独立运行，按编号顺序执行。所有实验的输出直接打印到终端。

---

### 实验 1: 环境搭建与架构分析

**目的**: 验证 5 节点 RF=3 集群的 HLC 时钟同步、Raft 拓扑和 Geo-Partitioning。

```bash
make experiment-hlc          # HLC 时钟同步: 对比各节点 now()
make experiment-tablespace   # 创建 region1-5 + pref1 表空间
make experiment-raft         # 查看 yb_servers() 拓扑
```

**预期输出**:
- HLC: 同主机各节点 `now()` 完全一致
- Raft: 5 节点, 3 masters (1 leader + 2 followers) + 2 tservers
- 表空间: region1, region2, region3, region4, region5, pref1 创建成功

---

### 实验 2: 基准延迟测试

**目的**: 测量无延迟环境下 5 个节点的读写延迟基线。

```bash
# 启动基准集群
make up

# 运行基准测试
make experiment-latency-baseline
```

**预期输出**:
```
region1 (30ms egress):  READ avg≈49ms  P50≈49ms  P99≈59ms
region2 (60ms egress):  READ avg≈59ms  P50≈54ms  P99≈85ms
...
```
> 所有节点 ~50ms 延迟主要来自 Docker 网络栈 + psql 连接建立开销。无 tc netem 延迟注入时，节点间延迟差异极小。

---

### 实验 3: 延迟环境基准测试

**目的**: 在 30/60/90/120/150ms 延迟梯度下测量读写延迟。

```bash
make up-delay               # 启动延迟集群 (自动注入 tc netem)
make experiment-latency-delay  # 运行延迟基准测试
make experiment-rtt         # 验证跨节点 RTT
```

**预期输出**:
```
                  读 avg    读 P99    写 avg
region1 (30ms):   104ms     131ms     103ms
region2 (60ms):   135ms     202ms     133ms
region3 (90ms):   167ms     258ms     164ms
region4 (120ms):  198ms     321ms     194ms
region5 (150ms):  229ms     354ms     226ms

RTT: region1↔region5 = 180ms, region4↔region5 = 270ms
```

延迟与 egress 延迟呈线性关系：`latency ≈ 0.83 × egress + 80ms` (R² ≈ 0.997)

---

### 实验 4: 故障切换 RTO

**目的**: 对比 docker stop（进程崩溃）和 iptables（网络分区）两种故障场景的恢复时间。

```bash
# 实验 4a: docker stop 故障切换
make experiment-failover-docker

# 实验 4b: iptables 网络分区
make experiment-failover-iptables
```

**预期输出**:
| 场景 | RTO |
|------|-----|
| docker stop 主节点 | ~515ms |
| iptables isolate 主节点 | ~1000-1500ms (含 500ms heartbeat timeout) |

两种场景 RPO = 0（Raft 保证已提交日志不丢失）。

---

### 实验 5: WAN 模拟

**目的**: 验证 jitter+丢包和带宽限制对延迟分布的影响。

```bash
make experiment-wan
```

**执行内容**:
1. region2 设置 60ms+20ms jitter+2% loss
2. region3 设置 90ms+30ms jitter+5% loss
3. 运行延迟基准测试
4. 恢复标准延迟
5. region4 设置 120ms+10mbit 带宽限制
6. 再次运行延迟基准测试
7. 恢复标准延迟

**预期输出**:
```
                   条件           读 avg    读 P99    P99 增长
region1 (对照):     30ms           104ms     131ms     —
region2 (2% loss):  60+20j+2%L    137ms     192ms     1.0×
region3 (5% loss):  90+30j+5%L    310ms     1254ms    4.9×
region4 (对照):     120ms          199ms     303ms     —
region5 (对照):     150ms          230ms     378ms     —

带宽 10mbit: 对 256B 小查询无影响
```

---

### 实验 6: Asymmetric Delay

**目的**: 验证非均匀延迟下 Master leader 和 tablet leader 的分布行为。

```bash
make experiment-asymmetric
```

**执行内容**:
1. 5 个节点分别设置为 10/25/50/75/100ms 延迟
2. 检查 Master leader 所在节点
3. 检查 perf_test 表的 tablet leader 所在节点
4. 恢复标准延迟

**预期结果**:
- Master leader → region1 (10ms, 最低延迟节点) ✅ 自动选择
- Tablet leader → 不一定是 region1 ❌ 需 Leader Preference 配置

---

### 实验 7: 动态分区压测

**目的**: 在持续写入过程中注入网络分区，观测读写行为。

```bash
make experiment-partition-dynamic
```

**执行内容**: 后台持续写入 + 前端读取 → t=10s 隔离 region2 → t=25s 恢复

**预期输出**:
```
Phase 1 (正常 0-10s): 写入成功, 读 ~5000ms (锁竞争)
Phase 2 (隔离 10-25s): 写入全部失败, 读 ~80ms (follower, 无锁竞争)
Phase 3 (恢复 25-30s): 立即恢复
```

---

### 实验 8: 时钟偏移实验

**目的**: 操纵系统时钟验证 HLC 的单调性保证和安全机制。需要 Docker 容器支持 `SYS_TIME` capability（已在 compose/base.yaml 中启用）。

**先决条件**: 基准集群已启动 (`make up`)

```bash
make experiment-clock-skew
```

**执行内容**:
1. 记录所有节点基准时间
2. yb-5 时钟快进 +2s → 观测集群是否正常
3. yb-5 时钟回退 -4s → 观测 HLC 安全机制
4. 注入网络分区 → 观测写入行为

**预期结果**:
| 操作 | 观测 |
|------|------|
| 快进 +2s | 所有节点保持健康 |
| 回退 -4s | 约 4-5s 后检测到时钟异常的节点 postgres 自动关闭 |
| 分区期间写入 | 失败 (无法达成共识) |
| 恢复后 | 集群自愈 |

---

### 实验 9: 震荡节点测试

**目的**: 验证节点反复隔离/恢复（flapping）场景下的集群稳定性。

**先决条件**: 基准集群已启动 (`make up`)

```bash
make experiment-flapping
```

**执行内容**:
- region2 每 5 秒切换一次隔离/恢复，共 12 个周期 (120s)
- 后台持续写入 + 前端定时读取

**预期输出**:
| 观察项 | 结果 |
|--------|------|
| 隔离窗口写入 | 失败 |
| P99 延迟 | ~4800-5000ms (锁竞争主导) |
| 震荡停止后 | 完全恢复，无级联故障 |

---

## 实验复现总览

| 实验 | 命令 | 所需环境 | 耗时 |
|------|------|---------|------|
| 1. 架构分析 | `make experiment-phase1` | 基准集群 | 1min |
| 2. 基准延迟 | `make experiment-phase2` | 基准集群 | 2min |
| 3. 延迟基准 | `make experiment-phase3` | 延迟集群 | 5min |
| 4. 故障切换 | `make experiment-failover-*` | 延迟集群 | 2min |
| 5. WAN 模拟 | `make experiment-wan` | 延迟集群 | 5min |
| 6. Asymmetric | `make experiment-asymmetric` | 延迟集群 | 2min |
| 7. 动态分区 | `make experiment-partition-dynamic` | 延迟集群 | 1min |
| 8. 时钟偏移 | `make experiment-clock-skew` | 基准集群 | 1min |
| 9. 震荡节点 | `make experiment-flapping` | 基准集群 | 3min |

**一键全跑**: `make experiment-all`（约 30-40min）

## Makefile 命令参考

| 命令 | 作用 |
|------|------|
| `make up` | 启动基准集群 (无延迟) |
| `make up-delay` | 启动延迟集群 (30/60/90/120/150ms) |
| `make status` | 查看集群状态 + 拓扑 |
| `make psql` | 连接 yb-1 |
| `make fix-delay` | 修复/重设延迟注入 (tc netem) |
| `make clean` | 关停并清理所有容器和数据 |
| `make chaos CMD="status"` | 查看混沌工程状态 |
| `make chaos CMD="partition isolate region2"` | 隔离 region2 |
| `make chaos CMD="partition heal all"` | 恢复全部节点 |
| `make chaos CMD="scenario run flapping-node region2 12 5"` | 运行震荡场景 |
| `make chaos CMD="scenario list"` | 列出预设混沌场景 |

## 混沌工程命令

| 命令 | 作用 |
|------|------|
| `make chaos-status` | 查看集群网络/延迟/进程状态 |
| `make chaos CMD="partition isolate <node>"` | 完全隔离节点 (双向 DROP) |
| `make chaos CMD="partition heal [node]"` | 恢复节点 (不指定=全部) |
| `make chaos CMD="delay set <node> <ms> [jitter] [loss%]"` | 动态设置延迟 |
| `make chaos CMD="scenario run <name> [args]"` | 运行预设场景 |
| `make chaos-scenario CMD="flapping-node region2 12 5"` | 震荡节点场景 |

预设场景:
- `network-partition [node=region1] [duration=20]` — 隔离 N 秒后恢复
- `asymmetric-delay` — 10/25/50/75/100ms 非均匀延迟
- `cascading-failure [duration=15]` — 依次隔离 region1→region2
- `flapping-node [node=region2] [cycles=12] [interval=5]` — 反复隔离/恢复

## 延迟模拟原理

```yaml
# compose/base.yaml 关键部分:
cap_add:
  - NET_ADMIN     # 允许修改网络队列
  - SYS_TIME      # 允许时钟操作 (时钟偏移实验)

# tc netem 延迟注入:
# region1: tc qdisc add dev eth0 root netem delay 30ms
# region2: tc qdisc add dev eth0 root netem delay 60ms  
# region3: tc qdisc add dev eth0 root netem delay 90ms
# region4: tc qdisc add dev eth0 root netem delay 120ms
# region5: tc qdisc add dev eth0 root netem delay 150ms
```

各节点 egress 延迟通过 `tc netem` 注入，影响容器间出站流量。**跨节点 RTT = 源节点 egress + 目标节点 egress**。最大 RTT: region4 ↔ region5 = 270ms。

## 网络延迟对比

| 环境 | 配置 | 节点延迟 | 读 avg | 读 P50 | 写 avg |
|------|------|---------|--------|--------|--------|
| 基准 | NET_DELAY_MS=1 | ~0ms | 49ms | 49ms | 49ms |
| 延迟 | NET_DELAY_MS=30 | 30-150ms | 104-229ms | 110-229ms | 103-226ms |

## 分布式数据库设计要点

**YugabyteDB vs Spanner / CockroachDB**:

| 维度 | YugabyteDB | Google Spanner | CockroachDB |
|------|-----------|---------------|-------------|
| 时钟 | HLC（无硬件依赖） | TrueTime（需 GPS+原子钟） | HLC（同左） |
| 共识 | Raft（自定义优化） | Paxos | Raft（同左） |
| Commit Wait | 无需 | 2×clock_uncertainty (1-7ms) | 无需 |
| 故障恢复 | ~0.5-1.5s (Raft) | ~5s (Paxos) | ~1s (Raft) |
| SQL 兼容 | PostgreSQL | GoogleSQL | PostgreSQL |

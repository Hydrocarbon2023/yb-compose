# yblab — YugabyteDB 全球分布式数据库测评

在单机 Docker 上搭建 5 节点 RF=3 的 YugabyteDB 集群，通过 tc netem 模拟跨 region 网络延迟、iptables 模拟网络分区，完成完整的分布式数据库测评与混沌工程实验。

## ⚡ 一键复现全部实验

```bash
# 只需两步
make chaos-build
make experiment-all        # 自动依次执行全部实验
```

`experiment-all` 自动执行 11 个新脚本：架构分析 → 基准延迟 → 延迟基准 → 故障切换 → WAN 模拟 → 非均匀延迟 → 动态分区 → 时钟偏移 → 震荡节点 → TPC-C → 扩展性测试。全程约 45-60 分钟，取决于镜像构建和机器性能。

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
│   ├── experiment-01-setup-and-architecture.sh
│   ├── experiment-02-baseline-latency.sh
│   ├── experiment-03-delay-latency.sh
│   ├── experiment-04-failover-rto.sh
│   ├── experiment-05-wan-simulation.sh
│   ├── experiment-06-asymmetric-delay.sh
│   ├── experiment-07-dynamic-partition.sh
│   ├── experiment-08-clock-skew.sh
│   ├── experiment-09-flapping-node.sh
│   ├── experiment-10-tpcc-benchmark.sh
│   └── experiment-11-scalability.sh
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
| 所需镜像 | 自动拉取: yugabytedb/yugabyte, caddy:2-alpine, postgres:16 |
| 本地构建 | `yb-compose-chaosctl` (make chaos-build) |

## 在容器内运行实验（可选）

不想在宿主机装依赖？可以直接在 Docker 容器内跑实验：

```bash
# 一键复现全部实验（容器内自动安装 make + python3）
docker compose -f compose/dev.yaml run --rm yblab make experiment-all

# 运行单项实验
docker compose -f compose/dev.yaml run --rm yblab make experiment-05
docker compose -f compose/dev.yaml run --rm yblab make experiment-04

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
make experiment-01
```

**预期输出**:
- HLC: 同主机各节点 `now()` 完全一致
- Raft: 5 节点, 3 masters (1 leader + 2 followers) + 2 tservers
- 表空间: region1, region2, region3, region4, region5 创建成功

---

### 实验 2: 基准延迟测试

**目的**: 测量无延迟环境下 5 个节点的读写延迟基线。

```bash
make experiment-02
```

**预期输出**:
```
yb-1 (region1): READ avg≈65-68ms  P99≈82-89ms
yb-2 (region2): READ avg≈64-67ms  P99≈82-86ms
...
```
> 基准环境下实测约 64-68ms，主要来自 Docker 网络栈、psql 进程/连接建立和 YSQL 处理开销。无 tc netem 延迟注入时，节点间延迟差异极小。

---

### 实验 3: 延迟环境基准测试

**目的**: 在 30/60/90/120/150ms 延迟梯度下测量读写延迟。

```bash
make experiment-03
```

**预期输出**:
```
                  读 avg    读 P99    写 avg
region1 (30ms):    97ms     123ms     104ms
region2 (60ms):   129ms     202ms     135ms
region3 (90ms):   161ms     240ms     163ms
region4 (120ms):  198ms     323ms     193ms
region5 (150ms):  227ms     376ms     226ms

RTT: region1↔region5 = 180ms, region4↔region5 = 270ms
```

延迟与 egress 延迟呈线性关系：`latency ≈ 0.86 × egress + 70ms` (R² ≈ 0.998)

---

### 实验 4: 故障切换 RTO

**目的**: 对比 docker stop（进程崩溃）和 iptables（网络分区）两种故障场景的恢复时间。

```bash
make experiment-04
```

**预期输出**:
| 场景 | RTO |
|------|-----|
| docker stop 主节点 | ~560-590ms |
| iptables isolate 主节点 | net RTO ~560ms，total RTO 受 chaosctl 启动耗时影响 |

两种场景 RPO = 0（Raft 保证已提交日志不丢失）。

---

### 实验 5: WAN 模拟

**目的**: 验证 jitter+丢包和带宽限制对延迟分布的影响。

```bash
make experiment-05
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
make experiment-06
```

**执行内容**:
1. 5 个节点分别设置为 10/25/50/75/100ms 延迟
2. 检查 Master leader 所在节点
3. 检查 perf_test 表的 tablet leader 所在节点
4. 恢复标准延迟

**预期结果**:
- Master leader 不会因为当前延迟最低而自动迁移；实测可能停留在 region2 等非最低延迟节点
- Tablet leader 也不保证自动落在最低延迟节点；需要 Leader Preference 或显式重平衡

---

### 实验 7: 动态分区压测

**目的**: 在持续写入过程中注入网络分区，观测读写行为。

```bash
make experiment-07
```

**执行内容**: 后台持续写入 + 前端读取 → t=10s 隔离 region2 → t=25s 恢复

**预期输出**:
```
Phase 1 (正常 0-10s): 读写正常, 读约 200-300ms
Phase 2 (隔离 10-25s): 大部分请求继续成功, 可能出现短暂失败和秒级长尾
Phase 3 (恢复 25-30s): 立即恢复
```

---

### 实验 8: 时钟偏移实验

**目的**: 操纵系统时钟验证 HLC 的单调性保证和安全机制。需要 Docker 容器支持 `SYS_TIME` capability（已在 compose/base.yaml 中启用）。

**先决条件**: 基准集群已启动 (`make up`)

```bash
make experiment-08
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
make experiment-09
```

**执行内容**:
- region2 每 5 秒切换一次隔离/恢复，共 12 个周期 (120s)
- 后台持续写入 + 前端定时读取

**预期输出**:
| 观察项 | 结果 |
|--------|------|
| 隔离窗口写入 | 失败 |
| 查询延迟 | 震荡期间可能 TIMEOUT 或 P99 明显升高 |
| 震荡停止后 | 完全恢复，无级联故障 |

---

### 实验 10: TPC-C Benchmark

**目的**: 使用 go-tpc 测量 YugabyteDB 的 TPC-C 吞吐量和事务延迟。

```bash
make experiment-10
```

默认参数：10 warehouses、8 threads、5min duration。可覆盖：

```bash
make experiment-10 TPCC_WAREHOUSES=4 TPCC_THREADS=4 TPCC_DURATION=2m
```

---

### 实验 11: 扩展性测试

**目的**: 使用 pgbench 对比 1/3/5 节点吞吐量和延迟。

```bash
make experiment-11
```

默认参数：scale=1、16 clients、60s。可通过环境变量缩短调试：

```bash
PG_DURATION=15 NODE_COUNTS="1 3" bash scripts/experiment-11-scalability.sh
```

---

## 实验复现总览

| 实验 | 命令 | 所需环境 | 耗时 |
|------|------|---------|------|
| 1. 架构分析 | `make experiment-01` | 基准集群 | 1min |
| 2. 基准延迟 | `make experiment-02` | 基准集群 | 2min |
| 3. 延迟基准 | `make experiment-03` | 延迟集群 | 5min |
| 4. 故障切换 | `make experiment-04` | 延迟集群 | 2min |
| 5. WAN 模拟 | `make experiment-05` | 延迟集群 | 5min |
| 6. Asymmetric | `make experiment-06` | 延迟集群 | 2min |
| 7. 动态分区 | `make experiment-07` | 延迟集群 | 1min |
| 8. 时钟偏移 | `make experiment-08` | 基准集群 | 1min |
| 9. 震荡节点 | `make experiment-09` | 基准集群 | 3min |
| 10. TPC-C | `make experiment-10` | 基准集群 + go-tpc | 5-10min |
| 11. 扩展性 | `make experiment-11` | 基准集群 + pgbench | 3-5min |

**一键全跑**: `make experiment-all`（约 45-60min）

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
| 基准 | NET_DELAY_MS=1 | ~0ms | 64-68ms | 66-72ms | 64-68ms |
| 延迟 | NET_DELAY_MS=30 | 30-150ms | 97-227ms | 101-224ms | 104-226ms |

## 分布式数据库设计要点

**YugabyteDB vs Spanner / CockroachDB**:

| 维度 | YugabyteDB | Google Spanner | CockroachDB |
|------|-----------|---------------|-------------|
| 时钟 | HLC（无硬件依赖） | TrueTime（需 GPS+原子钟） | HLC（同左） |
| 共识 | Raft（自定义优化） | Paxos | Raft（同左） |
| Commit Wait | 无需 | 2×clock_uncertainty (1-7ms) | 无需 |
| 故障恢复 | ~0.5-1.5s (Raft) | ~5s (Paxos) | ~1s (Raft) |
| SQL 兼容 | PostgreSQL | GoogleSQL | PostgreSQL |

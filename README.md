# yblab — YugabyteDB 全球分布式数据库测评

在单机 Docker 上搭建 5 节点 RF=3 的 YugabyteDB 集群，通过 tc netem 模拟跨 region 网络延迟、iptables 模拟网络分区，完成完整的分布式数据库测评与混沌工程实验。

## 仓库结构

```
.
├── docker-compose.yaml          # 集群定义 (5 yb + pg + rfNready)
├── docker-compose.chaos.yaml    # 混沌工程控制器
├── docker-compose.bench.yaml    # 压测工具镜像构建
├── Dockerfile.pg                # 自定义 pg 镜像 (预装 pgbench)
├── Dockerfile.chaosctl          # 混沌控制器镜像
├── Makefile                     # 一键实验入口
├── .env                         # 基准环境配置 (NET_DELAY_MS=1)
├── .env.delay                   # 延迟环境配置 (NET_DELAY_MS=30)
├── README.md
├── 执行计划-YugabyteDB.md        # 完整实验计划
├── 实验结果汇总.md               # 实验结果
├── scripts/
│   ├── 01-setup-perf-test.sh    # 创建 perf_test 表并填充
│   ├── 02-latency-bench.py      # 跨节点延迟基准测试
│   ├── 03-consistency-test.sh   # 一致性级别 + 转账正确性
│   ├── 04-failover-test.sh      # 故障切换 RTO/RPO
│   ├── chaosctl                 # 混沌工程控制器 CLI
│   ├── chaos-bench.sh           # 动态分区压测脚本
│   └── run-all.sh               # 全自动实验脚本
└── sql/
    ├── 01-hlc-clock.sql         # HLC 时钟同步实验
    ├── 02-tablespaces.sql       # Geo-Partitioning 表空间
    └── 03-isolation-test.sql    # 隔离级别测试
```

## 所需 Docker 镜像

| 镜像 | 用途 | 来源 |
|------|------|------|
| `yugabytedb/yugabyte` | YugabyteDB 数据库节点 | Docker Hub (自动拉取) |
| `postgres:16` | 客户端工具 (psql, pgbench) | Docker Hub (自动拉取) |
| `caddy:2-alpine` | Web UI 反向代理 | Docker Hub (自动拉取) |
| `alpine:latest` | 轻量级网络测试容器 | Docker Hub (自动拉取) |
| `yb-compose-chaosctl` | 混沌工程控制器 | 本地构建 (`make chaos-build`) |

所有镜像中除了 `yb-compose-chaosctl` 需本地构建外，其余均在首次启动时自动拉取。

## 环境配置

### 1. 构建 chaosctl 镜像

```bash
# 首次使用前需构建混沌控制器镜像
make chaos-build
```

chaosctl 容器通过 Docker socket 向 yb 节点下发 iptables/tc 命令，无需在 yb 容器中预装 agent。

### 2. 选择环境配置

两个环境配置文件，通过 `--env-file` 切换：

| 文件 | NET_DELAY_MS | 节点延迟 | 用途 |
|------|-------------|---------|------|
| `.env` | 1 | ~0ms (基准) | 性能基线、功能验证 |
| `.env.delay` | 30 | 30/60/90/120/150ms | 跨 region 延迟模拟 |

所有 yb 节点使用同一 `NET_DELAY_MS` 值，实际延迟 = `NET_DELAY_MS × zone 编号`：
- region1 (yb-1): 1× 或 30ms egress
- region2 (yb-2): 2× 或 60ms egress
- region3 (yb-3): 3× 或 90ms egress
- region4 (yb-4): 4× 或 120ms egress
- region5 (yb-5): 5× 或 150ms egress

### 3. 启动集群

```bash
# 基准环境 (无延迟)
make up

# 或延迟环境 (30/60/90ms)
make up-delay
```

`make up` 会自动完成：启动 5 个 yb 容器 → 等待 rfNready（五节点全部就绪）→ 验证拓扑。

### 4. 验证环境

```bash
# 查看集群混沌状态 (节点/延迟/网络)
make chaos CMD="status"

# 预期输出: 5 nodes, 各节点显示对应延迟 (30/60/90/120/150ms), ysql accepting
```

## 快速开始

```bash
# 1. 启动基准集群 (5 节点, 无延迟)
make up

# 2. 或启动延迟环境 (region1=30ms, region2=60ms, region3=90ms, region4=120ms, region5=150ms)
make up-delay

# 3. 连接数据库
make psql

# 4. 运行全部实验
make bench

# 5. 在延迟环境下跑实验
make bench-delay

# 6. 混沌工程
make chaos CMD="status"                                    # 查看集群混沌状态
make chaos CMD="partition isolate region1"                 # 隔离节点 (网络分区)
make chaos CMD="partition isolate-input region2"           # 单向隔离 (只收不到)
make chaos CMD="partition heal all"                        # 恢复全部节点
make chaos CMD="delay set region2 100 5 1"                 # 动态设置延迟+丢包
make chaos CMD="scenario run network-partition region1 20" # 预设场景: 分区20s
make chaos CMD="scenario run cascading-failure"            # 预设场景: 级联故障

# 7. 关停清理
make clean
```

### 分步操作

```bash
# 完全清理旧环境
make clean

# 构建 chaosctl (首次或更新后)
make chaos-build

# 启动基准集群
make up

# 验证环境
make chaos CMD="status"

# 实验完成后清理
make clean
```

## 实验内容

### Phase 1: 环境搭建与验证
- 启动 5 节点 RF=3 集群
- 验证拓扑 (cloud.region{1..5}.zone)
- 验证复制因子 (RF=3)
- 验证延迟注入 (tc netem)

### Phase 2: 架构分析
- **HLC 时钟同步**: 对比各节点 `now()`
- **Raft 共识**: 查看 tablet leader/follower 分布
- **隔离级别**: 验证 Read Committed + 冲突事务
- **Geo-Partitioning**: 创建 region 表空间 + Leader Preference

### Phase 3: 基准测试
- **延迟对比**: 测量 5 个节点的读写延迟 (avg/P50/P99)
- **一致性**: 测试 leader_only / follower_read
- **正确性**: 并发转账 + 余额守恒验证

### Phase 4: 进阶实验
- **故障切换**: 停节点 → 测量 RTO/RPO
- **网络分区 (chaosctl)**: iptables 隔离节点（保留进程），对比与 docker stop 的 RTO 差异
- **分区下的一致性**: 验证多数派节点继续服务、被隔离节点自动防脑裂
- **级联故障**: 逐步失效至 1/3 节点，验证 Raft 容错边界

### Phase 5: 混沌工程 (chaosctl)
通过 `chaosctl` 在单机 Docker 环境中模拟真实网络故障：
- **网络分区**: 双向/单向 iptables DROP，保留进程运行
- **动态延迟**: 运行时修改 tc netem 参数（延迟/jitter/丢包率）
- **预设场景**: 自动化多步骤故障注入（分区→观测→恢复）
- **WAN 模拟**: 组合 jitter + loss + bandwidth 限制
- **动态分区压测**: 持续写入中注入网络分区

### 实验场景

#### 5 节点 WAN 模拟
在 5 节点集群上模拟不稳定的跨 region 网络：
- **Jitter + Loss**: region2 (60ms+20ms jitter+2% loss), region3 (90ms+30ms jitter+5% loss)
- **Bandwidth**: region4 (120ms+10mbit)
- **观测**: P99 在有损网络下呈现 6-8 倍增长（TCP 重传导致）

#### Asymmetric Delay
- 5 节点非均匀延迟 10/25/50/75/100ms
- Master leader 自动选择最低延迟节点
- Tablet leader 分布需配置 Leader Preference

#### 动态分区压测
- 后台持续写入 + 读取
- 中间隔离 region2，观测读写行为变化
- 恢复后验证集群收敛

## 延迟模拟原理

```yaml
# docker-compose.yaml 关键部分:
cap_add:
  - NET_ADMIN  # 允许修改网络队列

# 启动时注入 tc netem:
# NET_DELAY_MS=30, zone编号=1/2/3/4/5
# region1: tc qdisc add dev eth0 root netem delay 30ms
# region2: tc qdisc add dev eth0 root netem delay 60ms  
# region3: tc qdisc add dev eth0 root netem delay 90ms
# region4: tc qdisc add dev eth0 root netem delay 120ms
# region5: tc qdisc add dev eth0 root netem delay 150ms
```

各节点 egress 延迟通过 `tc netem` 注入，影响容器间出站流量。跨节点 RTT = 源节点 egress + 目标节点 egress。最大 RTT: region4 ↔ region5 = 270ms。

## Chaos Engineering

通过 `chaosctl` 混沌控制器，在单机 Docker 中用 iptables + tc 模拟真实的网络故障。

### 架构

```
┌──────────────────────────────────────────┐
│  chaosctl (Alpine 容器)                   │
│  ┌────────────────────────────────────┐  │
│  │  docker exec → yb-1: iptables/tc  │  │
│  │  docker exec → yb-2: iptables/tc  │  │
│  │  docker exec → yb-3: iptables/tc  │  │
│  └────────────────────────────────────┘  │
│  Volumes: /var/run/docker.sock           │
└──────────────────────────────────────────┘
```

chaosctl 通过 Docker socket 向各 yb 容器下发 iptables/tc 命令，无需在 yb 容器中预先安装任何 agent。iptables 在网络层面阻断流量，比 `docker stop` 更真实地模拟网络分区。

### 命令参考

| 命令 | 作用 |
|------|------|
| `chaosctl status` | 查看集群网络/延迟/进程状态 |
| `chaosctl partition isolate <node>` | 完全隔离节点（双向 DROP） |
| `chaosctl partition isolate-input <node>` | 只能发不能收 |
| `chaosctl partition isolate-output <node>` | 只能收不能发 |
| `chaosctl partition heal [node]` | 恢复节点（不指定=全部） |
| `chaosctl delay set <node> <ms> [jitter] [loss%]` | 动态设置延迟 |
| `chaosctl delay clear [node]` | 清除延迟 |
| `chaosctl scenario list` | 列出预设故障场景 |
| `chaosctl scenario run <name> [args]` | 运行预设场景 |

节点名支持 `region1` / `yb-1` / `yb-compose-yb-1` 三种写法。

### 预设场景

- **network-partition**: 隔离一个节点 N 秒，观测 Raft leader 重选举和集群恢复
- **asymmetric-delay**: 五个节点分别设置 10/25/50/75/100ms 延迟，观测 Leader Preference 效果
- **cascading-failure**: 依次隔离 region1 → region2，测试 RF=3 的容错极限

### 与 docker stop 的对比

| 故障模拟方式 | RTO | 适用场景 |
|-------------|-----|---------|
| `docker stop` | ~400ms | 进程级崩溃 |
| `iptables isolate` | ~987ms | 网络分区（真实生产场景） |

iptables 分区下，被隔离节点自动关闭 postgres 防止服务过期数据，确保无脑裂。

## 网络延迟对比

| 环境 | 配置 | 节点延迟 | 读 avg | 读 P50 | 写 avg |
|------|------|---------|--------|--------|--------|
| 基准 (3 节点) | NET_DELAY_MS=1 | ~0ms | 41ms | 40ms | 41ms |
| 延迟 (3 节点) | NET_DELAY_MS=30 | 30/60/90ms | 83-158ms | 82-150ms | 87-153ms |
| 延迟 (5 节点) | NET_DELAY_MS=30 | 30/60/90/120/150ms | 102-229ms | 106-229ms | 103-227ms |

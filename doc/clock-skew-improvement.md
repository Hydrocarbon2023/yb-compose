# 实验改进 — 时钟偏移 + 网络分区组合实验

## 1. 实验动机

YugabyteDB 使用 Hybrid Logical Clock (HLC) 在分布式节点间实现因果一致性。HLC 的核心保证是：

1. **单调递增**：即使物理时钟回退，HLC 也不会倒退
2. **因果有序**：happens-before 关系可通过 HLC 比较
3. **物理近似**：HLC 值接近物理时钟，偏差有界

现有实验（`01-hlc-clock.sql`）仅观测了正常状态下各节点 `now()` 的差异，未验证 HLC 在时钟异常场景下的行为。本实验通过主动操纵容器系统时钟 + 网络分区，验证 HLC 的单调性保证和分区下的共识行为。

## 2. 实验设计

### 2.1 前置条件

| 条件 | 说明 |
|------|------|
| `SYS_TIME` capability | 容器内 `date -s` 修改系统时钟需要此权限 |
| `NET_ADMIN` capability | 已有，用于 iptables/tc |
| `--privileged` docker exec | 时钟修改需要特权模式 |
| 5 节点集群运行中 | `make up` 或 `make up-delay` |

### 2.2 实验步骤

```
Step 1: Baseline     → 查询所有节点 HLC + now()
Step 2: Forward jump → yb-5 时钟快进 +500ms
Step 3: Observe      → HLC 是否跟随跳变
Step 4: Backward jump→ yb-5 时钟回退 -1000ms (模拟 NTP 修正)
Step 5: Observe      → HLC 是否拒绝回退 (单调性)
Step 6: Partition    → 隔离 yb-5 (iptables DROP)
Step 7: Write test   → 分区内写入 (预期失败: 无共识)
Step 8: HLC query    → 分区内查询 HLC
Step 9: Heal         → 恢复网络
Step 10: Verify      → 集群恢复确认
```

### 2.3 关键观测点

| 步骤 | 观测 | 预期结果 |
|------|------|---------|
| Step 2→3 | HLC 对时钟快进的响应 | HLC 跟随物理时钟前跳 |
| Step 4→5 | HLC 对时钟回退的响应 | HLC 保持单调递增，不回退 |
| Step 7 | 分区内写入 | 失败（无法达成 Raft 多数派） |
| Step 8 | 分区内 HLC | HLC 继续递增（逻辑计数器推进） |
| Step 10 | 恢复后集群状态 | 所有节点在线，HLC 正常 |

## 3. 技术实现

### 3.1 时钟操纵

使用 `docker exec --privileged <node> date -s "<offset>"` 修改容器系统时钟：

- `date -s "+500 milliseconds"` — 快进 500ms
- `date -s "-1000 milliseconds"` — 回退 1000ms

需要 `SYS_TIME` Linux capability（已添加到 compose/base.yaml 的 yb-default 模板）。

### 3.2 HLC 查询

```sql
-- 查询当前节点的 HLC 值
SELECT yb_get_current_hybrid_time();

-- 查询 PostgreSQL 当前时间
SELECT now()::timestamptz(6);
```

`yb_get_current_hybrid_time()` 返回一个 64 位混合逻辑时间戳，高 48 位为物理时间（微秒），低 16 位为逻辑计数器。

### 3.3 网络分区

复用现有 chaosctl 基础设施：

```bash
make chaos CMD="partition isolate yb-5"   # 隔离
make chaos CMD="partition heal yb-5"      # 恢复
```

### 3.4 为什么选择 yb-5

- yb-5 是 tserver-only 节点（无 master），分区后不影响 master 仲裁
- yb-5 延迟最高（150ms egress），最接近真实 WAN 场景
- yb-5 位于 region5，地理上最"远"

## 4. Docker Compose 修改

在 `yb-default` 服务模板中添加 `SYS_TIME` capability：

```yaml
cap_add:
  - NET_ADMIN
  - SYS_TIME    # 允许容器内 date -s 修改系统时钟
```

此修改影响所有 5 个 yb 节点（均继承 yb-default 模板），确保任意节点均可进行时钟操纵实验。

## 5. 运行方式

```bash
# 1. 重建集群（使 SYS_TIME 生效）
make clean && make up

# 2. 运行实验
bash scripts/06-clock-skew-partition.sh

# 3. 或在延迟环境下运行
make clean && make up-delay
bash scripts/06-clock-skew-partition.sh
```

## 6. 预期实验结果

### 6.1 时钟快进

yb-5 时钟快进 500ms 后，`now()` 立即反映新时间，`yb_get_current_hybrid_time()` 也会跳变到更高值。HLC 的物理部分跟随系统时钟。

### 6.2 时钟回退

yb-5 时钟回退 1000ms 后，`now()` 反映旧时间，但 `yb_get_current_hybrid_time()` **不会回退**。HLC 通过逻辑计数器保持单调递增——即使物理时钟回退，逻辑部分 +1 确保整体值递增。

### 6.3 分区写入

隔离 yb-5 后，从 yb-5 内部写入数据会失败。RF=3 需要 2 个副本确认，但 yb-5 无法联系其他节点，无法达成多数派共识。

### 6.4 分区 HLC

分区期间 yb-5 的 HLC 仍可查询且继续递增（逻辑计数器推进），但此 HLC 值与集群其他节点不同步。

### 6.5 恢复

网络恢复后，yb-5 重新加入集群，HLC 通过 Raft 通信重新同步，集群恢复正常服务。

## 7. 与现有实验的关系

| 实验 | 内容 | 本实验的扩展 |
|------|------|-------------|
| `01-hlc-clock.sql` | 静态观测 now() 差异 | 主动操纵时钟，验证 HLC 单调性 |
| `04-failover-test.sh` | 进程级故障切换 | 网络分区 + 时钟异常的组合故障 |
| `chaos-bench.sh` | 分区下压测 | 分区下 HLC 行为观测 |

本实验填补了"时钟异常"这一维度的测试空白，是混沌工程实验的重要补充。

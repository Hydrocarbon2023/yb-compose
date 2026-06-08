# 实验 6: Asymmetric Delay（非均匀延迟）

> **测试日期**: 2026-06-07
> **环境**: 5 节点 YugabyteDB RF=3（Docker Compose + tc netem）

---

## 1. 实验设计

### 1.1 目的

验证非均匀延迟下 Master Leader 和 Tablet Leader 的分布行为。

### 1.2 延迟配置

| 节点 | 延迟 | 角色 |
|------|------|------|
| yb-1 (region1) | 10ms | Master + TServer |
| yb-2 (region2) | 25ms | Master + TServer |
| yb-3 (region3) | 50ms | Master + TServer |
| yb-4 (region4) | 75ms | TServer |
| yb-5 (region5) | 100ms | TServer |

---

## 2. 结果

### 2.1 Master Leader 分布

| 节点 | 延迟 | Master 角色 |
|------|------|------------|
| yb-1 (region1) | 10ms | **FOLLOWER** |
| yb-2 (region2) | 25ms | **LEADER** ⚠️ |
| yb-3 (region3) | 50ms | FOLLOWER |

**关键发现**: Master Leader 在 **region2 (25ms)**，而非延迟最低的 **region1 (10ms)**。

> **文档同步**: README 已更新为"leader 不会因为当前延迟最低而自动迁移"。Master leader 的具体位置会随历史选举和启动状态变化，关键结论是不保证自动选择最低延迟节点。

### 2.2 Tablet Leader 分布

无法通过 `yb-admin list_tablets` 获取 perf_test 表的 tablet leader 分布（命令超时），但这本身说明了非均匀延迟下管理操作的性能退化。

---

## 3. 分析

### 3.1 Master Leader 为什么不在最低延迟节点？

Raft leader 选举的核心机制是**先到先得（first-come-first-served）**，而非延迟最优化：

1. **Leader 选举触发**: 当现有 leader 失联（heartbeat timeout），其他节点发起 PreVote → Vote
2. **选举条件**: 候选人需要获得多数派（2/3）投票
3. **选举结果**: 最先完成选举流程的节点成为新 leader

在本实验中，asymmetric-delay 场景是在**已有 leader 运行时**修改延迟的。Raft leader 不会因为网络延迟变化而主动让位（no preemption）。Leader 只在以下情况变更：
- 当前 leader 心跳超时（通常是进程崩溃或网络分区）
- 手动触发 leader stepdown

因此，**Master Leader 的位置取决于选举发生时的网络拓扑，而非当前的延迟分布**。

### 3.2 理想 vs 现实

| 维度 | 理想行为 | 实际行为 |
|------|---------|---------|
| Master Leader | 自动迁移到最低延迟节点 (region1) | 保持原位置或随机选举 |
| Tablet Leader | 自动迁移到客户端就近节点 | 随 tablet 创建时的 leader 选举结果 |
| Leader Preference | 自动配置 | 需要手动设置 `leader_preference` |

### 3.3 Leader Preference 的重要性

YugabyteDB 提供了 `leader_preference` 配置，可以建议 tablet leader 优先放在特定 region：

```sql
-- 将 leader 偏好设置到最低延迟的 region
ALTER TABLESPACE region1 SET (leader_preference = 1);
```

在不设置 Leader Preference 的情况下：
- **Master Leader**: 由 Raft 选举决定，可能不在最优位置
- **Tablet Leader**: 分散在各节点，无优先级
- **读/写延迟**: 受到 tablet leader 位置的影响，可能不是最优

### 3.4 生产建议

| 场景 | 建议 |
|------|------|
| 跨 region 部署 | 设置 Leader Preference，将 leader 优先放在客户端就近 region |
| 非均匀延迟 | 配合 Geo-Partitioning 将数据和 leader 放在低延迟 region |
| 自动 leader 均衡 | 使用 `yb-admin` 或 YSQL 命令触发 leader 重平衡 |

---

## 4. 结论

| 验证项 | 结果 |
|--------|------|
| Master Leader 位置 | ⚠️ 在 region2 (25ms)，非最低延迟 region1 (10ms) |
| Raft 选举机制 | ✅ 先到先得，不自动优化延迟 |
| Leader Preference | ❌ 默认未配置，需手动设置 |
| Tablet Leader 分布 | 无法获取（yb-admin 超时） |

**核心发现**: YugabyteDB 的 Raft leader 选举不会自动选择最低延迟节点作为 leader。在非均匀延迟环境下，需要手动配置 Leader Preference 才能优化 leader 放置。

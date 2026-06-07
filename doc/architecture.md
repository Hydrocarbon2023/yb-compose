
## 2.x 全球分布式数据库调研及测评

### · 总览

全球分布式数据库是分布式数据库的进一步演进，其节点跨越多个地理区域（如北美、欧洲、亚洲），需要在**跨洲级别的网络延迟**（100~300ms）下仍然保证强一致性与高可用性。Google Spanner 是该领域的奠基之作（OSDI 2012），此后涌现了一批受其启发的开源系统。

本题目从以下两个开源系统中选择进行调研与测评：

- **YugabyteDB**：同时支持 YSQL（PostgreSQL 兼容）和 YCQL（Cassandra 兼容），采用 Raft + MVCC

开源链接：

- YugabyteDB：https://github.com/yugabyte/yugabyte-db

---

### · 整体架构

研究全球分布式数据库，主要关注以下几点：

**时钟同步机制**：全球节点的物理时钟存在偏差，系统如何保证事件的全局顺序？（如 Spanner 的 TrueTime、CockroachDB 的 HLC）

**共识协议**：跨地区副本之间如何达成一致？Multi-Paxos 与 Raft 在高延迟网络下的表现差异

**并发控制**：如何在全球范围内实现 MVCC，读写事务分别采用什么策略（参考 Spanner 的 Commit Wait 机制）

**数据分区与就近读**：数据如何按地理位置划分（Geo-Partitioning），如何让用户尽可能从最近的副本读取数据

---

### · 测评

测评维度建议从以下角度展开：

**延迟对比**：单机房部署 vs 模拟跨区域部署（通过 `tc netem` 注入网络延迟）下，读写事务的平均延迟与尾延迟（P99）

**吞吐量**：使用 TPC-C Benchmark（推荐工具：BenchmarkSQL 或 go-tpc），测试不同并发线程数下的 tpmC 指标

**一致性开销**：对比强一致性读（Linearizable Read）与弱一致性读（Stale Read）的延迟差异，量化一致性为性能带来的代价

**扩展性**：增加节点数量时，系统吞吐量是否线性增长

---

### · 进阶要求

**跨区域 Commit Wait 开销量化**：在模拟多区域延迟环境下，实测读写事务中等待时钟不确定性消除所耗费的时间占比，与 Spanner 论文中的理论分析进行对比

**正确性验证**：使用 Jepsen 框架或自行构造并发场景（如写后读、跨节点转账），验证系统在节点故障、网络分区时是否仍满足外部一致性（External Consistency）

**自动故障切换测试**：模拟某个"地区"节点全部下线，测量系统从故障检测到恢复可用的时间（RTO），以及数据是否有丢失（RPO）

---

### · 参考

- [1] Spanner 原论文：https://www.usenix.org/conference/osdi12/technical-sessions/presentation/corbett
- [2] CockroachDB 设计文档：https://www.cockroachlabs.com/docs/stable/architecture/overview
- [3] YugabyteDB 架构：https://docs.yugabyte.com/preview/architecture/
- [4] TPC-C Benchmark 工具 go-tpc：https://github.com/pingcap/go-tpc
- [5] Jepsen 一致性测试框架：https://jepsen.io/

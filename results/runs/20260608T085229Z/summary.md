# Experiment Run Summary

- Run ID: `20260608T085229Z`
- Generated at: `2026-06-08T09:36:56Z`

| Target | Status | Duration | Key Metrics | Log |
|---|---:|---:|---|---|
| `clean` | PASS | 1s | - | [clean/output.log](clean/output.log) |
| `experiment-01` | PASS | 3s | - | [experiment-01/output.log](experiment-01/output.log) |
| `experiment-02` | PASS | 76s | ║ yb-1 │ 90.70 │ 88.74 ║;║ yb-2 │ 93.10 │ 88.51 ║;║ yb-3 │ 87.14 │ 87.52 ║;║ yb-4 │ 88.80 │ 91.11 ║;║ yb-5 │ 89.79 │ 91.27 ║; | [experiment-02/output.log](experiment-02/output.log) |
| `experiment-03` | PASS | 297s | ║ yb-1 │ 30ms │ 129.10 │ 126.76 │ 90.124-270.125ms ║;║ yb-2 │ 60ms │ 160.08 │ 156.53 │ 90.124-270.125ms ║;║ yb-3 │ 90ms │ 189.08 │ 187.60 │ 90.124-270.125ms ║;║ yb-4 │ 120ms │ 222.36 │ 219.07 │ 90.124-270.125ms ║;║ yb-5 │ 150ms │ 251.40 │ 246.73 │ 90.124-270.125ms ║; | [experiment-03/output.log](experiment-03/output.log) |
| `experiment-04` | PASS | 32s | ║ 场景 A: docker stop \| 场景 B: iptables 分区 ║;=== 场景 A: docker stop 故障切换 ===; Step A3: 停止 yb-4 (docker stop);║ docker stop (进程崩溃) │ 534ms ║;║ iptables 分区 (total) │ 7137ms ║;║ iptables 分区 (net) │ 615ms ║; - docker stop: 进程立即终止, YB-Master 快速检测并触发 leader 选举; - iptables 分区: 依赖心跳超时 (默认 500ms), 检测延迟 + 选举延迟; | [experiment-04/output.log](experiment-04/output.log) |
| `experiment-05` | PASS | 27s | - | [experiment-05/output.log](experiment-05/output.log) |
| `experiment-06` | PASS | 56s | - | [experiment-06/output.log](experiment-06/output.log) |
| `experiment-07` | PASS | 73s | - | [experiment-07/output.log](experiment-07/output.log) |
| `experiment-08` | PASS | 145s | - | [experiment-08/output.log](experiment-08/output.log) |
| `experiment-09` | PASS | 299s | - | [experiment-09/output.log](experiment-09/output.log) |
| `experiment-10` | PASS | 355s |  tpmC=15196.0 tpmTotal=33774.6 Efficiency=11816.5% | [experiment-10/output.log](experiment-10/output.log) |
| `experiment-11` | PASS | 308s |  N=5: TPS = 479.521206, Avg Latency = 33.367 ms; N=3: TPS = 438.957364, Avg Latency = 36.450 ms; N=1: TPS = 775.854846, Avg Latency = 20.622 ms; | [experiment-11/output.log](experiment-11/output.log) |

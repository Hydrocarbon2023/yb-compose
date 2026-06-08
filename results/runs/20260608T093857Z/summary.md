# Experiment Run Summary

- Run ID: `20260608T093857Z`
- Generated at: `2026-06-08T10:05:57Z`

| Target | Status | Duration | Key Metrics | Log |
|---|---:|---:|---|---|
| `clean` | PASS | 1s | - | [clean/output.log](clean/output.log) |
| `experiment-01` | PASS | 4s | - | [experiment-01/output.log](experiment-01/output.log) |
| `experiment-02` | PASS | 76s | ║ yb-1 │ 90.09 │ 90.16 ║;║ yb-2 │ 88.22 │ 93.06 ║;║ yb-3 │ 93.53 │ 88.01 ║;║ yb-4 │ 88.96 │ 87.02 ║;║ yb-5 │ 88.52 │ 89.22 ║; | [experiment-02/output.log](experiment-02/output.log) |
| `experiment-03` | PASS | 288s | ║ yb-1 │ 30ms │ 128.87 │ 127.28 │ 90.100-270.146ms ║;║ yb-2 │ 60ms │ 162.72 │ 156.48 │ 90.100-270.146ms ║;║ yb-3 │ 90ms │ 187.64 │ 187.80 │ 90.100-270.146ms ║;║ yb-4 │ 120ms │ 219.44 │ 216.84 │ 90.100-270.146ms ║;║ yb-5 │ 150ms │ 249.61 │ 248.89 │ 90.100-270.146ms ║; | [experiment-03/output.log](experiment-03/output.log) |
| `experiment-04` | PASS | 32s | ║ 场景 A: docker stop \| 场景 B: iptables 分区 ║;=== 场景 A: docker stop 故障切换 ===; Step A3: 停止 yb-4 (docker stop);║ docker stop (进程崩溃) │ 481ms ║;║ iptables 分区 (total) │ 6936ms ║;║ iptables 分区 (net) │ 478ms ║; - docker stop: 进程立即终止, YB-Master 快速检测并触发 leader 选举; - iptables 分区: 依赖心跳超时 (默认 500ms), 检测延迟 + 选举延迟; | [experiment-04/output.log](experiment-04/output.log) |
| `experiment-05` | PASS | 27s | - | [experiment-05/output.log](experiment-05/output.log) |
| `experiment-06` | PASS | 57s | - | [experiment-06/output.log](experiment-06/output.log) |
| `experiment-07` | PASS | 61s | - | [experiment-07/output.log](experiment-07/output.log) |
| `experiment-08` | PASS | 113s | - | [experiment-08/output.log](experiment-08/output.log) |
| `experiment-09` | PASS | 294s | - | [experiment-09/output.log](experiment-09/output.log) |
| `experiment-10` | PASS | 356s |  tpmC=14864.4 tpmTotal=32963.8 Efficiency=11558.6% | [experiment-10/output.log](experiment-10/output.log) |
| `experiment-11` | PASS | 307s |  N=5: TPS = 476.374222, Avg Latency = 33.587 ms; N=3: TPS = 482.147573, Avg Latency = 33.185 ms; N=1: TPS = 796.012952, Avg Latency = 20.100 ms; | [experiment-11/output.log](experiment-11/output.log) |

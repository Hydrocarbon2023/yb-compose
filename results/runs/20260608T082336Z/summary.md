# Experiment Run Summary

- Run ID: `20260608T082336Z`
- Generated at: `2026-06-08T08:51:03Z`

| Target | Status | Duration | Key Metrics | Log |
|---|---:|---:|---|---|
| `clean` | PASS | 1s | - | [clean/output.log](clean/output.log) |
| `experiment-01` | PASS | 3s | - | [experiment-01/output.log](experiment-01/output.log) |
| `experiment-02` | PASS | 76s | ║ yb-1 │ 88.53 │ 90.39 ║;║ yb-2 │ 91.92 │ 94.25 ║;║ yb-3 │ 90.18 │ 92.64 ║;║ yb-4 │ 86.06 │ 88.79 ║;║ yb-5 │ 89.25 │ 90.41 ║; | [experiment-02/output.log](experiment-02/output.log) |
| `experiment-03` | PASS | 324s | ║ yb-1 │ 30ms │ 126.97 │ 127.41 │ 90.128-270.165ms ║;║ yb-2 │ 60ms │ 158.11 │ 154.57 │ 90.128-270.165ms ║;║ yb-3 │ 90ms │ 190.55 │ 188.29 │ 90.128-270.165ms ║;║ yb-4 │ 120ms │ 222.22 │ 220.90 │ 90.128-270.165ms ║;║ yb-5 │ 150ms │ 248.48 │ 248.11 │ 90.128-270.165ms ║; | [experiment-03/output.log](experiment-03/output.log) |
| `experiment-04` | PASS | 32s | ║ 场景 A: docker stop \| 场景 B: iptables 分区 ║;=== 场景 A: docker stop 故障切换 ===; Step A3: 停止 yb-4 (docker stop);║ docker stop (进程崩溃) │ 486ms ║;║ iptables 分区 (total) │ 7150ms ║;║ iptables 分区 (net) │ 514ms ║; - docker stop: 进程立即终止, YB-Master 快速检测并触发 leader 选举; - iptables 分区: 依赖心跳超时 (默认 500ms), 检测延迟 + 选举延迟; | [experiment-04/output.log](experiment-04/output.log) |
| `experiment-05` | PASS | 31s | - | [experiment-05/output.log](experiment-05/output.log) |
| `experiment-06` | PASS | 60s | - | [experiment-06/output.log](experiment-06/output.log) |
| `experiment-07` | PASS | 73s | - | [experiment-07/output.log](experiment-07/output.log) |
| `experiment-08` | PASS | 114s | - | [experiment-08/output.log](experiment-08/output.log) |
| `experiment-09` | PASS | 268s | - | [experiment-09/output.log](experiment-09/output.log) |
| `experiment-10` | PASS | 355s |  tpmC=14784.6 tpmTotal=32706.6 Efficiency=11496.6% | [experiment-10/output.log](experiment-10/output.log) |
| `experiment-11` | PASS | 307s | [32m N=5: TPS = 494.285445, Avg Latency = 32.370 ms[0m;[32m N=3: TPS = 435.436326, Avg Latency = 36.745 ms[0m;[32m N=1: TPS = 808.654738, Avg Latency = 19.786 ms[0m; | [experiment-11/output.log](experiment-11/output.log) |

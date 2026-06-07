#!/usr/bin/env python3
"""
Phase 3.1 - 延迟对比实验
从容器网络内测量各节点的读写延迟，反映真实的跨节点网络延迟。

用法:
  ./scripts/02-latency-bench.py [--host yb-compose-yb-1] [--iter 50]
"""
import subprocess, random, time, sys, argparse, json, os

CLIENT_IMAGE = "alpine:latest"
CLIENT_NAME = f"yb-latency-client-{os.getpid()}"

def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)

def start_client():
    run(["docker", "run", "-d", "--name", CLIENT_NAME,
         "--network", "yb-compose_default", CLIENT_IMAGE, "sleep", "3600"],
        timeout=30)
    # install psql
    run(["docker", "exec", CLIENT_NAME, "apk", "add", "--no-cache",
         "postgresql-client"], timeout=60)

def stop_client():
    run(["docker", "rm", "-f", CLIENT_NAME], timeout=10)

def measure(host, op, n):
    results = []
    for i in range(n):
        t0 = time.time_ns()
        if op == "read":
            rid = random.randint(1, 10000)
            r = run(["docker", "exec", CLIENT_NAME, "psql",
                     "-h", host, "-U", "yugabyte", "-tAc",
                     f"SELECT * FROM perf_test WHERE id = {rid}"], timeout=30)
        else:
            r = run(["docker", "exec", CLIENT_NAME, "psql",
                     "-h", host, "-U", "yugabyte", "-tAc",
                     "INSERT INTO perf_test (data) VALUES (repeat('x', 256))"],
                    timeout=30)
        t1 = time.time_ns()
        results.append((t1 - t0) / 1_000_000)
    results.sort()
    avg = sum(results) / len(results)
    p50 = results[len(results)//2]
    p99 = results[int(len(results)*0.99)]
    return {"avg_ms": round(avg, 2), "p50_ms": round(p50, 2), "p99_ms": round(p99, 2)}

def main():
    parser = argparse.ArgumentParser(description="YB latency benchmark")
    parser.add_argument("--iter", type=int, default=50, help="iterations per test")
    args = parser.parse_args()

    print(f"Starting latency benchmark ({args.iter} iterations per test)...")
    start_client()

    try:
        # 确保 perf_test 存在
        r = run(["docker", "exec", CLIENT_NAME, "psql",
                 "-h", "yb-1", "-U", "yugabyte", "-tAc",
                 "SELECT count(*) FROM perf_test"], timeout=10)
        if "0" in r.stdout.strip():
            print("WARNING: perf_test table is empty. Run scripts/01-setup-perf-test.sh first.")

        hosts = {
            "region1 (30ms egress)":  "yb-1",
            "region2 (60ms egress)":  "yb-2",
            "region3 (90ms egress)":  "yb-3",
            "region4 (120ms egress)": "yb-4",
            "region5 (150ms egress)": "yb-5",
        }

        all_results = {}
        for label, host in hosts.items():
            print(f"\n=== {label} ===")
            for op in ["read", "write"]:
                r = measure(host, op, args.iter)
                print(f"  {op.upper()}: avg={r['avg_ms']}ms  P50={r['p50_ms']}ms  P99={r['p99_ms']}ms")
                all_results[f"{host}_{op}"] = r

        # 输出 JSON
        print("\n=== JSON ===")
        print(json.dumps(all_results, indent=2))
    finally:
        stop_client()

if __name__ == "__main__":
    main()

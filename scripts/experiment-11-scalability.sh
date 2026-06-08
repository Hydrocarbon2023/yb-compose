#!/bin/bash
# ============================================================================
# Experiment 11: 扩展性测试
#
# 目的: 对比 1/3/5 节点的扩展性, 使用 pgbench (TPC-B) 测量吞吐量
#       - 验证线性扩展: 5 nodes ≈ 5× throughput of 1 node
#
# 用法:
#   bash scripts/experiment-11-scalability.sh
#
# 所需环境: Docker + docker compose
# 耗时: ~3-5min (取决于 pgbench 运行时间)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Configuration ─────────────────────────────────────────────────────
read -r -a NODE_COUNTS <<< "${NODE_COUNTS:-5 3 1}"
PG_CLIENTS="${PG_CLIENTS:-16}"
PG_DURATION="${PG_DURATION:-60}"
PG_SCALE="${PG_SCALE:-1}"

declare -A TPS_RESULTS=()
declare -A LATENCY_RESULTS=()

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

cd "$PROJECT_ROOT"

# ── Cleanup ──────────────────────────────────────────────────────
NETWORK_NAME="yb-compose_default"
cleanup() {
    echo "  清理 Docker 资源..."
    docker compose -p yb-compose -f compose/base.yaml -f compose/bench.yaml down -v --remove-orphans 2>/dev/null || true
    docker network rm "$NETWORK_NAME" 2>/dev/null || true
}
trap cleanup EXIT ERR INT TERM

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Experiment 11: 扩展性测试 (Scalability)                 ║"
echo "║     测试节点数: ${NODE_COUNTS[*]}                                    ║"
echo "║     pgbench: $PG_CLIENTS clients, ${PG_DURATION}s, scale=$PG_SCALE          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================
# Step 1: Build pgbench image
# ============================================================
echo "=== Step 1: 构建 pgbench 镜像 ==="
docker compose -p yb-compose -f compose/base.yaml -f compose/bench.yaml build pg 2>&1 | tail -3
green "  镜像就绪"
echo ""

BENCH_RUN="docker compose -p yb-compose -f compose/base.yaml -f compose/bench.yaml run --rm -T pg"
COMPOSE="docker compose -p yb-compose -f compose/base.yaml"

# ============================================================
# Step 2: Iterate over node counts
# ============================================================
for N in "${NODE_COUNTS[@]}"; do
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Testing with N=$N node(s)                                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Clean up previous run (remove containers, volumes, orphans, and network)
    echo "  清理环境..."
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
    docker network rm "$NETWORK_NAME" 2>/dev/null || true
    sleep 3

    # Build node list
    NODE_LIST=""
    for i in $(seq 1 "$N"); do
        NODE_LIST="$NODE_LIST yb-$i"
    done
    NODE_LIST="${NODE_LIST# }"
    echo "  启动节点: $NODE_LIST"

    # Start
    $COMPOSE up -d $NODE_LIST 2>&1 | tail -5

    # Wait for pg_isready on all nodes
    echo "  等待节点就绪..."
    ALL_READY=false
    for try in $(seq 1 120); do
        ready_count=0
        for i in $(seq 1 "$N"); do
            $COMPOSE exec -T "yb-$i" bash -c 'postgres/bin/pg_isready -h $(hostname) -p 5433' 2>/dev/null \
                && ready_count=$((ready_count + 1)) || true
        done
        if [ "$ready_count" -eq "$N" ]; then
            ALL_READY=true
            echo "  所有 $N 节点就绪 ($try s)"
            break
        fi
        sleep 1
    done

    if [ "$ALL_READY" = false ]; then
        red "  ✗ 节点未就绪"
        continue
    fi

    # Wait for YB-Master registration
    sleep 5
    for try in $(seq 1 30); do
        registered=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
            "SELECT count(*) FROM yb_servers();" 2>/dev/null | tr -d '[:space:]' || echo "0")
        if [ "${registered:-0}" -ge "$N" ]; then
            echo "  YB-Master 可见 $registered 节点"
            break
        fi
        sleep 2
    done

    # Show topology
    echo "  集群拓扑:"
    $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c \
        "SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;" 2>/dev/null || true
    echo ""

    # Initialize pgbench
    echo "  初始化 pgbench (scale=$PG_SCALE)..."
    $BENCH_RUN "
        PGHOST=yb-1 PGPORT=5433 PGUSER=yugabyte
        dropdb --if-exists pgbench 2>&1
        createdb pgbench 2>&1
        pgbench -i -s $PG_SCALE pgbench 2>&1
    " 2>&1 | tail -3
    echo ""

    # Run pgbench
    echo "  运行 pgbench ($PG_CLIENTS clients, ${PG_DURATION}s)..."
    BENCH_OUTPUT=$($BENCH_RUN "
        PGHOST=yb-1 PGPORT=5433 PGUSER=yugabyte
        pgbench -c $PG_CLIENTS -j $PG_CLIENTS -T $PG_DURATION pgbench
    " 2>&1)

    # Parse results
    TPS=$(echo "$BENCH_OUTPUT" | grep -oE 'tps = [0-9.]+' | grep -oE '[0-9.]+' | head -1 || echo "0")
    LATENCY=$(echo "$BENCH_OUTPUT" | grep -oE 'latency average = [0-9.]+' | grep -oE '[0-9.]+' | head -1 || echo "0")

    TPS_RESULTS[$N]="${TPS:-0}"
    LATENCY_RESULTS[$N]="${LATENCY:-0}"

    echo ""
    green "  N=$N: TPS = ${TPS_RESULTS[$N]}, Avg Latency = ${LATENCY_RESULTS[$N]} ms"
    echo "$BENCH_OUTPUT" | tail -8
    echo ""

done

# ============================================================
# Step 3: Final cleanup
# ============================================================
echo "=== 清理环境 ==="
$COMPOSE down -v --remove-orphans 2>/dev/null || true
docker network rm "$NETWORK_NAME" 2>/dev/null || true
sleep 2
echo ""

# ============================================================
# Summary
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              SCALABILITY TEST SUMMARY                        ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-10s │ %-12s │ %-12s │ %-14s ║\n" "Nodes" "TPS" "Latency(ms)" "Scale Factor"
echo "╠══════════════════════════════════════════════════════════════╣"

BASE_TPS=""
for N in "${NODE_COUNTS[@]}"; do
    tps="${TPS_RESULTS[$N]}"
    lat="${LATENCY_RESULTS[$N]}"

    if [ -z "$BASE_TPS" ] && [ "$tps" != "0" ] && [ "$tps" != "" ]; then
        BASE_TPS="$tps"
        scale_factor="1.00×"
    elif [ -n "$BASE_TPS" ] && [ "$tps" != "0" ] && [ "$tps" != "" ] && [ "$BASE_TPS" != "0" ]; then
        ratio=$(python3 -c "print(round($tps / $BASE_TPS, 2))" 2>/dev/null || echo "N/A")
        scale_factor="${ratio}×"
    else
        scale_factor="N/A"
    fi

    printf "║  %-10s │ %-12s │ %-12s │ %-14s ║\n" "$N" "$tps" "$lat" "$scale_factor"
done

echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "  线性扩展分析:"
echo "  - 实际扩展系数见 'Scale Factor' 列，不预设增加节点一定提升吞吐量"
echo "  - 小数据集、单入口和 RF 差异会让 Raft/协调开销主导结果"
echo "  - 按 doc_test 历史结果，N=3/N=5 的 TPS 可能低于 N=1"
echo ""

echo "  影响扩展性的因素:"
echo "  1. Raft 共识开销: 每次写入需多数派确认"
echo "  2. Tablet Leader 分布: 可能导致热点"
echo "  3. 网络延迟: 跨节点 RTT (无延迟环境下影响极小)"
echo "  4. Docker 资源竞争: 同主机容器 CPU 争用"
echo ""

green "Experiment 11 完成."

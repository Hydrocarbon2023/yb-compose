#!/bin/bash
# ============================================================================
# Experiment 02: 基准延迟测试
#
# 目的: 无延迟环境下的 5 节点读写延迟基线测量
#
# 用法:
#   bash scripts/experiment-02-baseline-latency.sh [--iter N]
#
#   默认迭代 50 次/节点/操作类型
#
# 所需环境: 自动启动基准集群 (无延迟)
# 耗时: ~2min
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"

COMPOSE="docker compose -p yb-compose -f compose/base.yaml"

# Default config
ITERATIONS=50
declare -A LATENCY_READ=()
declare -A LATENCY_WRITE=()

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
cyan()   { echo -e "\033[36m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iter) ITERATIONS="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# Cleanup
CLIENT_NAME="yb-latency-client-$$"
NETWORK_NAME="yb-compose_default"
cleanup() {
    docker rm -f "$CLIENT_NAME" 2>/dev/null || true
}
trap cleanup EXIT

cd "$PROJECT_ROOT"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Experiment 02: 基准延迟测试 (无延迟环境)                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  迭代次数/节点/操作: $ITERATIONS"
echo ""

# ============================================================
# Step 1: 启动基准集群
# ============================================================
echo "=== Step 1: 启动基准集群 ==="
$COMPOSE up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 rfNready 2>&1 | tail -5
wait_for_cluster "$COMPOSE" yb-1 5 240
green "  集群已就绪"
echo ""

# ============================================================
# Step 2: 创建测试表并填充数据
# ============================================================
echo "=== Step 2: 创建 perf_test 表 ==="
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
CREATE TABLE IF NOT EXISTS perf_test (
    id         BIGSERIAL PRIMARY KEY,
    data       TEXT      DEFAULT repeat('x', 256),
    created_at TIMESTAMPTZ DEFAULT now()
);
" 2>/dev/null

ROW_COUNT=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM perf_test;" 2>/dev/null | tr -d '[:space:]')
if [ "${ROW_COUNT:-0}" -lt 10000 ]; then
    echo "  填充 10000 行数据..."
    $COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
    INSERT INTO perf_test (data)
    SELECT repeat('x', 256) FROM generate_series(1, 10000)
    ON CONFLICT DO NOTHING;
    " 2>/dev/null
fi

ROW_COUNT=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM perf_test;" 2>/dev/null | tr -d '[:space:]')
green "  perf_test 就绪 ($ROW_COUNT 行)"
echo ""

# ============================================================
# Step 3: 启动 PostgreSQL 压测客户端
# ============================================================
echo "=== Step 3: 启动压测客户端 ==="
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    yellow "  ⚠ 网络 '$NETWORK_NAME' 不存在，尝试创建..."
    docker network create "$NETWORK_NAME" >/dev/null 2>&1 || true
fi
docker run -d --name "$CLIENT_NAME" --network "$NETWORK_NAME" postgres:16 sleep 3600 >/dev/null
docker exec "$CLIENT_NAME" psql --version >/dev/null 2>&1
green "  压测客户端就绪"
echo ""

# ============================================================
# Step 4: 节点间 RTT 测量
# ============================================================
echo "=== Step 4: 跨节点 RTT 测量 ==="
echo ""
printf "  %-12s %-12s %12s\n" "源节点" "目标节点" "RTT (ms)"
echo "  -----------------------------------------"

declare -A RTT_MAP=()
for src in 1 2 3 4 5; do
    for dst in 1 2 3 4 5; do
        if [ "$src" -ne "$dst" ]; then
            rtt=$($COMPOSE exec -T "yb-$src" ping -c 2 -W 1 "yb-$dst" 2>/dev/null | \
                  tail -1 | sed -nE 's/.* = [0-9.]+\/([0-9.]+)\/.*/\1/p' || echo "FAIL")
            printf "  %-12s %-12s %12s\n" "yb-$src" "yb-$dst" "${rtt}ms"
            RTT_MAP["${src}-${dst}"]="$rtt"
        fi
    done
done
echo ""

# ============================================================
# Step 5: 延迟基准测试
# ============================================================
echo "=== Step 5: 延迟基准测试 ==="
echo ""

HOSTS=("yb-1" "yb-2" "yb-3" "yb-4" "yb-5")
HOST_LABELS=(
    "region1 (baseline)"
    "region2 (baseline)"
    "region3 (baseline)"
    "region4 (baseline)"
    "region5 (baseline)"
)

# 测量单次读/写延迟 (ms)
measure() {
    local host=$1 op=$2
    local t0 t1 rid
    { t0=$(date +%s%N)
      if [ "$op" = "read" ]; then
          rid=$(( RANDOM % 10000 + 1 ))
          docker exec "$CLIENT_NAME" psql -h "$host" -U yugabyte -tAc \
              "SELECT id FROM perf_test WHERE id = $rid" >/dev/null 2>&1
      else
          docker exec "$CLIENT_NAME" psql -h "$host" -U yugabyte -tAc \
              "INSERT INTO perf_test (data) VALUES (repeat('x', 256))" >/dev/null 2>&1
      fi
      t1=$(date +%s%N)
      echo "scale=2; ($t1 - $t0) / 1000000" | bc; } 2>/dev/null || echo "TIMEOUT"
}

# 批量测量并计算统计
benchmark_node() {
    local host=$1 label=$2

    echo ""
    bold "  --- $label ($host) ---"

    local read_times=() write_times=()

    # READ
    for i in $(seq 1 "$ITERATIONS"); do
        t=$(measure "$host" "read")
        read_times+=("$t")
        printf "\r    READ  %3d/$ITERATIONS" "$i"
    done
    echo ""

    # WRITE
    for i in $(seq 1 "$ITERATIONS"); do
        t=$(measure "$host" "write")
        write_times+=("$t")
        printf "\r    WRITE %3d/$ITERATIONS" "$i"
    done
    echo ""

    # 计算统计 (过滤 TIMEOUT)
    local valid_reads=() valid_writes=()
    for t in "${read_times[@]}"; do
        [[ "$t" =~ ^[0-9.]+$ ]] && valid_reads+=("$t")
    done
    for t in "${write_times[@]}"; do
        [[ "$t" =~ ^[0-9.]+$ ]] && valid_writes+=("$t")
    done

    calc_stats() {
        local name="$1"; shift
        local vals=("$@")
        local n=${#vals[@]}
        if [ "$n" -eq 0 ]; then echo "N/A N/A N/A N/A"; return; fi

        # 排序
        IFS=$'\n' sorted=($(sort -n <<<"${vals[*]}")); unset IFS

        # avg
        local sum=0
        for v in "${vals[@]}"; do sum=$(echo "$sum + $v" | bc); done
        local avg=$(echo "scale=2; $sum / $n" | bc)

        # p50
        local p50_idx=$(( n * 50 / 100 ))
        [ $p50_idx -ge $n ] && p50_idx=$(( n - 1 ))
        local p50="${sorted[$p50_idx]}"

        # p99
        local p99_idx=$(( n * 99 / 100 ))
        [ $p99_idx -ge $n ] && p99_idx=$(( n - 1 ))
        local p99="${sorted[$p99_idx]}"

        # max
        local max="${sorted[$((n-1))]}"

        echo "$avg $p50 $p99 $max"
    }

    read -r R_AVG R_P50 R_P99 R_MAX <<< $(calc_stats "READ" "${valid_reads[@]}")
    read -r W_AVG W_P50 W_P99 W_MAX <<< $(calc_stats "WRITE" "${valid_writes[@]}")

    LATENCY_READ["$host"]="$R_AVG"
    LATENCY_WRITE["$host"]="$W_AVG"

    printf "    READ : avg=%8sms  P50=%8sms  P99=%8sms  max=%8sms\n" "$R_AVG" "$R_P50" "$R_P99" "$R_MAX"
    printf "    WRITE: avg=%8sms  P50=%8sms  P99=%8sms  max=%8sms\n" "$W_AVG" "$W_P50" "$W_P99" "$W_MAX"
}

# 运行所有节点
for i in "${!HOSTS[@]}"; do
    benchmark_node "${HOSTS[$i]}" "${HOST_LABELS[$i]}"
done

# ============================================================
# Step 6: 一致性验证
# ============================================================
echo ""
echo "=== Step 6: 一致性验证 ==="

# leader_only vs follower_read
echo ""
echo "  读一致性测试:"
$COMPOSE exec -T yb-1 ysqlsh -h yb-1 -c "
CREATE TABLE IF NOT EXISTS consistency_check (
    id  INT PRIMARY KEY,
    val INT DEFAULT 42
);
INSERT INTO consistency_check (id, val) VALUES (1, 42) ON CONFLICT (id) DO NOTHING;
" 2>/dev/null

STRONG_READ=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
    "SET yb_read_from_followers = off; SELECT val FROM consistency_check WHERE id = 1;" 2>/dev/null | tail -1 | tr -d '[:space:]')
FOLLOWER_READ=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
    "SET yb_read_from_followers = on; SELECT val FROM consistency_check WHERE id = 1;" 2>/dev/null | tail -1 | tr -d '[:space:]')

printf "  leader_only read: %s\n" "$STRONG_READ"
printf "  follower read:    %s\n" "$FOLLOWER_READ"

if [ "$STRONG_READ" = "42" ] && [ "$FOLLOWER_READ" = "42" ]; then
    green "  ✓ 一致性验证通过 (强一致 + 从节点读均返回正确值)"
else
    yellow "  ⚠ 一致性检查: leader=$STRONG_READ, follower=$FOLLOWER_READ"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                 EXPERIMENT 02 SUMMARY                               ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  %-14s │ %10s │ %10s ║\n" "节点" "读 avg (ms)" "写 avg (ms)"
echo "╠══════════════════════════════════════════════════════════════════════╣"
for host in "${HOSTS[@]}"; do
    r="${LATENCY_READ[$host]:-N/A}"
    w="${LATENCY_WRITE[$host]:-N/A}"
    printf "║  %-14s │ %10s │ %10s ║\n" "$host" "$r" "$w"
done
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# 分析延迟与 RTT 关系
echo "  延迟分析:"
echo "  无 tc netem 延迟注入时，所有节点间延迟应接近一致。"
echo "  延迟主要来自: Docker 网络栈 + PSQL 连接开销 + Raft 共识往返。"
echo "  按 doc_test 实测口径，短连接 psql 查询通常在 60-80ms 量级。"
echo ""

green "Experiment 02 完成."

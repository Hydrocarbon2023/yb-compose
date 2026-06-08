#!/bin/bash
# ============================================================================
# Experiment 10: TPC-C Benchmark
#
# 目的: 使用 go-tpc 测量 YugabyteDB TPC-C 吞吐量基准
#       - 创建 warehouses, 加载数据, 运行基准, 解析 tpmC
#
# 用法:
#   bash scripts/experiment-10-tpcc-benchmark.sh [warehouses] [threads] [duration]
#   bash scripts/experiment-10-tpcc-benchmark.sh 10 8 5m     # 默认
#   bash scripts/experiment-10-tpcc-benchmark.sh 4 4 2m      # smoke test
#
# 所需环境: 基准集群已运行
# 耗时: 取决于 duration (默认 5min + prepare)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/common.sh"

WAREHOUSES="${1:-10}"
THREADS="${2:-8}"
DURATION="${3:-5m}"
HOST="${4:-yb-1}"
PORT="${5:-5433}"
DB="tpcc"
USER="yugabyte"
PASS="yugabyte"

COMPOSE="docker compose -p yb-compose -f compose/base.yaml"

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

cd "$PROJECT_ROOT"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Experiment 10: TPC-C Benchmark (go-tpc)                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  配置:"
echo "    Warehouses: $WAREHOUSES"
echo "    Threads:    $THREADS"
echo "    Duration:   $DURATION"
echo "    Host:       $HOST:$PORT"
echo ""

# ============================================================
# Step 1: 确保集群运行
# ============================================================
echo "=== Step 1: 确保集群运行 ==="
SERVER_COUNT=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
    "SELECT count(*) FROM yb_servers();" 2>/dev/null | tr -d '[:space:]' || echo "0")
if [ "${SERVER_COUNT:-0}" -lt 5 ]; then
    echo "  启动集群..."
    $COMPOSE up -d yb-1 yb-2 yb-3 yb-4 yb-5 rfNready 2>&1 | tail -3
    wait_for_cluster "$COMPOSE" yb-1 5 240
fi
SERVER_COUNT=$($COMPOSE exec -T yb-1 ysqlsh -h yb-1 -tAc \
    "SELECT count(*) FROM yb_servers();" 2>/dev/null | tr -d '[:space:]')
green "  集群就绪 ($SERVER_COUNT 节点)"
echo ""

# ============================================================
# Step 2: Build TPC-C image
# ============================================================
echo "=== Step 2: 构建 TPC-C 镜像 ==="
docker compose -p yb-compose -f compose/base.yaml -f compose/tpcc.yaml build tpcc 2>&1 | tail -3
green "  镜像就绪"
echo ""

TPCC_RUN="docker compose -p yb-compose -f compose/base.yaml -f compose/tpcc.yaml run --rm -T tpcc"

# ============================================================
# Step 3: Create database
# ============================================================
echo "=== Step 3: 创建 tpcc 数据库 ==="
$COMPOSE exec -T yb-1 ysqlsh -h "$HOST" -U "$USER" \
    -c "CREATE DATABASE $DB;" 2>/dev/null && echo "  数据库 '$DB' 已创建" || echo "  数据库 '$DB' 已存在"
echo ""

# ============================================================
# Step 4: Prepare (schema + data load)
# ============================================================
echo "=== Step 4: Prepare TPC-C schema ($WAREHOUSES warehouses) ==="
echo "  (加载数据中, 请耐心等待...)"
$TPCC_RUN go-tpc tpcc --warehouses "$WAREHOUSES" prepare \
    -d postgres -U "$USER" -p "$PASS" -D "$DB" \
    -H "$HOST" -P "$PORT" --conn-params sslmode=disable \
    -T "$THREADS" --ignore-error --no-check 2>&1 | tail -5
green "  Schema + 数据就绪"
echo ""

# ============================================================
# Step 5: Run benchmark
# ============================================================
echo "=== Step 5: 运行 TPC-C Benchmark ($THREADS threads, $DURATION) ==="
echo ""

START_TS=$(date +%s)
RAW_OUTPUT=$($TPCC_RUN go-tpc tpcc --warehouses "$WAREHOUSES" run \
    -d postgres -U "$USER" -p "$PASS" -D "$DB" \
    -H "$HOST" -P "$PORT" --conn-params sslmode=disable \
    -T "$THREADS" --time "$DURATION" --ignore-error 2>&1)
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

echo "$RAW_OUTPUT"
echo ""

# ============================================================
# Step 6: Parse results
# ============================================================
echo "=== Step 6: 解析结果 ==="
echo ""

SUMMARY=$(echo "$RAW_OUTPUT" | grep -oE 'tpmC: [0-9.]+.*efficiency: [0-9.]+%' | tail -1)
TPMC=$(echo "$SUMMARY" | grep -oE 'tpmC: [0-9.]+' | grep -oE '[0-9.]+' || echo "N/A")
TPM_TOTAL=$(echo "$SUMMARY" | grep -oE 'tpmTotal: [0-9.]+' | grep -oE '[0-9.]+' || echo "N/A")
EFFICIENCY=$(echo "$SUMMARY" | grep -oE 'efficiency: [0-9.]+%' | grep -oE '[0-9.]+%' || echo "N/A")

echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                    TPC-C BENCHMARK RESULTS                          ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  Warehouses: %-5s   Threads: %-5s   Duration: %-6s              ║\n" "$WAREHOUSES" "$THREADS" "$DURATION"
printf "║  Wall time:  %-5ss                                                    ║\n" "$ELAPSED"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  tpmC:       %-48s ║\n" "${TPMC:-N/A} (NEW_ORDER/min)"
printf "║  tpmTotal:   %-48s ║\n" "${TPM_TOTAL:-N/A} (all txns/min)"
printf "║  Efficiency: %-48s ║\n" "${EFFICIENCY:-N/A} (vs theoretical max)"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Per-transaction breakdown
echo "  按事务类型:"
echo "$RAW_OUTPUT" | grep '^\[Summary\]' || echo "  (无 summary 行)"
echo ""

# ============================================================
# Step 7: Cleanup
# ============================================================
echo "=== Step 7: 清理 TPC-C 数据 ==="
$TPCC_RUN go-tpc tpcc --warehouses "$WAREHOUSES" cleanup \
    -d postgres -U "$USER" -p "$PASS" -D "$DB" \
    -H "$HOST" -P "$PORT" --conn-params sslmode=disable 2>/dev/null || true
$COMPOSE exec -T yb-1 ysqlsh -h "$HOST" -U "$USER" \
    -c "DROP DATABASE IF EXISTS $DB;" 2>/dev/null || true
echo "  已清理"
echo ""

echo ""
green "Experiment 10 完成."
echo "  tpmC=${TPMC:-N/A}  tpmTotal=${TPM_TOTAL:-N/A}  Efficiency=${EFFICIENCY:-N/A}"

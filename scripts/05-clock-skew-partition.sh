#!/bin/bash
# Phase 6 - Clock Skew + Partition Combined Experiment
# Tests HLC behavior under clock manipulation and network partition
set -euo pipefail

NODES="yb-1 yb-2 yb-3 yb-4 yb-5"
TARGET="yb-5"

# ── helpers ──────────────────────────────────────────────────────────
query_hlc() {
  local node=$1
  docker compose exec -T "$node" ysqlsh -h "$node" -tAc \
    "SELECT host, yb_get_current_hybrid_time(), now()::timestamptz(6) FROM yb_servers() WHERE host = '$(docker compose exec -T "$node" hostname 2>/dev/null | tr -d '[:space:]')';" \
    2>/dev/null || echo "UNREACHABLE"
}

query_all_hlc() {
  local label=$1
  echo ""
  echo "── $label ──"
  for n in $NODES; do
    printf "  %-5s  " "$n"
    docker compose exec -T "$n" ysqlsh -h "$n" -tAc \
      "SELECT yb_get_current_hybrid_time() AS hlc, now()::timestamptz(6) AS pg_time;" \
      2>/dev/null || echo "UNREACHABLE"
  done
}

clock_set() {
  local node=$1
  local offset=$2
  echo "  Setting clock on $node: date -s '$offset'"
  docker exec --privileged "$node" date -s "$offset" 2>&1 | sed 's/^/    /'
}

write_test() {
  local node=$1
  local val=$2
  docker compose exec -T "$node" ysqlsh -h "$node" -tAc \
    "INSERT INTO clock_skew_test (id, ts, node) VALUES ($val, now()::text, '$node') RETURNING id, ts, node;" \
    2>/dev/null || echo "  WRITE FAILED (no consensus)"
}

# ── main ─────────────────────────────────────────────────────────────
echo "========================================="
echo " Clock Skew + Partition Combined Test"
echo "========================================="
echo "Target node: $TARGET (tserver-only, region5, delay=150ms)"
echo ""

# Step 0: Prepare test table
echo "=== Step 0: Prepare test table ==="
docker compose exec -T yb-1 ysqlsh -h yb-1 -c "
  CREATE TABLE IF NOT EXISTS clock_skew_test (
    id INT PRIMARY KEY,
    ts TEXT,
    node TEXT
  );
" > /dev/null 2>&1
echo "  Table clock_skew_test ready"

# Step 1: Record baseline
echo ""
echo "=== Step 1: Baseline — HLC and now() from all nodes ==="
query_all_hlc "Baseline"

# Step 2: Clock fast-forward on yb-5
echo ""
echo "=== Step 2: Clock fast-forward on $TARGET (+500ms) ==="
clock_set "$TARGET" "+500 milliseconds"
sleep 2

# Step 3: Query HLC after forward jump
echo ""
echo "=== Step 3: HLC after forward jump (expect $TARGET HLC jumped forward) ==="
query_all_hlc "After +500ms forward jump"

# Step 4: Clock rewind on yb-5
echo ""
echo "=== Step 4: Clock rewind on $TARGET (-1000ms, simulating NTP correction) ==="
clock_set "$TARGET" "-1000 milliseconds"
sleep 2

# Step 5: Query HLC after backward jump
echo ""
echo "=== Step 5: HLC after backward jump (expect HLC monotonicity — refuses to go back) ==="
query_all_hlc "After -1000ms backward jump"

# Step 6: Inject partition — isolate yb-5
echo ""
echo "=== Step 6: Inject partition — isolate $TARGET ==="
make chaos CMD="partition isolate $TARGET"
sleep 2
echo "  Partition active: $TARGET is isolated"

# Step 7: Write to yb-5 while partitioned
echo ""
echo "=== Step 7: Write to $TARGET while partitioned (expect failure — no consensus) ==="
write_test "$TARGET" 100

# Step 8: Query yb-5's hybrid_time while partitioned
echo ""
echo "=== Step 8: Query $TARGET hybrid_time while partitioned ==="
printf "  %-5s  " "$TARGET"
docker compose exec -T "$TARGET" ysqlsh -h "$TARGET" -tAc \
  "SELECT yb_get_current_hybrid_time() AS hlc, now()::timestamptz(6) AS pg_time;" \
  2>/dev/null || echo "UNREACHABLE (partitioned)"

# Step 9: Heal partition
echo ""
echo "=== Step 9: Heal partition — restore $TARGET ==="
make chaos CMD="partition heal $TARGET"
sleep 2
echo "  Partition healed"

# Step 10: Final verification
echo ""
echo "=== Step 10: Final verification — all nodes HLC ==="
query_all_hlc "After partition heal"

# Verify cluster recovery
echo ""
echo "  Cluster status:"
docker compose exec -T yb-1 ysqlsh -h yb-1 -c \
  "SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;" \
  2>/dev/null || echo "  Cannot query yb_servers()"

echo ""
echo "========================================="
echo " Experiment complete"
echo "========================================="

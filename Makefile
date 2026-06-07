# YugabyteDB 测评实验 Makefile
# =============================
# 快速开始:
#   make experiment-all    # 一键复现全部实验
#
# 单步操作:
#   make up                # 启动基准集群 (5 节点, 无延迟)
#   make up-delay          # 启动延迟环境 (30/60/90/120/150ms)
#   make status            # 查看集群状态
#   make psql              # 连接 yb-1
#   make clean             # 关停并清理所有容器和数据

# TPC-C benchmark defaults (override with make TPCC_WAREHOUSES=20 ...)
TPCC_WAREHOUSES ?= 10
TPCC_THREADS ?= 8
TPCC_DURATION ?= 5m

.PHONY: up up-delay status psql bench clean fix-delay
.PHONY: experiment-all experiment-phase1 experiment-phase2 experiment-phase3 experiment-phase4 experiment-phase5 experiment-phase6
.PHONY: chaos-build chaos chaos-status chaos-partition chaos-heal chaos-delay chaos-scenario
.PHONY: build-bench build-tpcc experiment-tpcc experiment-scalability

COMPOSE = docker compose -f compose/base.yaml

# ============================================================================
# 集群管理
# ============================================================================

up:
	$(COMPOSE) up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 rfNready
	$(COMPOSE) wait rfNready
	$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -c "SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;"

up-delay:
	$(COMPOSE) --env-file=.env.delay up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 rfNready
	$(COMPOSE) wait rfNready
	$(MAKE) fix-delay

# 修复/重设延迟注入（容器启动后安装 iproute-tc + 配 tc netem）
fix-delay:
	@echo "=== 安装 iproute-tc 并注入延迟 ==="
	@for pair in "yb-1 30" "yb-2 60" "yb-3 90" "yb-4 120" "yb-5 150"; do \
		n=$$(echo $$pair | cut -d' ' -f1); \
		d=$$(echo $$pair | cut -d' ' -f2); \
		$(COMPOSE) exec -T $$n bash -c '\
			command -v tc &>/dev/null || dnf install -y -q iproute-tc &>/dev/null; \
			tc qdisc del dev eth0 root 2>/dev/null; \
			tc qdisc add dev eth0 root netem delay '$${d}'ms \
		' 2>/dev/null && echo "  $$n: $${d}ms OK" || echo "  $$n: FAILED"; \
	done
	@echo "=== 延迟验证 ==="
	@for i in 1 2 3 4 5; do \
		s=$$($(COMPOSE) exec -T yb-$$i tc qdisc show dev eth0 2>/dev/null | grep -oE 'delay [0-9.]+ms' | grep -oE '[0-9.]+' || echo "none"); \
		echo "  yb-$$i: $${s}ms"; \
	done

status:
	$(COMPOSE) ps
	@echo ""
	$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -c "SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;"

psql:
	$(COMPOSE) exec -it yb-1 ysqlsh -h yb-1

clean:
	$(COMPOSE) down -v 2>/dev/null || true
	docker rm -f yb-latency-client- yb-latency-persist- 2>/dev/null || true

# ============================================================================
# 全自动实验复现
# ============================================================================

experiment-all: chaos-build
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║  YugabyteDB 分布式数据库 — 全自动实验复现        ║"
	@echo "╚══════════════════════════════════════════════════╝"
	$(MAKE) experiment-phase1
	$(MAKE) experiment-phase2
	$(MAKE) clean
	$(MAKE) experiment-phase3
	$(MAKE) experiment-phase4
	$(MAKE) experiment-phase5
	$(MAKE) experiment-phase6
	@echo ""
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║  全部实验完成                                    ║"
	@echo "╚══════════════════════════════════════════════════╝"

# Phase 1-2: 架构分析（基准环境，无延迟）
experiment-phase1: up
	@echo "\n══════ Phase 1-2: 架构分析 ══════\n"
	$(MAKE) experiment-hlc
	$(MAKE) experiment-tablespace
	$(MAKE) experiment-raft

experiment-hlc:
	@echo ">>> HLC 时钟同步"
	$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -f sql/01-hlc-clock.sql 2>/dev/null || true

experiment-tablespace:
	@echo ">>> 创建 Geo-Partitioning 表空间"
	@for i in 1 2 3 4 5; do \
		$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -c "CREATE TABLESPACE region$$i WITH ( replica_placement = '{\"num_replicas\": 1, \"placement_blocks\": [{\"cloud\": \"cloud\", \"region\": \"region$$i\", \"zone\": \"zone\", \"min_num_replicas\": 1}]}' );" 2>/dev/null || true; \
	done
	$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -c "SELECT spcname FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global');"

experiment-raft:
	@echo ">>> Raft 共识拓扑"
	$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -c "SELECT host, node_type, cloud, region FROM yb_servers() ORDER BY host;"

# Phase 3: 基准测试（基准环境，无延迟）
experiment-phase2: up
	@echo "\n══════ Phase 3: 基准测试 (无延迟) ══════\n"
	$(MAKE) experiment-latency-baseline

experiment-latency-baseline:
	@echo ">>> 创建 perf_test 表"
	bash scripts/01-setup-perf-test.sh
	@echo ">>> 延迟基准测试 (基线环境)"
	python3 scripts/02-latency-bench.py --iter 30
	@echo ">>> 一致性验证"
	bash scripts/03-consistency-test.sh

# Phase 3-4: 延迟环境基准 + 故障切换
experiment-phase3: up-delay
	@echo "\n══════ Phase 3-4: 延迟基准 + 故障切换 ══════\n"
	$(MAKE) experiment-latency-delay
	$(MAKE) experiment-rtt
	$(MAKE) experiment-failover-docker
	$(MAKE) experiment-failover-iptables

experiment-latency-delay:
	@echo ">>> 延迟基准测试 (30/60/90/120/150ms)"
	bash scripts/01-setup-perf-test.sh
	python3 scripts/02-latency-bench.py --iter 30

experiment-rtt:
	@echo ">>> 跨节点 RTT 验证"
	@for pair in "yb-1 yb-2" "yb-1 yb-3" "yb-2 yb-3" "yb-1 yb-5" "yb-4 yb-5"; do \
		a=$$(echo $$pair | cut -d' ' -f1); b=$$(echo $$pair | cut -d' ' -f2); \
		rtt=$$($(COMPOSE) exec -T $$a ping -c 3 -W 1 $$b 2>/dev/null | tail -1 | sed -nE 's/.* = [0-9.]+\/([0-9.]+)\/.*/\1/p' || echo "FAIL"); \
		echo "  $$a ↔ $$b: $${rtt}ms"; \
	done

experiment-failover-docker:
	@echo ">>> 故障切换 RTO (docker stop)"
	bash scripts/04-failover-test.sh yb-2 yb-1

experiment-failover-iptables:
	@echo ">>> 故障切换 RTO (iptables isolate)"
	@$(COMPOSE) exec -T yb-2 ysqlsh -h yb-2 -tAc "SELECT 1;" >/dev/null 2>&1
	@FAILURE_TIME=$$(date +%s%N); \
	make chaos CMD="partition isolate region1" >/dev/null 2>&1; \
	PART_DONE=$$(date +%s%N); \
	echo "  Isolation effective. Probing write recovery..."; \
	for i in $$(seq 1 60); do \
		if $(COMPOSE) exec -T yb-2 ysqlsh -h yb-2 -tAc "INSERT INTO failover_test DEFAULT VALUES RETURNING id;" 2>/dev/null | grep -qE '^[0-9]+'; then \
			R=$$(date +%s%N); \
			RTO_TOTAL=$$(echo "scale=2; ($$R - $$FAILURE_TIME) / 1000000" | bc); \
			RTO_NET=$$(echo "scale=2; ($$R - $$PART_DONE) / 1000000" | bc); \
			echo "  Write recovered after ~$$((i*500))ms, RTO(total)=$${RTO_TOTAL}ms, RTO(net)=$${RTO_NET}ms"; \
			break; \
		fi; \
		sleep 0.5; \
	done
	$(MAKE) chaos-heal CMD="all"

# Phase 5: 混沌工程实验
experiment-phase4: up-delay
	@echo "\n══════ Phase 5: 混沌工程 ══════\n"
	$(MAKE) experiment-wan
	$(MAKE) experiment-asymmetric
	$(MAKE) experiment-partition-dynamic

experiment-wan:
	@echo ">>> WAN 模拟: Jitter+Loss"
	$(MAKE) chaos-delay-set NODE="region2" ARGS="60 20 2"
	$(MAKE) chaos-delay-set NODE="region3" ARGS="90 30 5"
	bash scripts/01-setup-perf-test.sh 2>/dev/null
	python3 scripts/02-latency-bench.py --iter 30
	$(MAKE) fix-delay
	@echo ">>> WAN 模拟: Bandwidth"
	@$(COMPOSE) exec -T yb-4 bash -c 'tc qdisc del dev eth0 root 2>/dev/null; tc qdisc add dev eth0 root handle 1: netem delay 120ms; tc qdisc add dev eth0 parent 1:1 handle 10: tbf rate 10mbit burst 32kbit latency 50ms' 2>/dev/null
	python3 scripts/02-latency-bench.py --iter 30
	$(MAKE) fix-delay

experiment-asymmetric:
	@echo ">>> Asymmetric Delay"
	$(MAKE) chaos-scenario CMD="asymmetric-delay"
	sleep 3
	@echo "  Tablet leader 分布:"
	$(COMPOSE) exec -T yb-1 bash -c 'TABLE_ID=$$(yb-admin -master_addresses yb-1:7100 list_tables 2>/dev/null | grep -i perf_test | grep -oE "\[[0-9a-f]+\]" | tr -d "[]") && yb-admin -master_addresses yb-1:7100 list_tablets tableid.$$TABLE_ID 0 2>/dev/null' 2>&1 || echo "  (check manually)"
	$(MAKE) fix-delay

experiment-partition-dynamic:
	@echo ">>> 动态分区压测"
	bash scripts/07-chaos-bench.sh 2>&1 || true

# Phase 5: 新增实验（基准环境下运行）
experiment-phase5: up
	@echo "\n══════ Phase 6-7: 新增实验 ══════\n"
	bash scripts/01-setup-perf-test.sh
	$(MAKE) experiment-clock-skew
	$(MAKE) experiment-flapping

experiment-clock-skew:
	@echo ">>> 时钟偏移实验 (需要 SYS_TIME 权限)"
	@echo "  Baseline time:"
	@for n in yb-1 yb-2 yb-3 yb-4 yb-5; do printf "  %-5s: " $$n; $(COMPOSE) exec -T $$n date +"%T.%N" 2>/dev/null; done
	@echo "  Fast-forward yb-5 +2s..."
	@docker exec --privileged yb-compose-yb-5-1 bash -c 'date -s "$$(date -d "2 seconds" +"%T.%N")"' 2>/dev/null
	@echo "  Checking cluster... (5s wait)"
	@sleep 5
	@$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM yb_servers();" 2>/dev/null
	@echo "  Clock rewind yb-5 -4s..."
	@docker exec --privileged yb-compose-yb-5-1 bash -c 'date -s "$$(date -d "4 seconds ago" +"%T.%N")"' 2>/dev/null
	@echo "  Waiting for HLC reaction (10s)..."
	@sleep 10
	@$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM yb_servers();" 2>/dev/null || echo "  (cluster may be recovering)"
	$(MAKE) chaos-heal CMD="all"

experiment-flapping:
	@echo ">>> 震荡节点测试"
	bash scripts/06-flapping-node-test.sh 2>&1 || true

# Phase 6: TPC-C + 扩展性（基准环境 + bench 工具）
experiment-phase6: up build-tpcc build-bench
	@echo "\n══════ Phase 8-9: TPC-C 吞吐量 + 扩展性 ══════\n"
	$(MAKE) experiment-tpcc
	$(MAKE) experiment-scalability

experiment-tpcc:
	@echo ">>> TPC-C Benchmark (go-tpc)"
	@echo "    Warehouses=$(TPCC_WAREHOUSES) Threads=$(TPCC_THREADS) Duration=$(TPCC_DURATION)"
	bash scripts/08-tpcc-benchmark.sh $(TPCC_WAREHOUSES) $(TPCC_THREADS) $(TPCC_DURATION)

experiment-scalability:
	@echo ">>> 扩展性测试 (pgbench, 1/3/5 节点)"
	bash scripts/09-scalability-test.sh

# ============================================================================
# 压测工具构建
# ============================================================================

build-tpcc:
	$(COMPOSE) -f compose/tpcc.yaml build tpcc

build-bench:
	$(COMPOSE) -f compose/bench.yaml build pg

# 传统入口（兼容）
bench: up
	$(MAKE) experiment-hlc
	$(MAKE) experiment-tablespace
	$(MAKE) experiment-latency-baseline

bench-delay: up-delay
	$(MAKE) bench

# ============================================================================
# 混沌工程
# ============================================================================

CHAOS_COMPOSE = docker compose -f compose/chaos.yaml

chaos-build:
	$(CHAOS_COMPOSE) build

chaos:
	@$(CHAOS_COMPOSE) run --rm chaosctl $(CMD)

chaos-status:
	@$(CHAOS_COMPOSE) run --rm chaosctl status

chaos-partition:
	@$(CHAOS_COMPOSE) run --rm chaosctl partition $(CMD)

chaos-heal:
	@$(CHAOS_COMPOSE) run --rm chaosctl partition heal $(CMD)

chaos-delay:
	@$(CHAOS_COMPOSE) run --rm chaosctl delay $(CMD)

chaos-delay-set:
	@$(CHAOS_COMPOSE) run --rm chaosctl delay set $(NODE) $(ARGS)

chaos-scenario:
	@$(CHAOS_COMPOSE) run --rm chaosctl scenario run $(CMD)

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
LATENCY_ITER ?= 50

.PHONY: up up-delay status psql clean fix-delay
.PHONY: experiment-all experiment-01 experiment-02 experiment-03 experiment-04 experiment-05 experiment-06 experiment-07 experiment-08 experiment-09 experiment-10 experiment-11
.PHONY: chaos-build chaos chaos-status chaos-partition chaos-heal chaos-delay chaos-scenario
.PHONY: build-bench build-tpcc

COMPOSE = docker compose -p yb-compose -f compose/base.yaml

# ============================================================================
# 集群管理
# ============================================================================

up:
	$(COMPOSE) up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 rfNready
	@timeout 240s bash -c 'until $(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM yb_servers();" 2>/dev/null | grep -q "^5$$"; do sleep 3; done'
	$(COMPOSE) exec -T yb-1 ysqlsh -h yb-1 -c "SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;"

up-delay:
	$(COMPOSE) --env-file=.env.delay up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 rfNready
	@timeout 240s bash -c 'until $(COMPOSE) --env-file=.env.delay exec -T yb-1 ysqlsh -h yb-1 -tAc "SELECT count(*) FROM yb_servers();" 2>/dev/null | grep -q "^5$$"; do sleep 3; done'
	$(MAKE) fix-delay

# 修复/重设延迟注入（容器启动后安装 iproute-tc + 配 tc netem）
fix-delay:
	@echo "=== 安装 iproute-tc 并注入延迟 ==="
	@for pair in "yb-1 30" "yb-2 60" "yb-3 90" "yb-4 120" "yb-5 150"; do \
		n=$$(echo $$pair | cut -d' ' -f1); \
		d=$$(echo $$pair | cut -d' ' -f2); \
		$(COMPOSE) exec -T $$n bash -c '\
			command -v tc &>/dev/null || dnf install -y -q iproute-tc &>/dev/null; \
			tc qdisc replace dev eth0 root netem delay '$${d}'ms \
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
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	docker network rm yb-compose_default 2>/dev/null || true
	docker rm -f yb-latency-client- yb-latency-persist- 2>/dev/null || true

# ============================================================================
# 全自动实验复现
# ============================================================================

experiment-all: chaos-build
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║  YugabyteDB 分布式数据库 — 11 项实验复现         ║"
	@echo "╚══════════════════════════════════════════════════╝"
	$(MAKE) experiment-01
	$(MAKE) experiment-02
	$(MAKE) clean
	$(MAKE) experiment-03
	$(MAKE) experiment-04
	$(MAKE) experiment-05
	$(MAKE) experiment-06
	$(MAKE) experiment-07
	$(MAKE) clean
	$(MAKE) experiment-08
	$(MAKE) clean
	$(MAKE) experiment-09
	$(MAKE) experiment-10
	$(MAKE) experiment-11
	@echo ""
	@echo "╔══════════════════════════════════════════════════╗"
	@echo "║  全部实验完成                                    ║"
	@echo "╚══════════════════════════════════════════════════╝"

experiment-01:
	bash scripts/experiment-01-setup-and-architecture.sh

experiment-02:
	bash scripts/experiment-02-baseline-latency.sh --iter $(LATENCY_ITER)

experiment-03:
	bash scripts/experiment-03-delay-latency.sh --iter $(LATENCY_ITER)

experiment-04:
	bash scripts/experiment-04-failover-rto.sh

experiment-05:
	bash scripts/experiment-05-wan-simulation.sh

experiment-06:
	bash scripts/experiment-06-asymmetric-delay.sh

experiment-07:
	bash scripts/experiment-07-dynamic-partition.sh

experiment-08:
	bash scripts/experiment-08-clock-skew.sh

experiment-09:
	bash scripts/experiment-09-flapping-node.sh

experiment-10:
	bash scripts/experiment-10-tpcc-benchmark.sh $(TPCC_WAREHOUSES) $(TPCC_THREADS) $(TPCC_DURATION)

experiment-11:
	bash scripts/experiment-11-scalability.sh

# ============================================================================
# 压测工具构建
# ============================================================================

build-tpcc:
	$(COMPOSE) -f compose/tpcc.yaml build tpcc

build-bench:
	$(COMPOSE) -f compose/bench.yaml build pg

# ============================================================================
# 混沌工程
# ============================================================================

CHAOS_COMPOSE = docker compose -p yb-compose -f compose/chaos.yaml

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

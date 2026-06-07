# YugabyteDB 测评实验 Makefile
# =============================
# make up        - 启动基准集群 (5 节点, 无延迟)
# make up-delay  - 启动延迟环境 (NET_DELAY_MS=30)
# make status    - 查看集群状态
# make psql      - 连接 yb-1
# make bench     - 运行全部基准测试
# make bench-delay - 在延迟环境下运行基准测试
# make clean     - 关停并清理所有容器和数据

.PHONY: up up-delay status psql bench bench-delay clean

up:
	docker compose up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 pg rfNready
	docker compose wait rfNready
	docker compose exec -T yb-1 ysqlsh -h yb-1 -c "SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;"

up-delay:
	docker compose --env-file=.env.delay up -d yb-1 yb-2 yb-3 yb-4 yb-5 ui-7000 ui-15433 pg rfNready
	docker compose wait rfNready
	@sleep 3
	@echo "=== 验证延迟注入 ==="
	for i in 1 2 3 4 5; do \
		n=yb-$$i; \
		d="$$(docker compose exec $$n tc qdisc show dev eth0 2>/dev/null | grep -o 'delay [0-9]*ms' || echo 'none')"; \
		echo "  $$n: $$d"; \
	done

status:
	docker compose ps
	@echo ""
	docker compose exec -T yb-1 ysqlsh -h yb-1 -c "SELECT host, cloud, region, zone FROM yb_servers() ORDER BY host;"

psql:
	docker compose exec -it yb-1 ysqlsh -h yb-1

# 构建压测工具镜像
build-bench:
	docker compose -f docker-compose.yaml -f docker-compose.bench.yaml build pg

bench: up
	@echo ">>> Phase 2.1: HLC 时钟"
	docker compose exec -T yb-1 ysqlsh -h yb-1 -f sql/01-hlc-clock.sql 2>/dev/null || true
	@echo ""
	@echo ">>> Phase 2.4: 表空间"
	for i in 1 2 3 4 5; do \
		docker compose exec -T yb-1 ysqlsh -h yb-1 -c "CREATE TABLESPACE region$$i WITH ( replica_placement = '{\"num_replicas\": 1, \"placement_blocks\": [{\"cloud\": \"cloud\", \"region\": \"region$$i\", \"zone\": \"zone\", \"min_num_replicas\": 1}]}' );" 2>/dev/null || true; \
	done
	@echo "  Tablespaces created"
	@echo ""
	@echo ">>> Phase 3.1: perf_test + 延迟基准"
	bash scripts/01-setup-perf-test.sh
	python3 scripts/02-latency-bench.py --iter 30
	@echo ""
	@echo ">>> Phase 3.3: 一致性验证"
	bash scripts/03-consistency-test.sh
	@echo ""
	@echo ">>> Phase 4.3: 故障切换"
	bash scripts/04-failover-test.sh yb-1 yb-1

bench-delay: up-delay
	$(MAKE) bench

# 对基线环境和延迟环境分别做延迟测试对比
bench-compare: up
	@echo "=== 基线环境 (无延迟) ==="
	python3 scripts/02-latency-bench.py --iter 30
	@echo ""
	@echo "=== 切换到延迟环境 ==="
	docker compose down -v
	$(MAKE) up-delay
	python3 scripts/02-latency-bench.py --iter 30

clean:
	docker compose down -v 2>/dev/null || true
	docker rm -f yb-latency-client- 2>/dev/null || true

# Chaos Engineering
# =================
# 依赖: docker-compose.chaos.yaml + scripts/chaosctl
# 用法: make chaos CMD="status"
#       make chaos CMD="partition isolate region1"
#       make chaos CMD="partition heal all"
#       make chaos CMD="scenario run network-partition yb-1 20"

CHAOS_COMPOSE = docker compose -f docker-compose.chaos.yaml

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

chaos-scenario:
	@$(CHAOS_COMPOSE) run --rm chaosctl scenario run $(CMD)

.PHONY: chaos chaos-status chaos-partition chaos-heal chaos-delay chaos-scenario

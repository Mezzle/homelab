.PHONY: up down restart logs status pull update reload-rules help

COMPOSE := docker compose

up: ## Start all services
	$(COMPOSE) up -d

down: ## Stop all services
	$(COMPOSE) down

restart: ## Restart all services (or specific: make restart s=prometheus)
ifdef s
	$(COMPOSE) restart $(s)
else
	$(COMPOSE) restart
endif

pull: ## Pull latest images
	$(COMPOSE) pull

update: pull ## Pull latest images and recreate changed containers
	$(COMPOSE) up -d --remove-orphans

logs: ## Tail logs (or specific: make logs s=prometheus)
ifdef s
	$(COMPOSE) logs -f --tail=100 $(s)
else
	$(COMPOSE) logs -f --tail=100
endif

status: ## Show container status with health
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort

reload-rules: ## Hot-reload Prometheus alert rules (no restart needed)
	curl -sf -X POST http://localhost:9090/-/reload && echo "Rules reloaded" || echo "Failed (is Prometheus running?)"

alerts: ## Show currently firing alerts
	@curl -sf http://localhost:9093/api/v2/alerts | python3 -m json.tool 2>/dev/null || echo "Alertmanager not reachable"

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

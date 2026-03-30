.PHONY: up down restart logs status update pull help

COMPOSE := docker compose

up: ## Start home services
	$(COMPOSE) up -d

down: ## Stop home services
	$(COMPOSE) down

restart: ## Restart (or specific: make restart s=mosquitto)
ifdef s
	$(COMPOSE) restart $(s)
else
	$(COMPOSE) restart
endif

pull: ## Pull latest images
	$(COMPOSE) pull

update: pull ## Pull and recreate
	$(COMPOSE) up -d --remove-orphans

logs: ## Tail logs (or specific: make logs s=z2m)
ifdef s
	$(COMPOSE) logs -f --tail=100 $(s)
else
	$(COMPOSE) logs -f --tail=100
endif

status: ## Show status
	@docker ps --filter "label=com.docker.compose.project=home" --format "table {{.Names}}\t{{.Status}}" | sort

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

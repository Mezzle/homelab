.PHONY: up down restart logs status update pull help

COMPOSE := docker compose

up: ## Start Music Assistant
	$(COMPOSE) up -d

down: ## Stop Music Assistant
	$(COMPOSE) down

restart: ## Restart
	$(COMPOSE) restart

pull: ## Pull latest images
	$(COMPOSE) pull

update: pull ## Pull and recreate
	$(COMPOSE) up -d --remove-orphans

logs: ## Tail logs
	$(COMPOSE) logs -f --tail=100

status: ## Show status
	@docker ps --filter "label=com.docker.compose.project=music" --format "table {{.Names}}\t{{.Status}}" | sort

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

.PHONY: up down restart logs status update pull clean help

COMPOSE := docker compose

up: ## Start Immich
	$(COMPOSE) up -d

down: ## Stop Immich
	$(COMPOSE) down

restart: ## Restart Immich (or specific: make restart s=immich-server)
ifdef s
	$(COMPOSE) restart $(s)
else
	$(COMPOSE) restart
endif

pull: ## Pull latest images
	$(COMPOSE) pull

update: pull ## Pull and recreate changed containers
	$(COMPOSE) up -d --remove-orphans

logs: ## Tail logs (or specific: make logs s=immich-ml)
ifdef s
	$(COMPOSE) logs -f --tail=100 $(s)
else
	$(COMPOSE) logs -f --tail=100
endif

status: ## Show container status
	@docker ps --filter "label=com.docker.compose.project=immich" --format "table {{.Names}}\t{{.Status}}" | sort

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

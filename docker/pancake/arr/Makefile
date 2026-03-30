.PHONY: up down restart logs status bootstrap backup update pull sync sync-logs clean help

COMPOSE := docker compose

##############################################################################
# Lifecycle
##############################################################################

up: ## Start all services
	$(COMPOSE) up -d

down: ## Stop all services
	$(COMPOSE) down

restart: ## Restart all services (or specific: make restart s=sonarr)
ifdef s
	$(COMPOSE) restart $(s)
else
	$(COMPOSE) restart
endif

pull: ## Pull latest images
	$(COMPOSE) pull

update: pull ## Pull latest images and recreate changed containers
	$(COMPOSE) up -d --remove-orphans

##############################################################################
# Observability
##############################################################################

logs: ## Tail logs (or specific: make logs s=sonarr)
ifdef s
	$(COMPOSE) logs -f --tail=100 $(s)
else
	$(COMPOSE) logs -f --tail=100
endif

status: ## Show container status with health
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort

health: ## Show only health status of all containers
	@docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "(healthy|unhealthy|starting)" | sort

##############################################################################
# Setup & maintenance
##############################################################################

bootstrap: ## Run first-time auto-configuration of cross-service links
	./scripts/bootstrap.sh

bootstrap-dry: ## Preview what bootstrap would configure (no changes)
	./scripts/bootstrap.sh --dry

backup: ## Run a manual backup now
	docker exec backup /bin/bash /backup.sh

recyclarr-sync: ## Trigger an immediate Recyclarr sync
	docker exec recyclarr recyclarr sync

sync: ## Trigger a manual gitops sync now
	./scripts/gitops-sync.sh

sync-logs: ## Tail the gitops sync logs
	journalctl -u gitops-sync.service -f

##############################################################################
# Cleanup
##############################################################################

clean: ## Remove stopped containers, dangling images, unused networks
	docker system prune -f --volumes=false

##############################################################################
# Help
##############################################################################

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

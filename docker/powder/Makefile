.PHONY: up-all down-all restart-all status update-all backup-all help

# All stacks to manage — add new stacks here as you create them
STACKS := infra monitoring

up-all: ## Start all stacks
	@for s in $(STACKS); do echo "=== Starting $$s ===" && $(MAKE) -C $$s up; done

down-all: ## Stop all stacks
	@for s in $(STACKS); do echo "=== Stopping $$s ===" && $(MAKE) -C $$s down; done

restart-all: ## Restart all stacks
	@for s in $(STACKS); do echo "=== Restarting $$s ===" && $(MAKE) -C $$s restart; done

update-all: ## Pull and recreate all stacks
	@for s in $(STACKS); do echo "=== Updating $$s ===" && $(MAKE) -C $$s update; done

backup-all: ## Run backups for all stacks that support it
	@for s in $(STACKS); do \
	  if $(MAKE) -C $$s -n backup >/dev/null 2>&1; then \
	    echo "=== Backing up $$s ===" && $(MAKE) -C $$s backup; \
	  fi; \
	done

status: ## Show all container status
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help

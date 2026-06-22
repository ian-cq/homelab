.PHONY: help setup install uninstall configure start stop restart status logs

UNIT := frps
CONFIG_DIR := /etc/frp
SYSTEMD_DIR := /etc/systemd/system

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: ## Download frps binary, create user, configure firewall
	bash setup.sh

install: setup ## Full install: setup + copy config + enable systemd service
	sudo cp frps.toml $(CONFIG_DIR)/frps.toml
	sudo chown frp:frp $(CONFIG_DIR)/frps.toml
	sudo chmod 640 $(CONFIG_DIR)/frps.toml
	sudo cp frps.service $(SYSTEMD_DIR)/$(UNIT).service
	sudo systemctl daemon-reload
	sudo systemctl enable --now $(UNIT)
	@echo "==> frps installed and running"
	@echo "    edit auth.token in $(CONFIG_DIR)/frps.toml, then: make restart"

uninstall: ## Stop and remove frps service, config, and binary
	-sudo systemctl disable --now $(UNIT)
	-sudo rm -f $(SYSTEMD_DIR)/$(UNIT).service
	-sudo rm -rf $(CONFIG_DIR)
	-sudo rm -f /usr/local/bin/frps
	-sudo userdel frp 2>/dev/null || true
	sudo systemctl daemon-reload
	@echo "==> frps uninstalled"

configure: ## Copy updated frps.toml and restart
	sudo cp frps.toml $(CONFIG_DIR)/frps.toml
	sudo chown frp:frp $(CONFIG_DIR)/frps.toml
	sudo chmod 640 $(CONFIG_DIR)/frps.toml
	sudo systemctl restart $(UNIT)
	@echo "==> config updated and frps restarted"

start: ## Start frps
	sudo systemctl start $(UNIT)

stop: ## Stop frps
	sudo systemctl stop $(UNIT)

restart: ## Restart frps
	sudo systemctl restart $(UNIT)

status: ## Show frps service status
	sudo systemctl status $(UNIT)

logs: ## Follow frps logs
	journalctl -u $(UNIT) -f

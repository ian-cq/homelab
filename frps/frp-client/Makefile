.PHONY: help setup install uninstall secret secret-rotate configure start stop restart status logs

UNIT := frpc
CONFIG_DIR := /etc/frp
SYSTEMD_DIR := /etc/systemd/system
OP_ITEM := op://Homelab/frp-auth-token/credential

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: ## Download frpc binary and create service user
	bash setup.sh

secret: ## Pull auth token from 1Password and write to /etc/frp/frpc.env
	@echo "==> fetching FRP auth token from 1Password"
	@op read "$(OP_ITEM)" | xargs -I{} sh -c 'echo "FRP_AUTH_TOKEN={}"' | sudo tee $(CONFIG_DIR)/frpc.env > /dev/null
	sudo chown frp:frp $(CONFIG_DIR)/frpc.env
	sudo chmod 600 $(CONFIG_DIR)/frpc.env
	@echo "==> secret written to $(CONFIG_DIR)/frpc.env"

install: setup secret ## Full install: setup + secret + copy config + enable systemd service
	sudo cp frpc.toml $(CONFIG_DIR)/frpc.toml
	sudo chown frp:frp $(CONFIG_DIR)/frpc.toml
	sudo chmod 640 $(CONFIG_DIR)/frpc.toml
	sudo cp frpc.service $(SYSTEMD_DIR)/$(UNIT).service
	sudo systemctl daemon-reload
	sudo systemctl enable --now $(UNIT)
	@echo "==> frpc installed and running"

uninstall: ## Stop and remove frpc service, config, and binary
	-sudo systemctl disable --now $(UNIT)
	-sudo rm -f $(SYSTEMD_DIR)/$(UNIT).service
	-sudo rm -rf $(CONFIG_DIR)
	-sudo rm -f /usr/local/bin/frpc
	-sudo userdel frp 2>/dev/null || true
	sudo systemctl daemon-reload
	@echo "==> frpc uninstalled"

secret-rotate: secret ## Re-pull secret from 1Password and restart
	sudo systemctl restart $(UNIT)
	@echo "==> secret rotated and frpc restarted"

configure: ## Copy updated frpc.toml and restart
	sudo cp frpc.toml $(CONFIG_DIR)/frpc.toml
	sudo chown frp:frp $(CONFIG_DIR)/frpc.toml
	sudo chmod 640 $(CONFIG_DIR)/frpc.toml
	sudo systemctl restart $(UNIT)
	@echo "==> config updated and frpc restarted"

start: ## Start frpc
	sudo systemctl start $(UNIT)

stop: ## Stop frpc
	sudo systemctl stop $(UNIT)

restart: ## Restart frpc
	sudo systemctl restart $(UNIT)

status: ## Show frpc service status
	sudo systemctl status $(UNIT)

logs: ## Follow frpc logs
	journalctl -u $(UNIT) -f

HOST ?= preview
SERVER ?= root@159.89.98.26

deploy:
	nixos-rebuild switch --flake .#$(HOST) \
		--target-host $(SERVER) \
		--build-host $(SERVER)

dry-run:
	nixos-rebuild dry-activate --flake .#$(HOST) \
		--target-host $(SERVER) \
		--build-host $(SERVER)

health:
	@curl -sf http://159.89.98.26:9101/health | python3 -m json.tool

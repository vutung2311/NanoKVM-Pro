# ==============================================================================
# NanoKVM Pro - End-to-End Build & Release Automation Makefile
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# ------------------------------------------------------------------------------
# Project Paths & Settings
# ------------------------------------------------------------------------------
ROOT_DIR        ?= $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
SERVER_DIR      ?= $(ROOT_DIR)/server
WEB_DIR         ?= $(ROOT_DIR)/web
SUPPORT_DIR     ?= $(ROOT_DIR)/support
BUILD_IMAGE_DIR ?= $(SUPPORT_DIR)/scripts/build_image
OVERLAY_DIR     ?= $(BUILD_IMAGE_DIR)/overlay
VERSION         ?= 1.2.15
VERSION_UNDERSCORE := $(subst .,_,$(VERSION))
BASE_FIRMWARE_DIR ?= $(SUPPORT_DIR)/base_firmware
DIST_DIR        ?= $(ROOT_DIR)/build_dist
APP_DIR         ?= $(DIST_DIR)/nanokvm_pro_$(VERSION)
BASE_APP_DIR    ?= $(BASE_FIRMWARE_DIR)/nanokvm_pro_$(VERSION)

# Release Artifact File Names & Templates
BASE_AXP        ?= $(BASE_FIRMWARE_DIR)/20260529_NanoKVMPro_1_0_15.axp
BASE_TAR_GZ     ?= $(BASE_FIRMWARE_DIR)/nanokvm_pro_$(VERSION).tar.gz
OUTPUT_AXP      ?= $(DIST_DIR)/NanoKVMPro_Custom_$(VERSION_UNDERSCORE).axp
OUTPUT_IMG_XZ   ?= $(DIST_DIR)/NanoKVMPro_Custom_$(VERSION_UNDERSCORE).img.xz

# Tools & Binaries
PYTHON          ?= python3
VENV_PYTHON     ?= $(BUILD_IMAGE_DIR)/.venv/bin/python3
AXP2IMG         ?= $(shell command -v axp2img 2>/dev/null || ([ -x $(BUILD_IMAGE_DIR)/.venv/bin/axp2img ] && echo $(BUILD_IMAGE_DIR)/.venv/bin/axp2img) || echo axp2img)
PNPM            ?= pnpm

# Upstream Repository Settings
UPSTREAM_REMOTE ?= upstream
UPSTREAM_REPO   ?= https://github.com/sipeed/NanoKVM-Pro.git
UPSTREAM_BRANCH ?= main

# Privilege escalation (auto-detect: root -> none, pkexec -> sudo -> doas)
ifeq ($(shell id -u),0)
    PRIV_ESC    ?=
else ifneq ($(shell command -v pkexec 2>/dev/null),)
    PRIV_ESC    ?= pkexec
else ifneq ($(shell command -v sudo 2>/dev/null),)
    PRIV_ESC    ?= sudo
else ifneq ($(shell command -v doas 2>/dev/null),)
    PRIV_ESC    ?= doas
else
    PRIV_ESC    ?=
endif

# Formatting Helpers
CYAN  := \033[36m
GREEN := \033[32m
YELLOW:= \033[33m
RED   := \033[31m
RESET := \033[0m

# ------------------------------------------------------------------------------
# Phony Targets
# ------------------------------------------------------------------------------
.PHONY: all help fetch-base build server client web overlay deb app-pkg web-pkg image-axp image-raw image-img image release deploy clean distclean flash-info check-upstream rebase-upstream sync-upstream

# Default Target
all: help

# ------------------------------------------------------------------------------
# Base Firmware Targets
# ------------------------------------------------------------------------------
## Download pristine base firmware artifacts (.axp and stock packages) from GitHub release
fetch-base:
	@mkdir -p $(BASE_FIRMWARE_DIR)
	@if [ ! -f "$(BASE_AXP)" ]; then \
		echo -e "$(CYAN)==> Downloading base AXP image from Sipeed releases...$(RESET)"; \
		curl -L -f --progress-bar -o "$(BASE_AXP)" "https://github.com/sipeed/NanoKVM-Pro/releases/download/v1.0.15/20260529_NanoKVMPro_1_0_15.axp" || { \
			rm -f "$(BASE_AXP)"; \
			echo -e "$(RED)Failed to download base AXP image.$(RESET)"; \
			exit 1; \
		}; \
		echo -e "$(GREEN)[✓] Base AXP image downloaded: $(BASE_AXP)$(RESET)"; \
	else \
		echo -e "$(GREEN)[✓] Base AXP image already present: $(BASE_AXP)$(RESET)"; \
	fi
	@if [ ! -f "$(BASE_TAR_GZ)" ]; then \
		echo -e "$(CYAN)==> Downloading base application package archive ($(VERSION))...$(RESET)"; \
		curl -L -f --progress-bar -o "$(BASE_TAR_GZ)" "https://github.com/sipeed/NanoKVM-Pro/releases/download/$(VERSION)/nanokvm_pro_$(VERSION).tar.gz" || { \
			rm -f "$(BASE_TAR_GZ)"; \
			echo -e "$(RED)Failed to download base application package archive.$(RESET)"; \
			exit 1; \
		}; \
		echo -e "$(GREEN)[✓] Base package archive downloaded: $(BASE_TAR_GZ)$(RESET)"; \
	else \
		echo -e "$(GREEN)[✓] Base package archive already present: $(BASE_TAR_GZ)$(RESET)"; \
	fi
	@if [ ! -d "$(BASE_APP_DIR)" ] || [ ! -f "$(BASE_APP_DIR)/nanokvmpro_$(VERSION)_arm64.deb" ]; then \
		echo -e "$(CYAN)==> Unpacking pristine base Debian packages into $(BASE_APP_DIR)...$(RESET)"; \
		mkdir -p "$(BASE_APP_DIR)"; \
		tar -xzf "$(BASE_TAR_GZ)" -C "$(BASE_FIRMWARE_DIR)"; \
		echo -e "$(GREEN)[✓] Base packages unpacked in $(BASE_APP_DIR)$(RESET)"; \
	else \
		echo -e "$(GREEN)[✓] Base packages verified in $(BASE_APP_DIR)$(RESET)"; \
	fi

# ------------------------------------------------------------------------------
# Build Targets (Server & Client)
# ------------------------------------------------------------------------------
## Compile both the server backend and the web frontend
build: server client

## Compile NanoKVM-Server ARM64 binary
server:
	@echo -e "$(CYAN)==> Building NanoKVM-Server (Go + ARM64 toolchain)...$(RESET)"
	@cd $(SERVER_DIR) && ./build.sh
	@echo -e "$(GREEN)[✓] NanoKVM-Server built successfully: $(SERVER_DIR)/NanoKVM-Server$(RESET)"

## Compile Web UI frontend with pnpm/vite
client: web
web:
	@echo -e "$(CYAN)==> Building Web Client (Vite + TypeScript)...$(RESET)"
	@cd $(WEB_DIR) && \
		if [ ! -d "node_modules" ]; then \
			echo -e "$(YELLOW)[!] Installing frontend dependencies with pnpm...$(RESET)"; \
			$(PNPM) install; \
		fi && \
		$(PNPM) run build
	@echo -e "$(GREEN)[✓] Web UI built successfully: $(WEB_DIR)/dist$(RESET)"

# ------------------------------------------------------------------------------
# Packaging & Staging Targets
# ------------------------------------------------------------------------------
## Stage compiled server binary and web dist into the overlay directory
overlay: server client
	@echo -e "$(CYAN)==> Staging binaries and web assets to overlay directory...$(RESET)"
	@mkdir -p $(OVERLAY_DIR)/kvmapp/server/web
	@cp $(SERVER_DIR)/NanoKVM-Server $(OVERLAY_DIR)/kvmapp/server/NanoKVM-Server
	@chmod 755 $(OVERLAY_DIR)/kvmapp/server/NanoKVM-Server
	@rm -rf $(OVERLAY_DIR)/kvmapp/server/web/*
	@cp -r $(WEB_DIR)/dist/* $(OVERLAY_DIR)/kvmapp/server/web/
	@chmod +x $(OVERLAY_DIR)/kvmapp/scripts/*.sh 2>/dev/null || true
	@chmod +x $(OVERLAY_DIR)/kvmcomm/scripts/*.sh 2>/dev/null || true
	@echo -e "$(GREEN)[✓] Overlay staged at: $(OVERLAY_DIR)$(RESET)"

## Repackage ARM64 Debian packages (nanokvmpro & kvmcomm) with custom code & scripts
deb: server client
	@if [ ! -d "$(BASE_APP_DIR)" ] || [ ! -f "$(BASE_APP_DIR)/nanokvmpro_$(VERSION)_arm64.deb" ]; then \
		echo -e "$(CYAN)==> Base packages not found, fetching base firmware...$(RESET)"; \
		$(MAKE) fetch-base; \
	fi
	@mkdir -p $(APP_DIR) $(DIST_DIR)
	@echo -e "$(CYAN)==> Staging clean base Debian packages into $(APP_DIR)...$(RESET)"
	@cp -f $(BASE_APP_DIR)/*.deb $(BASE_APP_DIR)/*.json $(APP_DIR)/
	@echo -e "$(CYAN)==> Repackaging $(APP_DIR)/nanokvmpro_$(VERSION)_arm64.deb...$(RESET)"
	@REPACK_DIR=$$(mktemp -d -t nanokvm_deb_XXXXXX); \
	dpkg-deb -R $(APP_DIR)/nanokvmpro_$(VERSION)_arm64.deb "$$REPACK_DIR" && \
	cp $(SERVER_DIR)/NanoKVM-Server "$$REPACK_DIR/kvmapp/server/NanoKVM-Server" && \
	chmod 755 "$$REPACK_DIR/kvmapp/server/NanoKVM-Server" && \
	rm -rf "$$REPACK_DIR/kvmapp/server/web"/* && \
	cp -r $(WEB_DIR)/dist/* "$$REPACK_DIR/kvmapp/server/web/" && \
	if [ -f "$(OVERLAY_DIR)/kvmapp/scripts/usbdev.sh" ]; then \
		cp $(OVERLAY_DIR)/kvmapp/scripts/usbdev.sh "$$REPACK_DIR/kvmapp/scripts/usbdev.sh" && \
		chmod 755 "$$REPACK_DIR/kvmapp/scripts/usbdev.sh"; \
	fi && \
	dpkg-deb --root-owner-group -b "$$REPACK_DIR" $(APP_DIR)/nanokvmpro_$(VERSION)_arm64.deb && \
	rm -rf "$$REPACK_DIR"
	@cp -f $(APP_DIR)/nanokvmpro_$(VERSION)_arm64.deb $(DIST_DIR)/
	@echo -e "$(GREEN)[✓] Debian package ready: $(DIST_DIR)/nanokvmpro_$(VERSION)_arm64.deb$(RESET)"
	@if [ -f "$(APP_DIR)/kvmcomm_$(VERSION)_arm64.deb" ]; then \
		echo -e "$(CYAN)==> Repackaging $(APP_DIR)/kvmcomm_$(VERSION)_arm64.deb with Wi-Fi auto-restore scripts...$(RESET)"; \
		REPACK_COMM=$$(mktemp -d -t kvmcomm_deb_XXXXXX); \
		dpkg-deb -R $(APP_DIR)/kvmcomm_$(VERSION)_arm64.deb "$$REPACK_COMM" && \
		if [ -f "$(OVERLAY_DIR)/kvmcomm/scripts/wifi.sh" ]; then \
			cp $(OVERLAY_DIR)/kvmcomm/scripts/wifi.sh "$$REPACK_COMM/kvmcomm/scripts/wifi.sh" && \
			chmod 755 "$$REPACK_COMM/kvmcomm/scripts/wifi.sh"; \
		fi && \
		if [ -f "$(OVERLAY_DIR)/kvmcomm/scripts/kvmcomm.sh" ]; then \
			cp $(OVERLAY_DIR)/kvmcomm/scripts/kvmcomm.sh "$$REPACK_COMM/kvmcomm/scripts/kvmcomm.sh" && \
			chmod 755 "$$REPACK_COMM/kvmcomm/scripts/kvmcomm.sh"; \
		fi && \
		dpkg-deb --root-owner-group -b "$$REPACK_COMM" $(APP_DIR)/kvmcomm_$(VERSION)_arm64.deb && \
		rm -rf "$$REPACK_COMM" && \
		cp -f $(APP_DIR)/kvmcomm_$(VERSION)_arm64.deb $(DIST_DIR)/; \
		echo -e "$(GREEN)[✓] Debian package ready: $(DIST_DIR)/kvmcomm_$(VERSION)_arm64.deb$(RESET)"; \
	fi

## Package update archive (.tar.gz) for Web UI update (Settings -> Update -> Manual Update)
app-pkg: web-pkg
web-pkg: deb
	@echo -e "$(CYAN)==> Generating web-uploadable update archive (.tar.gz)...$(RESET)"
	@cd $(APP_DIR) && \
		SIZE=$$(stat -c%s nanokvmpro_$(VERSION)_arm64.deb) && \
		HASH=$$(sha512sum nanokvmpro_$(VERSION)_arm64.deb | awk '{print $$1}' | xxd -r -p | base64 -w 0) && \
		printf '{\n  "version": "%s",\n  "name": "nanokvmpro_%s_arm64.deb",\n  "sha512": "%s",\n  "size": %s\n}\n' \
			"$(VERSION)" "$(VERSION)" "$$HASH" "$$SIZE" > nanokvmpro_$(VERSION).json && \
		if [ -f "kvmcomm_$(VERSION)_arm64.deb" ]; then \
			SIZE_COMM=$$(stat -c%s kvmcomm_$(VERSION)_arm64.deb) && \
			HASH_COMM=$$(sha512sum kvmcomm_$(VERSION)_arm64.deb | awk '{print $$1}' | xxd -r -p | base64 -w 0) && \
			printf '{\n  "version": "%s",\n  "name": "kvmcomm_%s_arm64.deb",\n  "sha512": "%s",\n  "size": %s\n}\n' \
				"$(VERSION)" "$(VERSION)" "$$HASH_COMM" "$$SIZE_COMM" > kvmcomm_$(VERSION).json; \
		fi
	@cd $(DIST_DIR) && tar -czf nanokvm_pro_$(VERSION).tar.gz nanokvm_pro_$(VERSION)/
	@echo -e "$(GREEN)[✓] Web update package ready: $(DIST_DIR)/nanokvm_pro_$(VERSION).tar.gz$(RESET)"

# ------------------------------------------------------------------------------
# Image Generation Targets (.axp and .img.xz)
# ------------------------------------------------------------------------------
## Repackage base AXP into custom NanoKVM-Pro AXP image
image-axp: overlay
	@echo -e "$(CYAN)==> Packaging custom AXP image using build_image.py...$(RESET)"
	@if [ ! -f "$(BASE_AXP)" ]; then \
		echo -e "$(CYAN)==> Base AXP file not found, fetching base firmware...$(RESET)"; \
		$(MAKE) fetch-base; \
	fi
	@mkdir -p $(DIST_DIR)
	$(PRIV_ESC) $(PYTHON) $(BUILD_IMAGE_DIR)/build_image.py \
		$(BASE_AXP) \
		--app $(APP_DIR) \
		--overlay $(OVERLAY_DIR) \
		-o $(OUTPUT_AXP)
	@echo -e "$(GREEN)[✓] AXP image created: $(OUTPUT_AXP)$(RESET)"

$(OUTPUT_AXP):
	@$(MAKE) image-axp

## Convert AXP image to compressed raw disk image (.img.xz)
image-raw: image-img
image-img: $(OUTPUT_AXP)
	@echo -e "$(CYAN)==> Converting AXP to raw disk image (.img.xz) using axp2img...$(RESET)"
	@if [ ! -x "$$(command -v $(AXP2IMG) 2>/dev/null)" ] && [ ! -x "$(AXP2IMG)" ]; then \
		echo -e "$(RED)Error: axp2img tool not found at $(AXP2IMG).$(RESET)"; \
		echo -e "$(YELLOW)Please run: pip3 install axp-tools$(RESET)"; \
		exit 1; \
	fi
	$(AXP2IMG) -i $(OUTPUT_AXP) -o $(OUTPUT_IMG_XZ)
	@echo -e "$(GREEN)[✓] Raw compressed image created: $(OUTPUT_IMG_XZ)$(RESET)"

## Build both AXP and raw .img.xz images
image: image-axp image-raw

# ------------------------------------------------------------------------------
# Release Target (End-to-End Orchestrator)
# ------------------------------------------------------------------------------
## Complete end-to-end pipeline (server + client + deb + overlay + axp + img.xz)
release: build overlay deb image-axp image-raw
	@echo ""
	@echo -e "$(GREEN)==================================================================$(RESET)"
	@echo -e "$(GREEN)  NanoKVM Pro End-to-End Release Complete!$(RESET)"
	@echo -e "$(GREEN)==================================================================$(RESET)"
	@echo -e "Generated Release Artifacts in $(DIST_DIR):"
	@ls -lh $(OUTPUT_AXP) $(OUTPUT_IMG_XZ)
	@echo ""
	@echo -e "SHA256 Checksums:"
	@sha256sum $(OUTPUT_AXP) $(OUTPUT_IMG_XZ)
	@echo -e "$(GREEN)==================================================================$(RESET)"
	@echo -e "Run '$(CYAN)make flash-info$(RESET)' to view device burning instructions."

# ------------------------------------------------------------------------------
# Remote SSH Deployment Target
# ------------------------------------------------------------------------------
## Deploy updated deb packages directly to the device over SSH (usage: make deploy IP=<device-ip>)
deploy: deb
	@TARGET_IP="$${IP:-$${DEVICE_IP:-}}"; \
	if [ -z "$$TARGET_IP" ]; then \
		echo -e "$(RED)Error: Target IP address not specified.$(RESET)"; \
		echo -e "$(YELLOW)Usage: make deploy IP=<device-ip>  (or: make deploy DEVICE_IP=<device-ip>)$(RESET)"; \
		exit 1; \
	fi; \
	echo -e "$(CYAN)==> Copying deb packages to root@$$TARGET_IP:/tmp/...$(RESET)"; \
	scp $(DIST_DIR)/nanokvmpro_$(VERSION)_arm64.deb $(DIST_DIR)/kvmcomm_$(VERSION)_arm64.deb root@$$TARGET_IP:/tmp/; \
	echo -e "$(CYAN)==> Installing packages and restarting services on $$TARGET_IP...$(RESET)"; \
	ssh root@$$TARGET_IP "dpkg -i /tmp/nanokvmpro_$(VERSION)_arm64.deb /tmp/kvmcomm_$(VERSION)_arm64.deb && systemctl restart nanokvm kvmcomm && rm -f /tmp/*_arm64.deb"; \
	echo -e "$(GREEN)[✓] Deployment to $$TARGET_IP completed successfully!$(RESET)"

# ------------------------------------------------------------------------------
# Git & Upstream Synchronization Targets
# ------------------------------------------------------------------------------
## Check upstream repository for new commits without modifying working tree
check-upstream:
	@CURR_BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$CURR_BRANCH" = "HEAD" ]; then \
		echo -e "$(RED)[✗] Detached HEAD state detected. Please checkout a branch first.$(RESET)"; \
		exit 1; \
	fi; \
	if ! git remote | grep -qx "$(UPSTREAM_REMOTE)"; then \
		echo -e "$(CYAN)==> Adding upstream remote '$(UPSTREAM_REMOTE)' ($(UPSTREAM_REPO))...$(RESET)"; \
		git remote add "$(UPSTREAM_REMOTE)" "$(UPSTREAM_REPO)"; \
	fi; \
	echo -e "$(CYAN)==> Checking $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)...$(RESET)"; \
	git fetch "$(UPSTREAM_REMOTE)" "$(UPSTREAM_BRANCH)" --quiet; \
	BEHIND=$$(git rev-list --count HEAD..$(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)); \
	AHEAD=$$(git rev-list --count $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)..HEAD); \
	echo -e "Branch: $(CYAN)$$CURR_BRANCH$(RESET) | Ahead: $(GREEN)$$AHEAD$(RESET) | Behind: $(YELLOW)$$BEHIND$(RESET)"; \
	if [ "$$BEHIND" -gt 0 ]; then \
		echo ""; \
		echo -e "$(YELLOW)New commits available in upstream $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH):$(RESET)"; \
		git log --oneline --no-merges -n 5 HEAD..$(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH); \
		echo ""; \
		echo -e "Run '$(GREEN)make rebase-upstream$(RESET)' to rebase your local branch."; \
	else \
		echo -e "$(GREEN)[✓] Up to date with upstream.$(RESET)"; \
	fi

## Rebase current branch on top of upstream main branch
rebase-upstream:
	@CURR_BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$CURR_BRANCH" = "HEAD" ]; then \
		echo -e "$(RED)[✗] Detached HEAD state detected. Please checkout a branch first.$(RESET)"; \
		exit 1; \
	fi; \
	if [ -d "$$(git rev-parse --git-dir)/rebase-merge" ] || [ -d "$$(git rev-parse --git-dir)/rebase-apply" ]; then \
		echo -e "$(RED)[✗] A git rebase is already in progress.$(RESET)"; \
		echo -e "Please finish it with '$(CYAN)git rebase --continue$(RESET)' or abort with '$(CYAN)git rebase --abort$(RESET)'."; \
		exit 1; \
	fi; \
	if [ -n "$$(git status --porcelain -uno)" ]; then \
		echo -e "$(RED)[✗] Working tree contains uncommitted changes.$(RESET)"; \
		echo -e "$(YELLOW)Please stash, commit, or discard your modifications before rebasing:$(RESET)"; \
		git status --short -uno; \
		exit 1; \
	fi; \
	if ! git remote | grep -qx "$(UPSTREAM_REMOTE)"; then \
		echo -e "$(CYAN)==> Adding upstream remote '$(UPSTREAM_REMOTE)' ($(UPSTREAM_REPO))...$(RESET)"; \
		git remote add "$(UPSTREAM_REMOTE)" "$(UPSTREAM_REPO)"; \
	fi; \
	echo -e "$(CYAN)==> Fetching latest changes from $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)...$(RESET)"; \
	git fetch "$(UPSTREAM_REMOTE)" "$(UPSTREAM_BRANCH)" --tags --prune; \
	BEHIND=$$(git rev-list --count HEAD..$(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)); \
	AHEAD=$$(git rev-list --count $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)..HEAD); \
	if [ "$$BEHIND" -eq 0 ]; then \
		echo -e "$(GREEN)[✓] Already up to date with $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH). (Local commits ahead: $$AHEAD)$(RESET)"; \
		exit 0; \
	fi; \
	echo -e "$(CYAN)==> Rebasing $$CURR_BRANCH onto $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)...$(RESET)"; \
	echo -e "$(YELLOW)    Applying $$BEHIND upstream commit(s) beneath $$AHEAD local commit(s)...$(RESET)"; \
	if git rebase "$(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)"; then \
		echo -e "$(GREEN)[✓] Successfully rebased $$CURR_BRANCH onto $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)!$(RESET)"; \
		echo -e "$(CYAN)    New upstream base: $$(git rev-parse --short $(UPSTREAM_REMOTE)/$(UPSTREAM_BRANCH)) | Current HEAD: $$(git rev-parse --short HEAD)$(RESET)"; \
	else \
		echo ""; \
		echo -e "$(RED)[!] Rebase encountered merge conflicts.$(RESET)"; \
		echo -e "$(YELLOW)Conflicted files:$(RESET)"; \
		git status --short | grep -E '^(UU|AA|DD|DU|UD|UA|AU)' || git status --short; \
		echo ""; \
		echo -e "Resolution steps:"; \
		echo -e "  1. Resolve conflicts in your editor"; \
		echo -e "  2. Mark resolved:  $(CYAN)git add <conflicted-file>$(RESET)"; \
		echo -e "  3. Continue:       $(CYAN)git rebase --continue$(RESET)"; \
		echo -e "  (To cancel safely: $(CYAN)git rebase --abort$(RESET))"; \
		exit 1; \
	fi

## Alias for rebase-upstream
sync-upstream: rebase-upstream

# ------------------------------------------------------------------------------
# Helper & Cleanup Targets
# ------------------------------------------------------------------------------
## Clean compiled server binary and web dist folder
clean:
	@echo -e "$(YELLOW)==> Cleaning build artifacts...$(RESET)"
	@rm -f $(SERVER_DIR)/NanoKVM-Server
	@rm -rf $(WEB_DIR)/dist
	@echo -e "$(GREEN)[✓] Clean complete.$(RESET)"

## Full clean of all generated build outputs (preserves support/base_firmware)
distclean: clean
	@echo -e "$(YELLOW)==> Cleaning generated distribution artifacts in $(DIST_DIR)...$(RESET)"
	@rm -rf $(DIST_DIR)
	@echo -e "$(GREEN)[✓] Distclean complete. Base firmware in $(BASE_FIRMWARE_DIR) preserved.$(RESET)"

## Show device flashing instructions
flash-info:
	@echo ""
	@echo -e "$(CYAN)================ NanoKVM Pro Flashing Instructions ===============$(RESET)"
	@echo -e "Images available:"
	@echo -e "  • Raw Image: $(OUTPUT_IMG_XZ)"
	@echo -e "  • AXP Image: $(OUTPUT_AXP)"
	@echo ""
	@echo -e "$(YELLOW)Method 1: USB Mass Storage Burning (Recommended on Linux)$(RESET)"
	@echo -e "  1. Remove TF/SD card if inserted in NanoKVM Pro."
	@echo -e "  2. Connect USB cable from host PC to NanoKVM Pro's HID port."
	@echo -e "  3. Hold USER button, power on (or press Reset), hold until orange LED turns off, then release."
	@echo -e "  4. Device appears as a USB block device (check with: lsblk)."
	@echo -e "  5. Flash directly via dd:"
	@echo -e "     $(CYAN)xz -dc $(OUTPUT_IMG_XZ) | pkexec dd of=/dev/sdX bs=4M status=progress conv=fsync$(RESET)"
	@echo ""
	@echo -e "$(YELLOW)Method 2: Boot from MicroSD Card$(RESET)"
	@echo -e "  1. Insert SD card (>=16GB) into host reader."
	@echo -e "  2. Flash $(OUTPUT_IMG_XZ) to SD card using dd or balenaEtcher."
	@echo -e "  3. Insert into NanoKVM Pro, hold USER button while powering on to boot from SD."
	@echo ""
	@echo -e "$(YELLOW)Method 3: Official AXP Burning Tool (AXDL on Windows)$(RESET)"
	@echo -e "  1. Connect to HID port and open AXDL."
	@echo -e "  2. Select $(OUTPUT_AXP) and burn in download mode."
	@echo -e "$(CYAN)==================================================================$(RESET)"

## Show this help message
help:
	@echo ""
	@echo -e "$(CYAN)NanoKVM Pro Build System$(RESET)"
	@echo -e "Usage: make $(GREEN)<target>$(RESET)"
	@echo ""
	@echo -e "Targets:"
	@awk '/^[a-zA-Z0-9_-]+:/ { \
		if (lastLine ~ /^## /) { \
			helpCommand = substr($$1, 1, index($$1, ":")-1); \
			helpDesc = substr(lastLine, 4); \
			printf "  $(GREEN)%-16s$(RESET) %s\n", helpCommand, helpDesc; \
		} \
	} \
	{ lastLine = $$0 }' $(MAKEFILE_LIST)
	@echo ""

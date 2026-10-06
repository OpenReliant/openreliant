# OpenReliant: an engine reimplementation of StarLancer, and the study of the game behind it.
#
# `make help` lists the targets. The work is split over mk/*.mk:
#
#   mk/config.mk      paths, pinned versions, host detection
#   mk/toolchain.mk   JDK, Ghidra, GhydraMCP: everything under tools/
#   mk/zig.mk         our own code (delegates to build.zig)
#   mk/game.mk        disc images -> game/cd1, game/cd2, game/install
#   mk/ghidra.mk      headless import/analysis, exports, the GUI
#   mk/repo.mk        the check that keeps the game's files out of the repository, the git hooks
#
# Written for GNU Make 3.81, which is what macOS ships.

.DEFAULT_GOAL := help
# Make 3.81 has no .SHELLFLAGS; flags ride along in SHELL instead.
SHELL := /bin/bash -eu -o pipefail
.DELETE_ON_ERROR:
.SUFFIXES:

include mk/config.mk
include mk/toolchain.mk
include mk/zig.mk
include mk/game.mk
include mk/ghidra.mk
include mk/repo.mk

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } \
	     /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	     /^[a-zA-Z0-9_.-]+:.*## / { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: all
all: setup build game ghidra-import ## Everything: toolchain, tools, game files, Ghidra project

.PHONY: clean
clean: zig-clean ## Remove build products (keeps tools/, game/ and the Ghidra project)

.PHONY: doctor
doctor: ## Report which parts of the environment are in place
	@scripts/doctor.sh "$(ROOT)" "$(JDK_HOME)" "$(GHIDRA_HOME)" "$(GHIDRA_PLATFORM)" \
	    "$(GHIDRA_USER_DIR)" "$(ZIG)" "$(GHIDRA_PROJECT_DIR)/$(GHIDRA_PROJECT).gpr" "$(ZIG_VERSION)"

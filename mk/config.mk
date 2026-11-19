# Paths, pinned versions and host detection. Every `?=` can be overridden from the environment or
# the make command line.

ROOT := $(patsubst %/,%,$(dir $(abspath $(firstword $(MAKEFILE_LIST)))))

TOOLS_DIR      := $(ROOT)/tools
DOWNLOADS_DIR  := $(TOOLS_DIR)/downloads
STAMPS_DIR     := $(TOOLS_DIR)/.stamps
GAME_DIR       := $(ROOT)/game
GHIDRA_DIR     := $(ROOT)/ghidra

# --- host -------------------------------------------------------------------------------------

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

ifeq ($(HOST_OS),Darwin)
  ADOPTIUM_OS := mac
  GHIDRA_OS   := mac
  GHIDRA_USER_BASE ?= $(HOME)/Library/ghidra
else
  ADOPTIUM_OS := linux
  GHIDRA_OS   := linux
  GHIDRA_USER_BASE ?= $(HOME)/.config/ghidra
endif

ifneq ($(filter arm64 aarch64,$(HOST_ARCH)),)
  ADOPTIUM_ARCH := aarch64
  GHIDRA_ARCH   := arm_64
else
  ADOPTIUM_ARCH := x64
  GHIDRA_ARCH   := x86_64
endif

# Name of the directory Ghidra looks in for its native helpers (decompiler, demangler, ...).
GHIDRA_PLATFORM := $(GHIDRA_OS)_$(GHIDRA_ARCH)

# --- pinned versions --------------------------------------------------------------------------

JDK_MAJOR ?= 25
GHYDRA_PYTHON_VERSION ?= 3.15

GHIDRA_VERSION ?= 12.2
GHIDRA_DATE    ?= 20261016
GHIDRA_SHA256  ?= 2c2cd776db3c1f6a097ba418922378ac3649cadd5e844a6f5f088ae628a7be67

MAVEN_VERSION ?= 3.10.1
MAVEN_SHA512  ?= 8af2fcc48ee6b8f8fc0b21054226e14404b88500df6483cdeb3ae603408f6de27b1397ac591a9fb0d98fee64f4f624fee1383efd25b8998786cda1598fb9ea39

# Turns the game's shaders from SPIR-V into Metal's language: only `make shaders` needs it.
SPIRV_CROSS_VERSION ?= vulkan-sdk-1.4.363.0
SPIRV_CROSS_SHA256  ?= f708982e88b763ef5b0394ed468fc2c3628f68cdab89f2e7a946cd628c04e721

# The Ghidra plugin must be built against the exact Ghidra version, so it is built from source.
GHYDRA_REPO ?= https://github.com/starsong-consulting/GhydraMCP.git
GHYDRA_REF  ?= v3.0.0-rc.1

# --- derived ----------------------------------------------------------------------------------

JDK_HOME        := $(TOOLS_DIR)/jdk
GHIDRA_HOME     := $(TOOLS_DIR)/ghidra_$(GHIDRA_VERSION)_PUBLIC
GHIDRA_USER_DIR := $(GHIDRA_USER_BASE)/ghidra_$(GHIDRA_VERSION)_PUBLIC
MAVEN_HOME      := $(TOOLS_DIR)/apache-maven-$(MAVEN_VERSION)
GHYDRA_SRC      := $(TOOLS_DIR)/ghydramcp-src
VENV_DIR        := $(TOOLS_DIR)/venv
SPIRV_CROSS     := $(TOOLS_DIR)/spirv-cross/spirv-cross

# Include the version in each stamp so an existing installation picks up new pins.
JDK_STAMP            := $(STAMPS_DIR)/jdk-$(JDK_MAJOR)
GHIDRA_STAMP         := $(STAMPS_DIR)/ghidra-$(GHIDRA_VERSION)
GHIDRA_NATIVES_STAMP := $(GHIDRA_STAMP)-natives
MAVEN_STAMP          := $(STAMPS_DIR)/maven-$(MAVEN_VERSION)
GHYDRA_SRC_STAMP     := $(STAMPS_DIR)/ghydra-src-$(subst /,-,$(GHYDRA_REF))
GHYDRA_PLUGIN_STAMP  := $(GHYDRA_SRC_STAMP)-plugin-$(GHIDRA_VERSION)
GHYDRA_CLI_STAMP     := $(GHYDRA_SRC_STAMP)-cli-$(GHYDRA_PYTHON_VERSION)

# Prefer a native arm64 Zig over an x86_64 one that happens to be first on PATH. `make doctor`
# warns when it isn't the version build.zig.zon asks for.
ZIG ?= $(firstword $(wildcard /opt/homebrew/bin/zig) zig)
ZIG_VERSION := $(shell sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' $(ROOT)/build.zig.zon)

CURL := curl --location --fail --retry 5 --retry-delay 5 --silent --show-error

# Run a command with the project JDK.
WITH_JDK := JAVA_HOME="$(JDK_HOME)" PATH="$(JDK_HOME)/bin:$$PATH"

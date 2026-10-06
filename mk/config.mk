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

JDK_MAJOR ?= 21

GHIDRA_VERSION ?= 12.1.3
GHIDRA_DATE    ?= 20260817
GHIDRA_SHA256  ?= 93a5d11a9ad510622acaaf908c556a7b9b764d338e78a7567f3689bf5081fd54

MAVEN_VERSION ?= 3.9.16
MAVEN_SHA512  ?= 831a8591fe20c8243b1dbe7d71e3244f31d1665b0804b2e825e38cbbe5ce0cafb8338851f90780735568773e0a6cd07bbec107cda0b896b008b861075358b6f6

# Turns the game's shaders from SPIR-V into Metal's language: only `make shaders` needs it.
SPIRV_CROSS_VERSION ?= vulkan-sdk-1.4.357.0
SPIRV_CROSS_SHA256  ?= 97c910326afdd44d794ce8561326fa675fd1958b27142f03295403044d639639

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

# Prefer a native arm64 Zig over an x86_64 one that happens to be first on PATH. `make doctor`
# warns when it isn't the version build.zig.zon asks for.
ZIG ?= $(firstword $(wildcard /opt/homebrew/bin/zig) zig)
ZIG_VERSION := $(shell sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' $(ROOT)/build.zig.zon)

CURL := curl --location --fail --retry 5 --retry-delay 5 --silent --show-error

# Run a command with the project JDK.
WITH_JDK := JAVA_HOME="$(JDK_HOME)" PATH="$(JDK_HOME)/bin:$$PATH"

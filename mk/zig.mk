# Our own code. build.zig owns compilation; these targets only make it reachable from `make` and
# give the other fragments a file ($(SLTOOL)) to depend on.

##@ Code (Zig)

SLTOOL      := $(ROOT)/zig-out/bin/sltool
OPENRELIANT := $(ROOT)/zig-out/bin/openreliant
ZIG_SOURCES := $(ROOT)/build.zig $(ROOT)/build.zig.zon $(shell find $(ROOT)/src $(ROOT)/deps -name '*.zig' -o -name '*.zon')

.PHONY: build
build: $(SLTOOL) ## Build the tools into zig-out/bin

$(SLTOOL): $(ZIG_SOURCES)
	$(ZIG) build -Doptimize=ReleaseSafe
	@touch $@

# The same build makes both.
$(OPENRELIANT): $(SLTOOL) ;

# The engine, optimized, for the host's own processor: a Zig built for Intel Macs, run under Rosetta
# on Apple silicon, would otherwise build it for Intel too.
GAME_TARGET := $(if $(and $(filter Darwin,$(HOST_OS)),$(filter arm64 aarch64,$(HOST_ARCH))),-Dtarget=aarch64-macos,)

.PHONY: play
play: | $(GAME_DIR)/.stamp-install ## Build OpenReliant optimized and run it on the installed game files
	$(ZIG) build -Doptimize=ReleaseFast $(GAME_TARGET)
	$(ROOT)/zig-out/bin/openreliant $(INSTALL_DIR)

# The game's shaders, for each GPU interface SDL runs on: SPIR-V for Vulkan, and Metal's
# language from that. The outputs are committed, so building needs neither tool; regenerating needs
# glslc (from shaderc) on the PATH, and SPIRV-Cross, which this builds.
SHADER_DIR := $(ROOT)/src/platform/shaders
SHADERS    := $(foreach name,device bloom shadow,$(foreach stage,vert frag,$(SHADER_DIR)/$(name).$(stage).spv $(SHADER_DIR)/$(name).$(stage).msl))
GLSLC      ?= glslc

.PHONY: shaders
shaders: $(SHADERS) ## Compile the game's shader for Vulkan and Metal (needs glslc)

# What they share of colour, which they include.
SHADER_COMMON := $(SHADER_DIR)/colour.glsl

$(SHADER_DIR)/%.vert.spv: $(SHADER_DIR)/%.glsl $(SHADER_COMMON)
	$(GLSLC) -fshader-stage=vertex -DVERTEX -O $< -o $@

$(SHADER_DIR)/%.frag.spv: $(SHADER_DIR)/%.glsl $(SHADER_COMMON)
	$(GLSLC) -fshader-stage=fragment -DFRAGMENT -O $< -o $@

$(SHADER_DIR)/%.msl: $(SHADER_DIR)/%.spv | $(SPIRV_CROSS)
	$(SPIRV_CROSS) $< --msl --msl-version 20200 --msl-decoration-binding --output $@

.PHONY: test
test: ## Run the unit tests
	$(ZIG) build test --summary all

# The scripting API's definitions for Luau's language server and its reference page, which tests
# check (src/scripting/reference.zig). Write them again when what scripts see changes on purpose.
.PHONY: definitions
definitions: ## Write the scripting API's definitions and reference page in docs/guide
	$(ZIG) build
	$(ROOT)/zig-out/bin/openreliant hooks --definitions > $(ROOT)/docs/guide/openreliant.d.luau
	$(ROOT)/zig-out/bin/openreliant hooks --markdown > $(ROOT)/docs/guide/hooks.md

# Tests joystick and gamepad support on Linux with virtual controllers that imitate real ones
# (scripts/controllers). It runs in a privileged Docker container with the host's /dev mounted,
# which also works on macOS through Docker's Linux VM.
CONTROLLER_TEST_ARCH := $(if $(filter arm64 aarch64,$(HOST_ARCH)),aarch64,x86_64)
CONTROLLER_TEST_PLATFORM := $(if $(filter arm64 aarch64,$(HOST_ARCH)),linux/arm64,linux/amd64)

.PHONY: test-controllers
test-controllers: ## Test joysticks and gamepads on Linux with virtual controllers (needs Docker)
	$(ZIG) build -Doptimize=ReleaseFast -Dtarget=$(CONTROLLER_TEST_ARCH)-linux-gnu --prefix $(ROOT)/zig-out/linux
	docker run --rm --privileged --platform $(CONTROLLER_TEST_PLATFORM) -v /dev:/dev \
	    -v $(ROOT)/scripts/controllers:/test:ro -v $(ROOT)/zig-out/linux/bin/openreliant:/opt/openreliant:ro \
	    ubuntu:24.04 /test/run.sh /opt/openreliant

.PHONY: fmt
fmt: ## Format the Zig sources
	$(ZIG) fmt build.zig src

.PHONY: fmt-check
fmt-check: ## Fail if any Zig source is not formatted
	$(ZIG) fmt --check build.zig src

.PHONY: zig-clean
zig-clean:
	rm -rf $(ROOT)/.zig-cache $(ROOT)/zig-out

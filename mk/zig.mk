# Our own code. build.zig owns compilation; these targets only make it reachable from `make` and
# give the other fragments a file ($(SLTOOL)) to depend on.

##@ Code (Zig)

SLTOOL      := $(ROOT)/zig-out/bin/sltool
OPENRELIANT := $(ROOT)/zig-out/bin/openreliant
# The game always includes networking. Build the pinned transport once for this host.
TRANSPORT_ARCH := $(if $(filter arm64 aarch64,$(HOST_ARCH)),aarch64,x86_64)
TRANSPORT_SYSTEM := $(if $(filter Darwin,$(HOST_OS)),macos.15.0,linux-gnu.2.31)
TRANSPORT_TARGET := $(TRANSPORT_ARCH)-$(TRANSPORT_SYSTEM)
TRANSPORT_WORK := $(ROOT)/.zig-cache/transport
TRANSPORT_PREFIX := $(TRANSPORT_WORK)/$(TRANSPORT_TARGET)/prefix
TRANSPORT_LIB := $(TRANSPORT_PREFIX)/lib/libGameNetworkingSockets_s.a

$(TRANSPORT_WORK)/%/prefix/lib/libGameNetworkingSockets_s.a: scripts/build_transport.py deps/transport/CMakeLists.txt deps/transport/PatchGnsSource.cmake $(wildcard deps/transport/*.patch)
	python3 scripts/build_transport.py $(TRANSPORT_WORK) $*

ZIG_SOURCES := $(ROOT)/build.zig $(ROOT)/build.zig.zon $(shell find $(ROOT)/src $(ROOT)/deps -name '*.zig' -o -name '*.zon')

.PHONY: build
build: $(SLTOOL) ## Build the tools into zig-out/bin

$(SLTOOL): $(ZIG_SOURCES) $(TRANSPORT_LIB)
	$(ZIG) build --release=safe $(GAME_TARGET) -Dgns-prefix=$(TRANSPORT_PREFIX)
	@touch $@

# The same build makes both.
$(OPENRELIANT): $(SLTOOL) ;

# The engine, optimized, for the host's own processor: a Zig built for Intel Macs, run under Rosetta
# on Apple silicon, would otherwise build it for Intel too.
GAME_TARGET := $(if $(and $(filter Darwin,$(HOST_OS)),$(filter arm64 aarch64,$(HOST_ARCH))),-Dtarget=aarch64-macos,)

.PHONY: play
play: $(TRANSPORT_LIB) | $(GAME_DIR)/.stamp-install ## Build OpenReliant optimized and run it on the installed game files
	$(ZIG) build --release=fast $(GAME_TARGET) -Dgns-prefix=$(TRANSPORT_PREFIX)
	$(ROOT)/zig-out/bin/openreliant $(INSTALL_DIR)

# The game's shaders, for each GPU interface SDL runs on: SPIR-V for Vulkan, and Metal's
# language from that. The outputs are committed, so building needs neither tool; regenerating needs
# glslc (from shaderc) on the PATH, and SPIRV-Cross, which this builds. Each shader's .sha256 holds
# the SHA-256 of the source it was compiled from, which a test checks against the source
# (src/platform/gpu/programs.zig), so that a shader changed without `make shaders` fails the tests.
SHADER_DIR   := $(ROOT)/src/platform/shaders
SHADER_NAMES := device bloom shadow
SHADERS      := $(foreach name,$(SHADER_NAMES),$(foreach stage,vert frag,$(SHADER_DIR)/$(name).$(stage).spv $(SHADER_DIR)/$(name).$(stage).msl) $(SHADER_DIR)/$(name).sha256)
GLSLC        ?= glslc

.PHONY: shaders
shaders: $(SHADERS) ## Compile the game's shader for Vulkan and Metal (needs glslc)

# What they share of colour, which they include.
SHADER_COMMON := $(SHADER_DIR)/color.glsl

$(SHADER_DIR)/%.vert.spv: $(SHADER_DIR)/%.glsl $(SHADER_COMMON)
	$(GLSLC) -fshader-stage=vertex -DVERTEX -O $< -o $@

$(SHADER_DIR)/%.frag.spv: $(SHADER_DIR)/%.glsl $(SHADER_COMMON)
	$(GLSLC) -fshader-stage=fragment -DFRAGMENT -O $< -o $@

$(SHADER_DIR)/%.msl: $(SHADER_DIR)/%.spv | $(SPIRV_CROSS)
	$(SPIRV_CROSS) $< --msl --msl-version 20200 --msl-decoration-binding --output $@

$(SHADER_DIR)/%.sha256: $(SHADER_DIR)/%.glsl $(SHADER_COMMON)
	cat $< $(SHADER_COMMON) | shasum -a 256 | cut -c1-64 > $@

# OpenReliant's icon (assets/icon): its PNGs, the Windows .ico and the macOS .icns, which
# scripts/icon.sh makes from its SVG. They are committed, so building needs none of the tools that
# make them: rsvg-convert (librsvg), icotool (icoutils) and macOS's iconutil.
.PHONY: icon
icon: ## Make the icon's PNG, ICO and ICNS files from its SVG (needs librsvg, icoutils and macOS)
	$(ROOT)/scripts/icon.sh

.PHONY: test
test: $(TRANSPORT_LIB) ## Run the unit tests
	$(ZIG) build test --summary all -Dgns-prefix=$(TRANSPORT_PREFIX)

# The definitions for Luau's language server and the reference pages, of the scripting API and of
# mission source, which tests check (src/scripting/reference.zig, and definitions.zig and
# reference.zig in src/formats/dte/source). Write them again when what scripts see, or what mission
# source holds, changes on purpose.
.PHONY: definitions
definitions: $(TRANSPORT_LIB) ## Write the definitions for Luau's language server and the reference pages in docs/guide
	$(ZIG) build $(GAME_TARGET) -Dgns-prefix=$(TRANSPORT_PREFIX)
	$(ROOT)/zig-out/bin/openreliant hooks --definitions > $(ROOT)/docs/guide/openreliant.d.luau
	$(ROOT)/zig-out/bin/openreliant hooks --markdown > $(ROOT)/docs/guide/reference.md
	$(ROOT)/zig-out/bin/sltool dte definitions > $(ROOT)/docs/guide/mission.d.luau
	$(ROOT)/zig-out/bin/sltool dte reference > $(ROOT)/docs/guide/mission-reference.md

# Tests joystick and gamepad support on Linux with virtual controllers that imitate real ones
# (scripts/controllers). It runs in a privileged Docker container with the host's /dev mounted,
# which also works on macOS through Docker's Linux VM.
CONTROLLER_TEST_ARCH := $(if $(filter arm64 aarch64,$(HOST_ARCH)),aarch64,x86_64)
CONTROLLER_TRANSPORT := $(TRANSPORT_WORK)/$(CONTROLLER_TEST_ARCH)-linux-gnu.2.31/prefix
CONTROLLER_TEST_PLATFORM := $(if $(filter arm64 aarch64,$(HOST_ARCH)),linux/arm64,linux/amd64)

.PHONY: test-controllers
test-controllers: $(CONTROLLER_TRANSPORT)/lib/libGameNetworkingSockets_s.a ## Test joysticks and gamepads on Linux with virtual controllers (needs Docker)
	$(ZIG) build --release=fast -Dtarget=$(CONTROLLER_TEST_ARCH)-linux-gnu.2.31 -Dgns-prefix=$(CONTROLLER_TRANSPORT) --prefix $(ROOT)/zig-out/linux
	docker run --rm --privileged --platform $(CONTROLLER_TEST_PLATFORM) -v /dev:/dev \
	    -v $(ROOT)/scripts/controllers:/test:ro -v $(ROOT)/zig-out/linux/bin/openreliant:/opt/openreliant:ro \
	    ubuntu:26.04 /test/run.sh /opt/openreliant

.PHONY: fmt
fmt: ## Format the Zig sources
	$(ZIG) fmt build.zig src

.PHONY: fmt-check
fmt-check: ## Fail if any Zig source is not formatted
	$(ZIG) fmt --check build.zig src

.PHONY: zig-clean
zig-clean:
	rm -rf $(ROOT)/.zig-cache $(ROOT)/zig-out $(ROOT)/zig-pkg

# Third-party toolchain, all of it under tools/ (git-ignored): a JDK, Ghidra with native helpers
# for this host, Maven, and the GhydraMCP plugin + CLI.
#
# Each step leaves a stamp in tools/.stamps/, so `make setup` only does what is missing. Downloads
# are order-only prerequisites: a re-fetched archive never forces a rebuild.

##@ Toolchain

.PHONY: setup
setup: jdk ghidra ghydra ## Install the whole toolchain into tools/

$(DOWNLOADS_DIR) $(STAMPS_DIR):
	mkdir -p $@

# --- JDK (Eclipse Temurin) --------------------------------------------------------------------

JDK_ARCHIVE := $(DOWNLOADS_DIR)/temurin-$(JDK_MAJOR)-$(ADOPTIUM_OS)-$(ADOPTIUM_ARCH).tar.gz
JDK_URL     := https://api.adoptium.net/v3/binary/latest/$(JDK_MAJOR)/ga/$(ADOPTIUM_OS)/$(ADOPTIUM_ARCH)/jdk/hotspot/normal/eclipse

.PHONY: jdk
jdk: $(JDK_STAMP) ## Eclipse Temurin JDK for this host (Ghidra 12.2 needs 25)

$(JDK_ARCHIVE): | $(DOWNLOADS_DIR)
	$(CURL) --output $@ "$(JDK_URL)"

# The archive unpacks to jdk-<version>/; on macOS the JDK proper is in Contents/Home below that.
$(JDK_STAMP): | $(JDK_ARCHIVE) $(STAMPS_DIR)
	tar -xzf $(JDK_ARCHIVE) -C $(TOOLS_DIR)
	top=$$(tar -tzf $(JDK_ARCHIVE) | head -1 | cut -d/ -f1); \
	home=$$top; if [ -d "$(TOOLS_DIR)/$$top/Contents/Home" ]; then home=$$top/Contents/Home; fi; \
	ln -sfn "$$home" $(JDK_HOME)
	$(JDK_HOME)/bin/java -version
	touch $@

# --- Ghidra -----------------------------------------------------------------------------------

GHIDRA_ARCHIVE := $(DOWNLOADS_DIR)/ghidra_$(GHIDRA_VERSION)_PUBLIC_$(GHIDRA_DATE).zip
GHIDRA_URL     := https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_$(GHIDRA_VERSION)_build/$(notdir $(GHIDRA_ARCHIVE))

.PHONY: ghidra
ghidra: $(GHIDRA_NATIVES_STAMP) ## Ghidra, with native helpers built for this host

$(GHIDRA_ARCHIVE): | $(DOWNLOADS_DIR)
	$(CURL) --output $@ "$(GHIDRA_URL)"
	scripts/verify-hash.sh sha256 $(GHIDRA_SHA256) $@

$(GHIDRA_STAMP): | $(GHIDRA_ARCHIVE) $(STAMPS_DIR)
	unzip -q -o $(GHIDRA_ARCHIVE) -d $(TOOLS_DIR)
	ln -sfn $(notdir $(GHIDRA_HOME)) $(TOOLS_DIR)/ghidra
	@# Pin Ghidra to the project JDK so it also starts when launched outside of make.
	sed -i.orig 's|^JAVA_HOME_OVERRIDE=.*|JAVA_HOME_OVERRIDE=$(JDK_HOME)|' $(GHIDRA_HOME)/support/launch.properties
	touch $@

# Release archives carry natives for Windows and Linux x86-64 only. Everywhere else (notably
# macOS) the decompiler has to be compiled, which needs a C++ toolchain (Xcode CLT on macOS).
$(GHIDRA_NATIVES_STAMP): $(GHIDRA_STAMP) $(JDK_STAMP)
	if [ -x "$(GHIDRA_HOME)/Ghidra/Features/Decompiler/os/$(GHIDRA_PLATFORM)/decompile" ]; then \
	    echo "Ghidra ships natives for $(GHIDRA_PLATFORM)"; \
	else \
	    gradle=$$(command -v gradle || echo ./gradlew); \
	    cd $(GHIDRA_HOME)/support/gradle && $(WITH_JDK) $$gradle --no-daemon --quiet buildNatives; \
	    test -x "$(GHIDRA_HOME)/Ghidra/Features/Decompiler/build/os/$(GHIDRA_PLATFORM)/decompile"; \
	fi
	touch $@

# --- SPIRV-Cross (only needed to regenerate the shaders) ----------------------------------------

SPIRV_CROSS_ARCHIVE := $(DOWNLOADS_DIR)/SPIRV-Cross-$(SPIRV_CROSS_VERSION).tar.gz
SPIRV_CROSS_URL     := https://github.com/KhronosGroup/SPIRV-Cross/archive/refs/tags/$(SPIRV_CROSS_VERSION).tar.gz

$(SPIRV_CROSS_ARCHIVE): | $(DOWNLOADS_DIR)
	$(CURL) --output $@ "$(SPIRV_CROSS_URL)"
	scripts/verify-hash.sh sha256 $(SPIRV_CROSS_SHA256) $@

.PHONY: spirv-cross
spirv-cross: $(SPIRV_CROSS) ## SPIRV-Cross, which `make shaders` needs, built from source

# Its command-line tool, built from its sources with Zig's C++ compiler.
$(SPIRV_CROSS): $(SPIRV_CROSS_ARCHIVE)
	rm -rf $(TOOLS_DIR)/spirv-cross && mkdir -p $(TOOLS_DIR)/spirv-cross
	tar -xzf $(SPIRV_CROSS_ARCHIVE) -C $(TOOLS_DIR)/spirv-cross --strip-components 1
	cd $(TOOLS_DIR)/spirv-cross && $(ZIG) c++ -O2 -std=c++14 -w -o spirv-cross main.cpp spirv_cfg.cpp \
	    spirv_cross.cpp spirv_cross_parsed_ir.cpp spirv_cross_util.cpp spirv_parser.cpp \
	    spirv_glsl.cpp spirv_hlsl.cpp spirv_msl.cpp spirv_cpp.cpp spirv_reflect.cpp

# --- Maven (only needed to build the GhydraMCP plugin) ----------------------------------------

MAVEN_ARCHIVE := $(DOWNLOADS_DIR)/apache-maven-$(MAVEN_VERSION)-bin.tar.gz
MAVEN_URL     := https://downloads.apache.org/maven/maven-3/$(MAVEN_VERSION)/binaries/$(notdir $(MAVEN_ARCHIVE))

$(MAVEN_ARCHIVE): | $(DOWNLOADS_DIR)
	$(CURL) --output $@ "$(MAVEN_URL)"
	scripts/verify-hash.sh sha512 $(MAVEN_SHA512) $@

$(MAVEN_STAMP): | $(MAVEN_ARCHIVE) $(STAMPS_DIR)
	tar -xzf $(MAVEN_ARCHIVE) -C $(TOOLS_DIR)
	touch $@

# --- GhydraMCP --------------------------------------------------------------------------------
#
# Three parts: the Ghidra plugin (HTTP API inside the CodeBrowser), the `ghydra` CLI, and the MCP
# bridge. The bridge is configured in .mcp.json; the other two are installed here.

.PHONY: ghydra
ghydra: $(GHYDRA_PLUGIN_STAMP) $(GHYDRA_CLI_STAMP) ## GhydraMCP: Ghidra plugin + `ghydra` CLI

$(GHYDRA_SRC_STAMP): | $(STAMPS_DIR)
	if [ -d $(GHYDRA_SRC)/.git ]; then \
	    git -C $(GHYDRA_SRC) fetch --quiet --tags origin; \
	else \
	    git clone --quiet $(GHYDRA_REPO) $(GHYDRA_SRC); \
	fi
	git -C $(GHYDRA_SRC) -c advice.detachedHead=false checkout --quiet $(GHYDRA_REF)
	touch $@

# Ghidra 12.2 removed the two-argument overload for deleting one data type.
ifeq ($(GHIDRA_VERSION),12.2)
GHYDRA_PLUGIN_PATCH := $(ROOT)/mk/ghydramcp-ghidra-12.2.patch
endif

# Build against our exact Ghidra, install like File > Install Extensions would, and switch the
# plugin on in the CodeBrowser tool so it needs no clicking through Ghidra's configure dialogs.
$(GHYDRA_PLUGIN_STAMP): $(GHYDRA_SRC_STAMP) $(GHIDRA_STAMP) $(JDK_STAMP) $(MAVEN_STAMP) $(GHYDRA_PLUGIN_PATCH)
	$(if $(GHYDRA_PLUGIN_PATCH),git -C "$(GHYDRA_SRC)" apply --reverse --check "$(GHYDRA_PLUGIN_PATCH)" 2>/dev/null || git -C "$(GHYDRA_SRC)" apply "$(GHYDRA_PLUGIN_PATCH)")
	rm -f $(GHYDRA_SRC)/target/Ghydra-*.zip
	cd $(GHYDRA_SRC) && $(WITH_JDK) GHIDRA_HOME="$(GHIDRA_HOME)" \
	    $(MAVEN_HOME)/bin/mvn --batch-mode --quiet package -DskipTests -Dghidra.version=$(GHIDRA_VERSION)
	mkdir -p "$(GHIDRA_USER_DIR)/Extensions"
	rm -rf "$(GHIDRA_USER_DIR)/Extensions/Ghydra"
	unzip -q -o "$$(ls $(GHYDRA_SRC)/target/Ghydra-*.zip | grep -v Complete)" -d "$(GHIDRA_USER_DIR)/Extensions"
	scripts/seed-codebrowser-tool.sh "$(GHIDRA_HOME)" "$(GHIDRA_USER_DIR)"
	touch $@

$(GHYDRA_CLI_STAMP): $(GHYDRA_SRC_STAMP)
	uv venv --quiet --allow-existing --python $(GHYDRA_PYTHON_VERSION) $(VENV_DIR)
	uv pip install --quiet --python $(VENV_DIR)/bin/python $(GHYDRA_SRC)
	$(VENV_DIR)/bin/ghydra --version
	touch $@

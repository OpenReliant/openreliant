# The game itself, all of it under game/ (git-ignored; none of it is ours to redistribute).
#
#   game/discs/disc<N>.bin   raw images of your own discs, which you supply
#   game/cd<N>/              the files on each disc
#   game/install/            what the installer puts on disk: LANCER.CAB unpacked, plus the
#                            loader and language DLLs it copies from the disc
#   game/decrypted/          the game executable with its code readable, which you supply
#   game/assets/<archive>/   the contents of each .HOG, decompressed
#   game/models/             the .SHP models as Wavefront OBJ
#   game/sprites/            the .SPR shapes as PNG
#   game/textures/           the hardware texture cache's textures as PNG
#   game/sounds/             the .fat sound banks' sounds as WAV
#   game/fonts/              the .fnt fonts as glyph atlases
#   game/renders/            reference images drawn by sltool render
#
# sltool reads the discs' raw sectors and ISO 9660 itself; `openreliant install` installs the game
# from both discs, as a player does.

##@ Game files

DISCS_DIR     := $(GAME_DIR)/discs
INSTALL_DIR   := $(GAME_DIR)/install
DECRYPTED_DIR := $(GAME_DIR)/decrypted

# The game executable with its code readable, which the Ghidra project and tablegen read. The
# repository provides no means of producing it.
PAYLOAD := $(DECRYPTED_DIR)/LANCER.EXE

ASSETS_DIR := $(GAME_DIR)/assets

# The archives worth unpacking by default: resource.hog holds the models, sprites, images,
# missions and stat tables. The disc archives are mostly video and the speech archive is large.
HOG_ARCHIVES := install/resource.hog install/pilots/pilots.hog

.PHONY: game
game: $(GAME_DIR)/.stamp-install $(GAME_DIR)/.stamp-cd2 ## Unpack your disc images

.PHONY: assets
assets: $(addprefix $(GAME_DIR)/.stamp-hog-,$(notdir $(basename $(HOG_ARCHIVES)))) ## Extract the .HOG archives into game/assets

$(GAME_DIR)/.stamp-hog-%: | $(GAME_DIR)/.stamp-install $(SLTOOL)
	$(SLTOOL) hog extract $(firstword $(filter %/$*.hog,$(addprefix $(GAME_DIR)/,$(HOG_ARCHIVES)))) $(ASSETS_DIR)/$*
	touch $@

MODELS_DIR := $(GAME_DIR)/models

.PHONY: models
models: $(GAME_DIR)/.stamp-models ## Export every .SHP model to game/models as Wavefront OBJ

$(GAME_DIR)/.stamp-models: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL)
	mkdir -p $(MODELS_DIR)
	@count=0; for f in $(ASSETS_DIR)/resource/*.[sS][hH][pP]; do \
	    name=$$(basename "$$f"); \
	    $(SLTOOL) shp obj "$$f" "$(MODELS_DIR)/$${name%.*}.obj" > /dev/null; \
	    count=$$((count + 1)); \
	done; echo "exported $$count models to $(MODELS_DIR)"
	touch $@

SPRITES_DIR := $(GAME_DIR)/sprites

.PHONY: sprites
sprites: $(GAME_DIR)/.stamp-sprites ## Export every .SPR shape to game/sprites as PNG

$(GAME_DIR)/.stamp-sprites: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL)
	mkdir -p $(SPRITES_DIR)
	@for f in $(ASSETS_DIR)/resource/*.[sS][pP][rR]; do \
	    $(SLTOOL) spr extract "$$f" $(SPRITES_DIR) > /dev/null; \
	done; echo "exported $$(ls $(SPRITES_DIR) | wc -l | tr -d ' ') images to $(SPRITES_DIR)"
	touch $@

TEXTURES_DIR := $(GAME_DIR)/textures

# Palette indices are looked up in the in-flight palette; the loadout screen's textures use
# palette3.tga instead. See docs/formats/tcache.md.
.PHONY: textures
textures: $(GAME_DIR)/.stamp-textures ## Export the hardware texture cache to game/textures as PNG

$(GAME_DIR)/.stamp-textures: | $(GAME_DIR)/.stamp-install $(GAME_DIR)/.stamp-hog-resource $(SLTOOL)
	$(SLTOOL) tcache extract $(INSTALL_DIR)/tcachehw.dat $(ASSETS_DIR)/resource/palette.tga $(TEXTURES_DIR)
	touch $@

SOUNDS_DIR := $(GAME_DIR)/sounds

.PHONY: sounds
sounds: $(GAME_DIR)/.stamp-sounds ## Export every .fat sound bank's sounds to game/sounds as WAV

$(GAME_DIR)/.stamp-sounds: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL)
	mkdir -p $(SOUNDS_DIR)
	@for f in $(ASSETS_DIR)/resource/*.[fF][aA][tT]; do \
	    $(SLTOOL) fat extract "$$f" $(SOUNDS_DIR) > /dev/null; \
	done; echo "exported $$(ls $(SOUNDS_DIR) | wc -l | tr -d ' ') sounds to $(SOUNDS_DIR)"
	touch $@

FONTS_DIR := $(GAME_DIR)/fonts

.PHONY: fonts
fonts: $(GAME_DIR)/.stamp-fonts ## Render every .fnt font to game/fonts as a PNG glyph atlas

$(GAME_DIR)/.stamp-fonts: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL)
	mkdir -p $(FONTS_DIR)
	@for f in $(ASSETS_DIR)/resource/*.[fF][nN][tT]; do \
	    name=$$(basename "$$f"); \
	    $(SLTOOL) fnt render "$$f" $(FONTS_DIR)/$${name%.*}.png > /dev/null; \
	done; echo "rendered $$(ls $(FONTS_DIR) | wc -l | tr -d ' ') fonts to $(FONTS_DIR)"
	touch $@

RENDERS_DIR := $(GAME_DIR)/renders
RENDER      := $(SLTOOL) render $(ASSETS_DIR)/resource $(INSTALL_DIR)/tcachehw.dat
RENDERS     := $(RENDERS_DIR)/predator.png $(RENDERS_DIR)/predator-sun.png

# Drawn again whenever the code changes. See docs/port/renderer.md.
.PHONY: render
render: $(RENDERS) ## Draw reference images of the Predator against the backdrop to game/renders

$(RENDERS): $(SLTOOL) | $(GAME_DIR)/.stamp-install $(GAME_DIR)/.stamp-hog-resource

$(RENDERS_DIR)/predator.png:
	$(RENDER) $@ --model USLF_Prd.SHP

$(RENDERS_DIR)/predator-sun.png:
	$(RENDER) $@ --model USLF_Prd.SHP --toward 1,-0.3,0.45 --heading -0.3,0.2,1

.PHONY: check-missions
check-missions: | $(GAME_DIR)/.stamp-hog-resource $(GAME_DIR)/.stamp-install $(SLTOOL) ## Parse, write again and bind every .DTE mission, and check the mission guide's change to mission 1
	@bad=0; for f in $(ASSETS_DIR)/resource/*.dte; do \
	    $(SLTOOL) dte info "$$f" > /dev/null && $(SLTOOL) dte check "$$f" > /dev/null || { echo "FAILED: $$f"; bad=$$((bad + 1)); }; \
	done; echo "$$(ls $(ASSETS_DIR)/resource/*.dte | wc -l | tr -d ' ') missions checked, $$bad with problems"
	@$(OPENRELIANT) missions $(INSTALL_DIR) | tail -1
	@scripts/check-mission-guide.sh $(SLTOOL) $(ASSETS_DIR)/resource/mission1.dte docs/guide/missions.md

.PHONY: check-models
check-models: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL) ## Validate every .SHP model, and write each again
	@bad=0; for f in $(ASSETS_DIR)/resource/*.[sS][hH][pP]; do \
	    $(SLTOOL) shp check "$$f" > /dev/null || { echo "FAILED: $$f"; bad=$$((bad + 1)); }; \
	done; echo "$$(ls $(ASSETS_DIR)/resource/*.[sS][hH][pP] | wc -l | tr -d ' ') models checked, $$bad with problems"

$(DISCS_DIR):
	mkdir -p $@

# Supply your own images of your own discs. A zip holding one is unpacked for convenience, and
# removed again once the disc has been extracted; an image you placed here yourself is left alone.
.INTERMEDIATE: $(DISCS_DIR)/disc1.bin $(DISCS_DIR)/disc2.bin
$(DISCS_DIR)/disc%.bin: | $(DISCS_DIR)
	@test -f $(DISCS_DIR)/disc$*.zip || { \
	    echo "missing $@"; \
	    echo "  Place your own image of disc $* here: a raw .bin (2352-byte sectors) or an .iso,"; \
	    echo "  or a .zip containing one, named disc$*.zip."; \
	    exit 1; }
	unzip -p $(DISCS_DIR)/disc$*.zip '*.bin' '*.iso' > $@

# Extracting the discs and installing the game need sltool and openreliant to be there, not to be
# current. They are order-only, since rebuilding them must not extract or install the game again,
# which would in turn make every later step look stale. They are also built only when they are
# missing (`present`), so that `make play` builds the game once, in its own mode, rather than first
# as `make build` does after every change.
present = $(if $(wildcard $(1)),,$(1))

$(GAME_DIR)/.stamp-cd%: $(DISCS_DIR)/disc%.bin | $(call present,$(SLTOOL))
	rm -rf $(GAME_DIR)/cd$*
	$(SLTOOL) cd extract $< $(GAME_DIR)/cd$*
	touch $@

$(GAME_DIR)/.stamp-install: $(GAME_DIR)/.stamp-cd1 $(GAME_DIR)/.stamp-cd2 | $(call present,$(OPENRELIANT))
	rm -rf $(INSTALL_DIR)
	$(OPENRELIANT) install --from $(GAME_DIR)/cd1 --from $(GAME_DIR)/cd2 $(INSTALL_DIR) > /dev/null
	touch $@

$(PAYLOAD):
	@echo "missing $@" >&2
	@echo "  The analysis reads the game executable, with its code readable, from here." >&2
	@echo "  This repository does not provide one." >&2
	@exit 1

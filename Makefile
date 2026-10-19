# J2ME content pak for Leaf.
#
# A clean clone of this repository plus Docker, make, and python3 is the whole
# toolchain. Nothing here reaches outside the repository: no sibling checkouts,
# no UMRK workspace layout, no locally built images. If a target of yours needs
# a path starting with ../, it does not belong in this file.
#
#   make core           build the pinned FreeJ2ME-Plus libretro core (patched)
#   make runtime        build the pinned jar and the jlink-trimmed Java runtime
#   make package-mlp1   assemble build/package/J2ME.pak
#   make dist-pakrat    zip it into build/dist/J2ME.mlp1.pak.zip
#   make dist-source    GPL corresponding source for the core, the jar and the runtime
#   make validate       check pak.json against the content-pak contract
#   make smoke          run the packaged core in an arm64 container (no device)
#   make check          validate + package + validate the packaged tree + smoke
#   make clean          remove build/ outputs (keeps the cached sources and downloads)
#   make distclean      remove build/ entirely, including the source clone and downloads

SHELL := /bin/bash
REPO_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD ?= $(REPO_ROOT)/build
PACKAGE := $(BUILD)/package/J2ME.pak
DIST := $(BUILD)/dist
ARTIFACT := $(DIST)/J2ME.mlp1.pak.zip

# The contract this pak is validated against: content-paks-v1, its schema, and
# its reference validator, in the public leaf-contracts repository. CI pins
# the same SHA; a local clone is fine for development.
CONTRACT_REPO ?= https://github.com/Utility-Muffin-Research-Kitchen/leaf-contracts.git
CONTRACT_REF ?= b74130056342efdd6bdeb9ed7204968dd294fbde
CONTRACT_DIR ?= $(BUILD)/contract

.PHONY: all core verify-core runtime verify-runtime package-mlp1 dist-pakrat dist-source validate smoke check clean distclean help

all: dist-pakrat

help:
	@sed -n '1,17p' $(lastword $(MAKEFILE_LIST))

core:
	@"$(REPO_ROOT)/core/build-core.sh"

verify-core:
	@FORCE=1 "$(REPO_ROOT)/core/build-core.sh"

runtime:
	@"$(REPO_ROOT)/runtime/build-runtime.sh"

verify-runtime:
	@FORCE=1 "$(REPO_ROOT)/runtime/build-runtime.sh"

# The jar and the runtime sit beside the core because that is where the Leaf
# patch looks for them. Uninstalling the pak removes all three with it, and
# nothing goes into the shared BIOS folder.
package-mlp1: core runtime
	@rm -rf "$(PACKAGE)"
	@mkdir -p "$(PACKAGE)/cores" "$(PACKAGE)/info" "$(PACKAGE)/art"
	@cp "$(REPO_ROOT)/pak/pak.json" "$(PACKAGE)/pak.json"
	@cp "$(REPO_ROOT)/pak/art/J2ME.png" "$(PACKAGE)/art/J2ME.png"
	@cp "$(REPO_ROOT)/pak/art/J2ME-photo.png" "$(PACKAGE)/art/J2ME-photo.png"
	@cp "$(REPO_ROOT)/pak/art/J2ME-grid.png" "$(PACKAGE)/art/J2ME-grid.png"
	@cp "$(REPO_ROOT)/pak/art/GRID-ICON-SOURCE.md" "$(PACKAGE)/art/GRID-ICON-SOURCE.md"
	@cp "$(REPO_ROOT)/pak/art/J2ME-wordmark.png" "$(PACKAGE)/art/J2ME-wordmark.png"
	@cp "$(REPO_ROOT)/pak/art/WORDMARK-SOURCE.md" "$(PACKAGE)/art/WORDMARK-SOURCE.md"
	@cp "$(REPO_ROOT)/pak/art/LICENSE-ASSETS.md" "$(PACKAGE)/art/LICENSE-ASSETS.md"
	@cp "$(BUILD)/core/freej2me_plus_libretro.so" "$(PACKAGE)/cores/freej2me_plus_libretro.so"
	@cp "$(BUILD)/core/freej2me_plus_libretro.info" "$(PACKAGE)/info/freej2me_plus_libretro.info"
	@cp "$(BUILD)/runtime/freej2me_plus-lr.jar" "$(PACKAGE)/cores/freej2me_plus-lr.jar"
	@cp -Rp "$(BUILD)/runtime/jre" "$(PACKAGE)/cores/jre"
	@# Non-ASCII ROM paths: the jlink runtime carries no locale data, so start
	@# the JVM through a shim that points glibc at the bundled C.utf8 locale.
	@mv "$(PACKAGE)/cores/jre/bin/java" "$(PACKAGE)/cores/jre/bin/java.real"
	@cp "$(REPO_ROOT)/runtime/overlay/java" "$(PACKAGE)/cores/jre/bin/java"
	@chmod 755 "$(PACKAGE)/cores/jre/bin/java" "$(PACKAGE)/cores/jre/bin/java.real"
	@mkdir -p "$(PACKAGE)/cores/jre/locale"
	@cp -R "$(REPO_ROOT)/runtime/overlay/locale/C.utf8" "$(PACKAGE)/cores/jre/locale/"
	@cp "$(REPO_ROOT)/LICENSES/CORE-LICENSE.txt" "$(PACKAGE)/LICENSE-CORE.txt"
	@cp "$(REPO_ROOT)/LICENSES/RUNTIME-LICENSE.txt" "$(PACKAGE)/LICENSE-RUNTIME.txt"
	@echo "packaged $(PACKAGE)"
	@echo "note: no launch.sh -- this is a pure content pak and is not listed in Apps."

dist-pakrat: package-mlp1
	@mkdir -p "$(DIST)"
	@rm -f "$(ARTIFACT)"
	@cd "$(BUILD)/package" && zip -q -r -X "$(ARTIFACT)" "J2ME.pak"
	@python3 -c "import hashlib,sys;p=sys.argv[1];print('sha256', hashlib.sha256(open(p,'rb').read()).hexdigest())" "$(ARTIFACT)"
	@echo "wrote $(ARTIFACT)"

# GPL corresponding source for every binary the pak ships: one archive for the
# core and the jar, built from the pinned FreeJ2ME-Plus commit, and Adoptium's
# own source tarball for the Java runtime. Publish both next to the artifact;
# a written offer is weaker than the source.
dist-source:
	@mkdir -p "$(DIST)"
	@SRC_DIR="$$("$(REPO_ROOT)/scripts/fetch-source.sh")" && \
	  python3 "$(REPO_ROOT)/scripts/make-source-archive.py" \
		--repo "$(REPO_ROOT)" \
		--source "$$SRC_DIR" \
		--output "$(DIST)/freej2me-plus-corresponding-source.tar.gz"
	@RUNTIME_SRC="$$("$(REPO_ROOT)/runtime/fetch-runtime-source.sh")" && \
	  cp "$$RUNTIME_SRC" "$(DIST)/$$(basename "$$RUNTIME_SRC")" && \
	  echo "wrote $(DIST)/$$(basename "$$RUNTIME_SRC") (sha256 checked against runtime.lock.json)"
	@cp "$(REPO_ROOT)/core/core.lock.json" "$(DIST)/core.lock.json"
	@cp "$(REPO_ROOT)/runtime/runtime.lock.json" "$(DIST)/runtime.lock.json"
	@python3 -c "import hashlib,sys;p=sys.argv[1];print('sha256', hashlib.sha256(open(p,'rb').read()).hexdigest())" \
		"$(DIST)/freej2me-plus-corresponding-source.tar.gz"
	@echo "wrote $(DIST)/freej2me-plus-corresponding-source.tar.gz"

$(CONTRACT_DIR):
	@mkdir -p "$(BUILD)"
	@echo "fetching contract $(CONTRACT_REF) from $(CONTRACT_REPO)"
	@(git init -q "$(CONTRACT_DIR)" && \
	  git -C "$(CONTRACT_DIR)" fetch -q --depth 1 "$(CONTRACT_REPO)" "$(CONTRACT_REF)" && \
	  git -C "$(CONTRACT_DIR)" checkout -q --detach FETCH_HEAD) \
		|| (rm -rf "$(CONTRACT_DIR)"; \
		    echo ""; \
		    echo "could not fetch the content-pak contract." >&2; \
		    echo "" >&2; \
		    echo "  It lives in the public leaf-contracts repository. If you have" >&2; \
		    echo "  a local clone, point at it:" >&2; \
		    echo "" >&2; \
		    echo "      make validate CONTRACT_DIR=/path/to/leaf-contracts" >&2; \
		    echo "" >&2; \
		    echo "  Otherwise check your network. Every other target in this" >&2; \
		    echo "  repository is self-contained and still works offline once" >&2; \
		    echo "  build/downloads holds the pinned archives." >&2; \
		    echo "" >&2; \
		    exit 1)

validate: | $(CONTRACT_DIR)
	@python3 "$(REPO_ROOT)/scripts/validate-pak.py" \
		--contract "$(CONTRACT_DIR)" --pak "$(REPO_ROOT)/pak"

smoke:
	@"$(REPO_ROOT)/tests/smoke-core.sh"

check: validate package-mlp1
	@python3 "$(REPO_ROOT)/scripts/validate-pak.py" \
		--contract "$(CONTRACT_DIR)" --pak "$(PACKAGE)" --packaged
	@"$(REPO_ROOT)/tests/smoke-core.sh"

clean:
	@rm -rf "$(BUILD)/package" "$(BUILD)/dist" "$(BUILD)/contract" "$(BUILD)/runtime-work"

distclean:
	@rm -rf "$(BUILD)"

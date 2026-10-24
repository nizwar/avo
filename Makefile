# Common tasks. Run `make help` for the list.

DERIVED ?= build/DerivedData

.PHONY: help test project build strings agent helpers gfxstream proto icons clean

help:
	@echo "make test     run the host core tests (swift test)"
	@echo "make project  generate host/Avo.xcodeproj (XcodeGen)"
	@echo "make build    build Avo.app (Debug) into $(DERIVED)"
	@echo "make strings  update the String Catalogs from the last build"
	@echo "make agent    build the Bridge Agent APK (Android SDK + NDK)"
	@echo "make helpers  rebuild the guest helpers embedded in the daemon (clipboard, links, macstate, fingerprint, gpuprofile, gfxsync, widgets)"
	@echo "make gfxstream  build the GPU renderer Avo.app ships (gfxstream, Vulkan loader, MoltenVK) into build/gfxstream"
	@echo "make proto    regenerate protocol bindings"
	@echo "make icons    regenerate brand assets"

test:
	cd host/AvoKit && swift test
	cd vendor/avo_kit && swift test

project:
	cd host && xcodegen generate

build: project
	xcodebuild -project host/Avo.xcodeproj -scheme Avo -configuration Debug -derivedDataPath $(DERIVED) build

strings:
	scripts/sync-strings.sh $(DERIVED)

agent:
	guest/bridge-agent/build.sh

helpers:
	guest/clipboard/build.sh
	guest/links/build.sh
	guest/macstate/build.sh
	guest/fingerprint/build.sh
	guest/gpuprofile/build.sh
	guest/glwrap/build.sh
	guest/gfxsync/build.sh
	guest/widgets/build.sh

gfxstream:
	scripts/build-gfxstream.sh

proto:
	scripts/gen-proto.sh

icons:
	python3 -I branding/tools/generate.py

clean:
	rm -rf $(DERIVED) host/AvoKit/.build guest/bridge-agent/build guest/clipboard/build guest/links/build guest/macstate/build

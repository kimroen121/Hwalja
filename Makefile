.PHONY: engine test test-rust test-swift app run dist clean
SWIFT_ARCHS ?= arm64
SWIFT_FLAGS = -c release $(foreach a,$(SWIFT_ARCHS),--arch $(a))

engine:
	./scripts/build-engine.sh

test: test-rust test-swift
test-rust:
	bash scripts/prepare-engine.sh
	cargo test --manifest-path Engine/Cargo.toml --locked --workspace
test-swift: engine
	swift test

app: engine
	swift build $(SWIFT_FLAGS)
	./scripts/bundle-app.sh "$$(swift build $(SWIFT_FLAGS) --show-bin-path)/HwpStudio"
run: app
	open build/HwpStudio.app

# Universal, Developer ID-signed, notarized zip. Needs SIGN_IDENTITY and a
# notarytool profile: xcrun notarytool store-credentials hwpstudio
dist:
	HWP_ENGINE_TARGETS="aarch64-apple-darwin x86_64-apple-darwin" $(MAKE) app SWIFT_ARCHS="arm64 x86_64"
	ditto -c -k --keepParent build/HwpStudio.app build/HwpStudio.zip
	xcrun notarytool submit build/HwpStudio.zip --keychain-profile hwpstudio --wait
	xcrun stapler staple build/HwpStudio.app
	ditto -c -k --keepParent build/HwpStudio.app build/HwpStudio.zip

clean:
	rm -rf .build build Engine/target Engine/include/HwpEngineABI.h

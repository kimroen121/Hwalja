.PHONY: engine test test-rust test-swift fmt-check compare-pages app run dist clean
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
fmt-check:
	git ls-files -z 'Engine/**/*.rs' | xargs -0 rustfmt --edition 2021 --check
compare-pages:
	mkdir -p .build/compare-module-cache
	swift -module-cache-path .build/compare-module-cache scripts/compare-pages.swift "$(REF_DIR)" "$(ACTUAL_DIR)" $(COMPARE_FLAGS)

app: engine
	swift build $(SWIFT_FLAGS)
	./scripts/bundle-app.sh "$$(swift build $(SWIFT_FLAGS) --show-bin-path)/Hwalja"
run: app
	open build/hwalja.app

# Universal, Developer ID-signed, notarized zip. Needs SIGN_IDENTITY and a
# notarytool profile: xcrun notarytool store-credentials hwalja
dist:
	HWP_ENGINE_TARGETS="aarch64-apple-darwin x86_64-apple-darwin" $(MAKE) app SWIFT_ARCHS="arm64 x86_64"
	ditto -c -k --keepParent build/hwalja.app build/hwalja.zip
	xcrun notarytool submit build/hwalja.zip --keychain-profile hwalja --wait
	xcrun stapler staple build/hwalja.app
	ditto -c -k --keepParent build/hwalja.app build/hwalja.zip

clean:
	rm -rf .build build Engine/target Engine/include/HwpEngineABI.h

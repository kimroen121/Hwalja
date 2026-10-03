.PHONY: bootstrap engine test-bootstrap test-rust test-abi build-clt clean
bootstrap: engine
	xcodegen generate
	xcodebuild build -scheme HwpStudio -destination 'platform=macOS' -derivedDataPath DerivedData
engine:
	./scripts/build-engine.sh
test-rust:
	cargo test --manifest-path Engine/Cargo.toml --locked --workspace
test-abi: engine
	clang -I Generated Tests/ABI/abi_smoke.c build/libhwp_engine_abi.a -o build/abi-smoke
	./build/abi-smoke
test-bootstrap: test-rust test-abi
	lipo build/libhwp_engine_abi.a -verify_arch arm64
	lipo build/libhwp_engine_abi.a -verify_arch x86_64
	xcodebuild test -scheme HwpStudio -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:HwpStudioTests/AppLaunchTests
build-clt:
	mkdir -p .build/cache .build/config .build/security .build/clang-cache
	CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/clang-cache" swift build --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
clean:
	swift package clean

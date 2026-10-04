.PHONY: bootstrap engine test-bootstrap test-rust test-abi clean
bootstrap: engine
	xcodegen generate
	xcodebuild build -scheme HwpStudio -destination 'platform=macOS' -derivedDataPath DerivedData
engine:
	./scripts/build-engine.sh
test-rust:
	bash scripts/prepare-engine.sh
	cargo test --manifest-path Engine/Cargo.toml --locked --workspace
test-abi: engine
	clang -I Generated Tests/ABI/abi_smoke.c build/libhwp_engine_abi.a -o build/abi-smoke
	./build/abi-smoke
test-bootstrap: test-rust test-abi
	lipo build/libhwp_engine_abi.a -verify_arch arm64
	lipo build/libhwp_engine_abi.a -verify_arch x86_64
	xcodebuild test -scheme HwpStudio -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:HwpStudioTests/AppLaunchTests
clean:
	xcodebuild clean -scheme HwpStudio

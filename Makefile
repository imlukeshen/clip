.PHONY: bootstrap generate build test test-packages shortcuts lint format clean

bootstrap:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen before continuing"; exit 1; }

generate:
	xcodegen generate

build: generate
	xcodebuild -project Reel.xcodeproj -scheme Reel -configuration Debug CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project Reel.xcodeproj -scheme Reel-AppStore -configuration AppStoreDebug CODE_SIGNING_ALLOWED=NO build

test: test-packages shortcuts

test-packages:
	swift test --package-path Packages/CoreModel
	swift test --package-path Packages/LibraryStore
	swift test --package-path Packages/CaptureKit
	swift test --package-path Packages/DesignSystem
	swift test --package-path App/Reel

shortcuts:
	Scripts/check-no-hardcoded-shortcuts.sh

lint:
	xcrun swift-format lint --strict --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests Packages/CaptureKit/Sources Packages/CaptureKit/Tests Packages/DesignSystem/Sources Packages/DesignSystem/Tests App/Reel/Sources App/Reel/Tests

format:
	xcrun swift-format format --in-place --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests Packages/CaptureKit/Sources Packages/CaptureKit/Tests Packages/DesignSystem/Sources Packages/DesignSystem/Tests App/Reel/Sources App/Reel/Tests

clean:
	rm -rf Reel.xcodeproj DerivedData

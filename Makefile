.PHONY: bootstrap generate build test test-packages deps shortcuts licence-audit distribution-check lint format ffmpeg licences release clean

bootstrap:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen before continuing"; exit 1; }

generate:
	xcodegen generate

build: generate
	xcodebuild -project Reel.xcodeproj -scheme Reel -configuration Debug CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project Reel.xcodeproj -scheme Reel-AppStore -configuration AppStoreDebug CODE_SIGNING_ALLOWED=NO build

test: test-packages deps shortcuts licence-audit

test-packages:
	swift test --package-path Packages/CoreModel
	swift test --package-path Packages/LibraryStore
	swift test --package-path Packages/CaptureKit
	swift test --package-path Packages/ConvertKit
	swift test --package-path Packages/MediaEngine
	swift test --package-path Packages/AIKit
	swift test --package-path Packages/DesignSystem
	swift test --package-path App/Reel

deps:
	Scripts/check-aikit-dependencies.sh

shortcuts:
	Scripts/check-no-hardcoded-shortcuts.sh

licence-audit:
	Scripts/check-licenses.sh

distribution-check:
	Scripts/check-distribution.sh

lint:
	xcrun swift-format lint --strict --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests Packages/CaptureKit/Sources Packages/CaptureKit/Tests Packages/ConvertKit/Sources Packages/ConvertKit/Tests Packages/MediaEngine/Sources Packages/MediaEngine/Tests Packages/AIKit/Sources Packages/AIKit/Tests Packages/DesignSystem/Sources Packages/DesignSystem/Tests App/Reel/Sources App/Reel/Tests

format:
	xcrun swift-format format --in-place --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests Packages/CaptureKit/Sources Packages/CaptureKit/Tests Packages/ConvertKit/Sources Packages/ConvertKit/Tests Packages/MediaEngine/Sources Packages/MediaEngine/Tests Packages/AIKit/Sources Packages/AIKit/Tests Packages/DesignSystem/Sources Packages/DesignSystem/Tests App/Reel/Sources App/Reel/Tests

ffmpeg:
	Scripts/build-ffmpeg.sh

licences:
	Scripts/licences.sh

release:
	Scripts/release.sh

clean:
	rm -rf Reel.xcodeproj DerivedData

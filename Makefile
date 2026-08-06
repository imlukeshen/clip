.PHONY: bootstrap generate xcode build run test test-packages test-frameworks test-app test-ui deps shortcuts licence-audit distribution-check lint format ffmpeg licences release clean

bootstrap:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen before continuing"; exit 1; }

generate:
	@# Reel.xcodeproj predates the Clip rename. Keeping both projects open makes
	@# Xcode load every local Swift package twice and report workspace conflicts.
	@rm -rf Reel.xcodeproj
	xcodegen generate
	@# Seed Xcode with the reviewed lock for the complete generated project graph.
	@mkdir -p Clip.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
	@cp App/Clip.Package.resolved Clip.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

xcode: generate
	open Clip.xcodeproj

build: generate
	xcodebuild -project Clip.xcodeproj -scheme Clip -configuration Debug -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project Clip.xcodeproj -scheme Clip-AppStore -configuration AppStoreDebug -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build

run: generate
	xcodebuild -project Clip.xcodeproj -scheme Clip -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -quiet build
	open -n DerivedData/Build/Products/Debug/Clip.app

test: test-packages deps shortcuts licence-audit

test-packages: test-frameworks test-app

test-frameworks:
	swift test --package-path Packages/CoreModel
	swift test --package-path Packages/LibraryStore
	swift test --package-path Packages/CaptureKit
	swift test --package-path Packages/ConvertKit
	swift test --package-path Packages/MediaEngine
	swift test --package-path Packages/PDFEngine
	swift test --package-path Packages/TextEngine
	swift test --package-path Packages/SearchEngine
	swift test --package-path Packages/AIKit
	swift test --package-path Packages/DesignSystem

test-app:
	swift test --package-path App/Reel

test-ui: generate
	@rm -rf TestResults/ClipUITests.xcresult
	@mkdir -p TestResults
	xcodebuild test -project Clip.xcodeproj -scheme Clip -configuration Debug -destination 'platform=macOS' -disableAutomaticPackageResolution -resultBundlePath TestResults/ClipUITests.xcresult CODE_SIGNING_ALLOWED=NO

deps:
	Scripts/check-aikit-dependencies.sh

shortcuts:
	Scripts/check-no-hardcoded-shortcuts.sh

licence-audit:
	Scripts/check-licenses.sh

distribution-check:
	Scripts/check-distribution.sh

lint:
	xcrun swift-format lint --strict --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests Packages/CaptureKit/Sources Packages/CaptureKit/Tests Packages/ConvertKit/Sources Packages/ConvertKit/Tests Packages/MediaEngine/Sources Packages/MediaEngine/Tests Packages/TextEngine/Sources Packages/TextEngine/Tests Packages/SearchEngine/Sources Packages/SearchEngine/Tests Packages/AIKit/Sources Packages/AIKit/Tests Packages/DesignSystem/Sources Packages/DesignSystem/Tests App/Reel/Sources App/Reel/Tests App/Reel/UITests

format:
	xcrun swift-format format --in-place --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests Packages/CaptureKit/Sources Packages/CaptureKit/Tests Packages/ConvertKit/Sources Packages/ConvertKit/Tests Packages/MediaEngine/Sources Packages/MediaEngine/Tests Packages/TextEngine/Sources Packages/TextEngine/Tests Packages/SearchEngine/Sources Packages/SearchEngine/Tests Packages/AIKit/Sources Packages/AIKit/Tests Packages/DesignSystem/Sources Packages/DesignSystem/Tests App/Reel/Sources App/Reel/Tests App/Reel/UITests

ffmpeg:
	Scripts/build-ffmpeg.sh

licences:
	Scripts/licences.sh

release:
	Scripts/release.sh

clean:
	rm -rf Clip.xcodeproj Reel.xcodeproj DerivedData

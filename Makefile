.PHONY: test test-packages lint format

test: test-packages

test-packages:
	swift test --package-path Packages/CoreModel
	swift test --package-path Packages/LibraryStore
	swift test --package-path Packages/CaptureKit
	swift test --package-path App/Reel

lint:
	xcrun swift-format lint --strict --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests Packages/CaptureKit/Sources Packages/CaptureKit/Tests App/Reel/Sources App/Reel/Tests

format:
	xcrun swift-format format --in-place --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests Packages/CaptureKit/Sources Packages/CaptureKit/Tests App/Reel/Sources App/Reel/Tests

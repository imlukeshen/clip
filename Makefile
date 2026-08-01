.PHONY: test test-packages lint format

test: test-packages

test-packages:
	swift test --package-path Packages/CoreModel
	swift test --package-path Packages/LibraryStore

lint:
	xcrun swift-format lint --strict --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests

format:
	xcrun swift-format format --in-place --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests Packages/LibraryStore/Sources Packages/LibraryStore/Tests

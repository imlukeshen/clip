.PHONY: test test-packages lint format

test: test-packages

test-packages:
	swift test --package-path Packages/CoreModel

lint:
	xcrun swift-format lint --strict --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests

format:
	xcrun swift-format format --in-place --recursive Packages/CoreModel/Sources Packages/CoreModel/Tests

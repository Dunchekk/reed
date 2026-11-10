.PHONY: ios-project ios-build swift-test server-check

ios-project:
	xcodegen generate --spec ios/project.yml

ios-build: ios-project
	xcodebuild -project ios/Reed.xcodeproj -scheme Reed -destination 'generic/platform=iOS Simulator' -derivedDataPath .local/DerivedData CODE_SIGNING_ALLOWED=NO build

swift-test:
	swift test --package-path ios/ReedCore --scratch-path .local/swift-build

server-check:
	npm run typecheck
	npm test
	npm run build

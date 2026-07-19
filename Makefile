DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Documents/DevPlugins

generate: ; xcodegen generate
build: generate ; xcodebuild -scheme LorePlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/LorePlugin.bundle"
	cp -R build/Build/Products/Debug/LorePlugin.bundle "$(DEV_PLUGINS)/LorePlugin.bundle"
test: generate ; xcodebuild -scheme LorePlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
release: ; ./scripts/release.sh $(V)

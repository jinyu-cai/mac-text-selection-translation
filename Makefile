BUNDLE  = Text Selection Translation.app
BIN     = MacTranslator
CONFIG ?= release
VERSION ?= 1.0
BUILD_VERSION ?= $(shell /bin/date +%Y%m%d%H%M%S)
# Code-signing identity. Auto-uses the stable self-signed "MacTranslator Dev"
# cert when present (so the Accessibility grant survives rebuilds); otherwise
# falls back to ad-hoc "-". Create the cert once: ./scripts/create-signing-cert.sh
# Override explicitly with: make app SIGN_ID="Your Identity"
SIGN_ID ?= $(shell security find-identity -p codesigning 2>/dev/null | grep -q "MacTranslator Dev" && echo "MacTranslator Dev" || echo "-")

.PHONY: build app run install clean

## Compile the Swift package
build:
	swift build -c $(CONFIG)

## Assemble a runnable .app bundle (ad-hoc signed)
app: build
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS"
	mkdir -p "$(BUNDLE)/Contents/Resources"
	cp ".build/$(CONFIG)/$(BIN)" "$(BUNDLE)/Contents/MacOS/$(BIN)"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(BUNDLE)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_VERSION)" "$(BUNDLE)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_ID)" "$(BUNDLE)" || true
	@echo "✅ Built $(BUNDLE) version $(VERSION) ($(BUILD_VERSION))"

## Build and launch
run: app
	open "$(BUNDLE)"

## Build and replace the copy in /Applications
install:
	./scripts/install-app.sh

clean:
	rm -rf .build "$(BUNDLE)"

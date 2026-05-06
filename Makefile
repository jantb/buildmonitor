APP_NAME := BitbucketBuildMonitor
PROJECT := BitbucketBuildMonitor.xcodeproj
SCHEME := BitbucketBuildMonitor
CONFIGURATION ?= Release
DERIVED_DATA ?= /private/tmp/$(APP_NAME)DerivedData
INSTALL_DIR ?= /Applications
SIGN_IDENTITY ?= -
ENTITLEMENTS := BitbucketBuildMonitor/BitbucketBuildMonitor.entitlements
APP_BUNDLE := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app

.PHONY: build install sign verify clean

build:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		CODE_SIGN_STYLE=Manual \
		build

install: build
	rm -rf "$(INSTALLED_APP)"
	ditto "$(APP_BUNDLE)" "$(INSTALLED_APP)"
	xattr -dr com.apple.quarantine "$(INSTALLED_APP)" 2>/dev/null || true
	$(MAKE) sign APP_BUNDLE="$(INSTALLED_APP)" SIGN_IDENTITY="$(SIGN_IDENTITY)"
	$(MAKE) verify APP_BUNDLE="$(INSTALLED_APP)"

sign:
	codesign --force --deep --options runtime --entitlements "$(ENTITLEMENTS)" --sign "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"

verify:
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

clean:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		clean

.PHONY: gen build test uitest run release clean

DERIVED := build

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project Ambit.xcodeproj -scheme Ambit -configuration Debug \
		-derivedDataPath $(DERIVED) CURRENT_PROJECT_VERSION=$$(date -u +%Y%m%d%H%M) -quiet build

test:
	swift test

# Drives the built app through its menu bar item. Takes over the pointer and keyboard while it
# runs, so nothing else may be using the screen (another UI test run included).
uitest: gen
	xcodebuild -project Ambit.xcodeproj -scheme Ambit -derivedDataPath $(DERIVED) -quiet test

run: build
	open $(DERIVED)/Build/Products/Debug/Ambit.app

# make release VERSION=0.1.0   (add PUBLISH=1 to upload the DMG and appcast)
release:
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=x.y.z" && exit 1)
	scripts/release.sh $(VERSION)

clean:
	rm -rf $(DERIVED) .build Ambit.xcodeproj App/Info.plist

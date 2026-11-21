.PHONY: gen build test run release clean

DERIVED := build

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project Ambit.xcodeproj -scheme Ambit -configuration Debug \
		-derivedDataPath $(DERIVED) -quiet build

test:
	swift test

run: build
	open $(DERIVED)/Build/Products/Debug/Ambit.app

# make release VERSION=0.1.0   (add PUBLISH=1 to upload the DMG and appcast)
release:
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=x.y.z" && exit 1)
	scripts/release.sh $(VERSION)

clean:
	rm -rf $(DERIVED) .build Ambit.xcodeproj App/Info.plist

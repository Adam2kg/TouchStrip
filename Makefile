BUNDLE   = TouchStrip.app
BINARY   = TouchStrip
BUILD    = .build/release
INSTALL  = /Applications

build:
	swift build -c release

app: build
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BUILD)/$(BINARY) $(BUNDLE)/Contents/MacOS/
	cp Info.plist $(BUNDLE)/Contents/
	xattr -cr $(BUNDLE)
	codesign -f -s "TouchStrip Dev" $(BUNDLE) 2>/dev/null || codesign -f -s - $(BUNDLE)

run: app
	pkill -f "$(BUNDLE)/Contents/MacOS/$(BINARY)" 2>/dev/null || true
	open $(BUNDLE)

install: app
	cp -r $(BUNDLE) $(INSTALL)/
	@echo "Installed to $(INSTALL)/$(BUNDLE)"

clean:
	rm -rf .build $(BUNDLE)

.PHONY: build app run install clean

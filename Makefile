CC := clang
MACOSX_DEPLOYMENT_TARGET ?= 14.0
MACOSX_VERSION_FLAG := -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)
BUILD := build
APP := $(BUILD)/Mica.app
APP_BIN := $(APP)/Contents/MacOS/Mica
APP_ICON := $(APP)/Contents/Resources/Mica.icns
PROJECT_ICON_TOOL := $(BUILD)/mica-project-icon
VOICE_SCRATCH := $(abspath $(BUILD)/swift-build)
VOICE_MODULE_CACHE := $(abspath $(BUILD)/swift-module-cache)
VOICE_BINARY := $(BUILD)/mica-voice
APP_VOICE_HELPER := $(APP)/Contents/Helpers/mica-voice
APP_THIRD_PARTY_NOTICES := $(APP)/Contents/Resources/THIRD_PARTY_NOTICES.md
APP_FONTS := $(APP)/Contents/Resources/Fonts/JetBrainsMono-Regular.ttf
APP_LAUNCHER_SCRIPT := $(APP)/Contents/Resources/Scripts/install-desktop-apps.py
APP_ICON_TOOL := $(APP)/Contents/Helpers/mica-project-icon
VOICE_SWIFT_SOURCES := $(shell find voice/Sources -type f -not -name '.*')
VOICE_LICENSES := $(wildcard voice/ThirdPartyLicenses/*)
CFLAGS ?= -O2
C_WARNINGS := -Wall -Wextra -Wpedantic
OBJC_WARNINGS := -Wall -Wextra -Wno-deprecated-declarations
CPPFLAGS := -Iinclude -Ithird_party/libvterm/include
# libvterm 0.3.3 is vendored (third_party/libvterm, MIT) with robustness patches found by the fuzz tests, and
# linked statically so the bundle runs signed (hardened runtime) and needs no Homebrew libraries.
VTERM_SRCS := $(wildcard third_party/libvterm/src/*.c)
VTERM_HEADERS := $(wildcard third_party/libvterm/src/*.h third_party/libvterm/src/*.inc third_party/libvterm/src/encoding/*.inc third_party/libvterm/include/*.h)
VTERM_OBJS := $(patsubst third_party/libvterm/src/%.c,$(BUILD)/libvterm/%.o,$(VTERM_SRCS))
VTERM_STATIC := $(BUILD)/libvterm.a
VTERM_SAN_OBJS := $(patsubst third_party/libvterm/src/%.c,$(BUILD)/libvterm-san/%.o,$(VTERM_SRCS))
VTERM_SAN_STATIC := $(BUILD)/libvterm-san.a
VTERM_CC_FLAGS := -std=c99 -Ithird_party/libvterm/include -Ithird_party/libvterm/src
$(BUILD)/libvterm/%.o: third_party/libvterm/src/%.c $(VTERM_HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(VTERM_CC_FLAGS) -c $< -o $@
$(VTERM_STATIC): $(VTERM_OBJS)
	@rm -f $@
	ar rcs $@ $^
$(BUILD)/libvterm-san/%.o: third_party/libvterm/src/%.c $(VTERM_HEADERS)
	@mkdir -p $(dir $@)
	$(CC) $(SAN_FLAGS) $(MACOSX_VERSION_FLAG) $(VTERM_CC_FLAGS) -c $< -o $@
$(VTERM_SAN_STATIC): $(VTERM_SAN_OBJS)
	@rm -f $@
	ar rcs $@ $^

CORE := src/session.c
POMODORO := src/pomodoro.c

.PHONY: all app sign dist notarize screenshots ui-audit sanitize fuzz stress test test-voice validate preflight clean run memory desktop-apps install-desktop-apps new-instance

all: app

app: $(APP_FONTS) $(APP_LAUNCHER_SCRIPT) $(APP_ICON_TOOL) $(APP_BIN) $(APP_ICON) $(PROJECT_ICON_TOOL) $(VOICE_BINARY) $(APP_VOICE_HELPER) $(APP_THIRD_PARTY_NOTICES)

$(APP_BIN): Makefile $(VTERM_STATIC) src/mica_app.m src/mica_voice_controller.m src/mica_voice_controller.h src/mica_diagnostics.m src/mica_diagnostics.h $(CORE) $(POMODORO) include/mica.h include/mica_pomodoro.h Info.plist
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE) $(POMODORO) src/mica_diagnostics.m src/mica_voice_controller.m src/mica_app.m $(VTERM_STATIC) -o $@
	@mkdir -p $(APP)/Contents
	@cp Info.plist $(APP)/Contents/Info.plist
	@touch $(APP)

$(VOICE_BINARY): voice/Package.swift voice/Package.resolved $(VOICE_SWIFT_SOURCES)
	@mkdir -p $(BUILD) $(VOICE_MODULE_CACHE)
	CLANG_MODULE_CACHE_PATH="$(VOICE_MODULE_CACHE)" swift build --package-path voice \
		--scratch-path "$(VOICE_SCRATCH)" -c release \
		-Xswiftc -module-cache-path -Xswiftc "$(VOICE_MODULE_CACHE)"
	@bin_dir=$$(CLANG_MODULE_CACHE_PATH="$(VOICE_MODULE_CACHE)" swift build --package-path voice \
		--scratch-path "$(VOICE_SCRATCH)" -c release --show-bin-path); \
	cp "$$bin_dir/mica-voice" "$@"
	@chmod 755 "$@"

# JetBrains Mono (SIL OFL 1.1) is bundled so the terminal looks the same on every Mac.
$(APP_FONTS): $(wildcard fonts/*)
	@mkdir -p $(dir $@)
	cp fonts/*.ttf fonts/OFL.txt $(dir $@)

# Bundled so "New Project Launcher…" works from a downloaded app, not only from a source checkout.
$(APP_LAUNCHER_SCRIPT): scripts/install-desktop-apps.py scripts/build-macos-icon.sh scripts/png-to-icns.py
	@mkdir -p $(dir $@)
	cp scripts/install-desktop-apps.py scripts/build-macos-icon.sh scripts/png-to-icns.py $(dir $@)

$(APP_ICON_TOOL): $(PROJECT_ICON_TOOL)
	@mkdir -p $(dir $@)
	cp $(PROJECT_ICON_TOOL) $@

$(APP_VOICE_HELPER): $(VOICE_BINARY) $(APP_BIN)
	@mkdir -p $(dir $@)
	cp $(VOICE_BINARY) $@
	@chmod 755 "$@"

$(APP_THIRD_PARTY_NOTICES): voice/THIRD_PARTY_NOTICES.md voice/LICENSE-FluidAudio.txt $(VOICE_LICENSES)
	@mkdir -p $(dir $@) $(APP)/Contents/Resources/ThirdPartyLicenses
	cp voice/THIRD_PARTY_NOTICES.md $@
	cp voice/LICENSE-FluidAudio.txt $(APP)/Contents/Resources/LICENSE-FluidAudio.txt
	cp -R voice/ThirdPartyLicenses/. $(APP)/Contents/Resources/ThirdPartyLicenses/

$(APP_ICON): assets/mica-icon.png scripts/build-macos-icon.sh scripts/png-to-icns.py
	@mkdir -p $(dir $@)
	scripts/build-macos-icon.sh $< $@

$(PROJECT_ICON_TOOL): scripts/build-project-icon.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc -framework Cocoa -framework Carbon $< -o $@

$(BUILD)/test-session: tests/test_session.c $(CORE) include/mica.h $(VTERM_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $(CORE) tests/test_session.c $(VTERM_STATIC) -o $@

$(BUILD)/test-pomodoro: tests/test_pomodoro.c $(POMODORO) include/mica_pomodoro.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $(POMODORO) tests/test_pomodoro.c -lm -o $@

$(BUILD)/test-ui: $(VTERM_STATIC) tests/test_app_ui.m src/mica_app.m src/mica_voice_controller.m src/mica_voice_controller.h src/mica_diagnostics.m src/mica_diagnostics.h $(CORE) $(POMODORO) include/mica.h include/mica_pomodoro.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE) $(POMODORO) src/mica_diagnostics.m src/mica_voice_controller.m tests/test_app_ui.m $(VTERM_STATIC) -o $@

test: $(BUILD)/test-session $(BUILD)/test-pomodoro $(BUILD)/test-ui $(APP_ICON) $(PROJECT_ICON_TOOL)
	rm -f $(BUILD)/ui-smoke.png $(BUILD)/ui-smoke-report.txt
	$(BUILD)/test-session
	$(BUILD)/test-pomodoro
	MICA_PROJECT_ICON_TOOL="$(PROJECT_ICON_TOOL)" MICA_TEST_APP_ICON="$(APP_ICON)" python3 tests/test_desktop_apps.py
	python3 tests/test_memory_processes.py
	MICA_UI_SMOKE_IMAGE=$(BUILD)/ui-smoke.png MICA_UI_SMOKE_REPORT=$(BUILD)/ui-smoke-report.txt $(BUILD)/test-ui
	python3 tests/test_agent_loop.py
	python3 tests/test_worktree.py

test-voice:
	@mkdir -p $(BUILD) $(VOICE_MODULE_CACHE)
	CLANG_MODULE_CACHE_PATH="$(VOICE_MODULE_CACHE)" swift build -c release --package-path voice \
		--scratch-path "$(VOICE_SCRATCH)" \
		-Xswiftc -module-cache-path -Xswiftc "$(VOICE_MODULE_CACHE)"

validate:
	$(MAKE) test
	$(MAKE) app
	$(MAKE) test-voice
	plutil -lint $(APP)/Contents/Info.plist
	git diff --check

preflight: validate

run: app
	$(APP_BIN) $(ARGS)

memory:
	@scripts/memory-sample.sh

desktop-apps: app
	python3 scripts/install-desktop-apps.py

install-desktop-apps: app
	python3 scripts/install-desktop-apps.py --install --base-app "$(APP)" --project-icon-tool "$(PROJECT_ICON_TOOL)"

new-instance: app
	python3 scripts/install-desktop-apps.py --new-instance --base-app "$(APP)" --project-icon-tool "$(PROJECT_ICON_TOOL)"

# SIGN_ID defaults to ad-hoc ("-"); pass a Developer ID identity for distribution.
# Default: the first Developer ID Application identity in the keychain (a stable signature keeps macOS folder and
# microphone permissions between builds), otherwise ad-hoc.
SIGN_ID ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1),-)
# Ad-hoc local builds need no timestamp; Developer ID signatures must carry Apple's secure timestamp to be notarized.
SIGN_TIMESTAMP := $(if $(filter -,$(SIGN_ID)),=none,)

sign: app
	codesign --force --options runtime --timestamp$(SIGN_TIMESTAMP) --entitlements Mica.entitlements --sign "$(SIGN_ID)" $(APP_VOICE_HELPER)
	codesign --force --options runtime --timestamp$(SIGN_TIMESTAMP) --sign "$(SIGN_ID)" $(APP_ICON_TOOL)
	codesign --force --options runtime --timestamp$(SIGN_TIMESTAMP) --entitlements Mica.entitlements --sign "$(SIGN_ID)" $(APP)
	codesign --verify --deep --strict $(APP)

dist: sign
	ditto -c -k --keepParent $(APP) $(BUILD)/Mica.zip

# Drag-to-Applications disk image; Mica.dmg is the stable asset name the README and site link to.
dmg: dist
	@rm -rf $(BUILD)/dmg && mkdir -p $(BUILD)/dmg
	cp -R $(APP) $(BUILD)/dmg/
	ln -s /Applications $(BUILD)/dmg/Applications
	rm -f $(BUILD)/Mica.dmg
	hdiutil create -volname "Mica" -srcfolder $(BUILD)/dmg -fs HFS+ -format UDZO -ov $(BUILD)/Mica.dmg
	@if [ "$(SIGN_ID)" != "-" ]; then codesign --force --timestamp --sign "$(SIGN_ID)" $(BUILD)/Mica.dmg; fi
	cd $(BUILD) && shasum -a 256 Mica.dmg Mica.zip > SHA256SUMS.txt

# Needs a Developer ID Application certificate and a notarytool keychain profile; see docs/RELEASING.md.
NOTARY_PROFILE ?= mica-notary

notarize: dist
	xcrun notarytool submit $(BUILD)/Mica.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	ditto -c -k --keepParent $(APP) $(BUILD)/Mica.zip
	$(MAKE) dmg SIGN_ID="$(SIGN_ID)"
	xcrun notarytool submit $(BUILD)/Mica.dmg --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(BUILD)/Mica.dmg
	spctl --assess --type execute --verbose $(APP)

# Sanitizer builds: the session tests and the fuzz/stress test run under AddressSanitizer + UBSan.
SAN_FLAGS := -fsanitize=address,undefined -fno-omit-frame-pointer -g -O1

$(BUILD)/test-session-san: tests/test_session.c $(CORE) include/mica.h $(VTERM_SAN_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $(CORE) tests/test_session.c $(VTERM_SAN_STATIC) -o $@

$(BUILD)/fuzz-session-san: tests/fuzz_session.c $(CORE) include/mica.h $(VTERM_SAN_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $(CORE) tests/fuzz_session.c $(VTERM_SAN_STATIC) -o $@

$(BUILD)/stress-ui-san: tests/stress_app_ui.m src/mica_app.m src/mica_voice_controller.m src/mica_diagnostics.m $(CORE) $(POMODORO) include/mica.h $(VTERM_SAN_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(MACOSX_VERSION_FLAG) -Wno-deprecated-declarations -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE) $(POMODORO) src/mica_diagnostics.m src/mica_voice_controller.m tests/stress_app_ui.m $(VTERM_SAN_STATIC) -o $@

# STRESS_SEEDS random seeds of 1500 random user actions each, under the sanitizers.
STRESS_SEEDS ?= 3
stress: $(BUILD)/stress-ui-san
	@i=1; while [ $$i -le $(STRESS_SEEDS) ]; do $(BUILD)/stress-ui-san $$((i * 104729)) 1500 || exit 1; i=$$((i+1)); done

# FUZZ_SEEDS: how many random seeds to run (default 3). Seeds are printed so failures can be replayed.
FUZZ_SEEDS ?= 3
fuzz: $(BUILD)/fuzz-session-san
	@i=1; while [ $$i -le $(FUZZ_SEEDS) ]; do $(BUILD)/fuzz-session-san $$((i * 7919)) || exit 1; i=$$((i+1)); done

sanitize: $(BUILD)/test-session-san fuzz
	$(BUILD)/test-session-san

# Renders the website/README product images from the real terminal view (fictional project, sample output only).
$(BUILD)/render-marketing: $(VTERM_STATIC) tools/render_marketing.m src/mica_app.m src/mica_voice_controller.m src/mica_diagnostics.m $(CORE) $(POMODORO) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE) $(POMODORO) src/mica_diagnostics.m src/mica_voice_controller.m tools/render_marketing.m $(VTERM_STATIC) -o $@

$(BUILD)/render-ui-audit: $(VTERM_STATIC) tools/render_ui_audit.m src/mica_app.m src/mica_voice_controller.m src/mica_diagnostics.m $(CORE) $(POMODORO) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE) $(POMODORO) src/mica_diagnostics.m src/mica_voice_controller.m tools/render_ui_audit.m $(VTERM_STATIC) -o $@

# Renders every surface (states, themes, narrow and crowded windows, settings) into build/ui-audit/ for review.
ui-audit: $(BUILD)/render-ui-audit
	$(BUILD)/render-ui-audit $(BUILD)/ui-audit

screenshots: $(BUILD)/render-marketing
	$(BUILD)/render-marketing docs/assets

clean:
	rm -rf $(BUILD)

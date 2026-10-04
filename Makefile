CC := clang
MACOSX_DEPLOYMENT_TARGET ?= 14.0
MACOSX_VERSION_FLAG := -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)
BUILD := build
APP := $(BUILD)/Mica.app
# Project launchers should run the installed release when available, keeping everyday project work
# independent of the app bundle rebuilt by `make app`.
BASE_APP ?= $(if $(wildcard /Applications/Mica.app),/Applications/Mica.app,$(APP))
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
APP_HOOK_HELPER := $(APP)/Contents/Helpers/mica-hook
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
HOOK := src/mica_hook.c
CORE_FRAMEWORK := -framework CoreFoundation
POMODORO := src/pomodoro.c

.PHONY: benchmark-history
$(BUILD)/benchmark-history: tools/benchmark_history.c $(CORE) include/mica.h $(VTERM_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $(CORE_FRAMEWORK) $(CORE) tools/benchmark_history.c $(VTERM_STATIC) -o $@

benchmark-history: $(BUILD)/benchmark-history
	$(BUILD)/benchmark-history

.PHONY: all app sign dist checksums notarize screenshots ui-audit sanitize fuzz stress test smoke-app test-voice validate preflight clean run memory desktop-apps install-desktop-apps new-instance

all: app

app: $(APP_FONTS) $(APP_LAUNCHER_SCRIPT) $(APP_ICON_TOOL) $(APP_HOOK_HELPER) $(APP_BIN) $(APP_ICON) $(PROJECT_ICON_TOOL) $(VOICE_BINARY) $(APP_VOICE_HELPER) $(APP_THIRD_PARTY_NOTICES)
	@if [ "$(SIGN_ID)" != "-" ]; then \
		codesign --force --options runtime --timestamp$(SIGN_TIMESTAMP) --entitlements Mica.entitlements --sign "$(SIGN_ID)" $(APP_VOICE_HELPER) && \
		codesign --force --options runtime --timestamp$(SIGN_TIMESTAMP) --sign "$(SIGN_ID)" $(APP_HOOK_HELPER) && \
		codesign --force --options runtime --timestamp$(SIGN_TIMESTAMP) --sign "$(SIGN_ID)" $(APP_ICON_TOOL) && \
		codesign --force --options runtime --timestamp$(SIGN_TIMESTAMP) --entitlements Mica.entitlements --sign "$(SIGN_ID)" $(APP) && \
		codesign --verify --deep --strict $(APP); \
	fi

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp $< $@
app: $(APP)/Contents/Info.plist

$(APP_BIN): Makefile $(VTERM_STATIC) src/mica_agent_detect.c include/mica_agent_detect.h src/mica_agent_state.m src/mica_agent_state.h src/mica_agent_rss.m src/mica_agent_rss.h src/mica_status_context.m src/mica_status_context.h src/mica_ssh_profile.m src/mica_ssh_profile.h src/mica_attention.m src/mica_attention.h src/mica_resume.m src/mica_resume.h src/mica_hook_install.m src/mica_hook_install.h src/mica_app.m src/mica_status_item.m src/mica_status_item.h src/mica_voice_controller.m src/mica_voice_controller.h src/mica_diagnostics.m src/mica_diagnostics.h src/mica_vocabulary.m src/mica_vocabulary.h $(CORE) $(POMODORO) include/mica.h include/mica_pomodoro.h Info.plist
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE_FRAMEWORK) $(CORE) src/mica_agent_detect.c $(POMODORO) src/mica_diagnostics.m src/mica_vocabulary.m src/mica_voice_controller.m src/mica_attention.m src/mica_resume.m src/mica_status_item.m src/mica_hook_server.m src/mica_hook_install.m src/mica_agent_state.m src/mica_agent_rss.m src/mica_status_context.m src/mica_ssh_profile.m src/mica_app.m $(HOOK) $(VTERM_STATIC) -o $@

$(BUILD)/test-resume: tests/test_resume.m src/mica_resume.m src/mica_resume.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc -Isrc -framework Foundation src/mica_resume.m tests/test_resume.m -o $@

$(BUILD)/test-ssh-profile: tests/test_ssh_profile.m src/mica_ssh_profile.m src/mica_ssh_profile.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc -Isrc -framework Foundation src/mica_ssh_profile.m tests/test_ssh_profile.m -o $@

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

$(APP_HOOK_HELPER): scripts/mica-hook
	@mkdir -p $(dir $@)
	cp $< $@
	@chmod 755 $@

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

$(BUILD)/test-hook: tests/test_hook.c $(HOOK) include/mica_hook.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(C_WARNINGS) $(CPPFLAGS) $(HOOK) tests/test_hook.c -o $@

$(BUILD)/test-agent-detect: tests/test_agent_detect.c src/mica_agent_detect.c include/mica_agent_detect.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(C_WARNINGS) $(CPPFLAGS) src/mica_agent_detect.c tests/test_agent_detect.c -o $@

$(BUILD)/test-hook-install: tests/test_hook_install.m src/mica_hook_install.m src/mica_hook_install.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc -Isrc -framework Cocoa src/mica_hook_install.m tests/test_hook_install.m -o $@

$(BUILD)/test-hook-server: tests/test_hook_server.m src/mica_hook_server.m src/mica_hook_server.h src/mica_hook_install.m src/mica_hook_install.h $(HOOK) include/mica_hook.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) -Isrc -framework Foundation src/mica_hook_server.m $(HOOK) tests/test_hook_server.m -o $@

$(BUILD)/test-session: tests/test_session.c $(CORE) $(HOOK) src/mica_agent_detect.c include/mica_agent_detect.h include/mica.h include/mica_hook.h $(VTERM_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) -DMICA_SESSION_TESTING $(CORE_FRAMEWORK) $(CORE) $(HOOK) src/mica_agent_detect.c tests/test_session.c $(VTERM_STATIC) -o $@

$(BUILD)/test-vterm-history: tests/test_vterm_history.c $(VTERM_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $< $(VTERM_STATIC) -o $@

$(BUILD)/test-pomodoro: tests/test_pomodoro.c $(POMODORO) include/mica_pomodoro.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $(POMODORO) tests/test_pomodoro.c -lm -o $@

$(BUILD)/test-agent-rss: tests/test_agent_rss.m src/mica_agent_rss.m src/mica_agent_rss.h $(CORE) $(VTERM_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) -Isrc -framework Foundation $(CORE_FRAMEWORK) $(CORE) $(HOOK) $(VTERM_STATIC) src/mica_agent_rss.m tests/test_agent_rss.m -o $@

$(BUILD)/test-status-context: tests/test_status_context.m src/mica_status_context.m src/mica_status_context.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc -Isrc -framework Foundation src/mica_status_context.m tests/test_status_context.m -o $@

$(BUILD)/test-attention: tests/test_attention.m src/mica_attention.m src/mica_attention.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc -Isrc -framework Foundation src/mica_attention.m tests/test_attention.m -o $@

$(BUILD)/test-ui: src/mica_agent_detect.c include/mica_agent_detect.h src/mica_agent_state.m src/mica_agent_state.h src/mica_agent_rss.m src/mica_agent_rss.h src/mica_status_context.m src/mica_status_context.h src/mica_ssh_profile.m src/mica_ssh_profile.h src/mica_attention.m src/mica_attention.h src/mica_resume.m src/mica_resume.h $(VTERM_STATIC) src/mica_hook_install.m src/mica_hook_install.h tests/test_app_ui.m src/mica_status_item.m src/mica_status_item.h src/mica_app.m src/mica_agent_rss.m src/mica_status_context.m src/mica_ssh_profile.m src/mica_vocabulary.m src/mica_vocabulary.h src/mica_voice_controller.m src/mica_voice_controller.h src/mica_diagnostics.m src/mica_diagnostics.h src/mica_hook_server.m src/mica_hook_server.h src/mica_hook_install.m src/mica_hook_install.h $(HOOK) include/mica_hook.h $(CORE) $(POMODORO) include/mica.h include/mica_pomodoro.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -DMICA_SESSION_TESTING -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE_FRAMEWORK) $(CORE) src/mica_agent_detect.c $(POMODORO) src/mica_diagnostics.m src/mica_vocabulary.m src/mica_voice_controller.m src/mica_attention.m src/mica_resume.m src/mica_status_item.m src/mica_hook_server.m src/mica_hook_install.m src/mica_agent_state.m src/mica_agent_rss.m src/mica_status_context.m src/mica_ssh_profile.m tests/test_app_ui.m $(HOOK) $(VTERM_STATIC) -o $@

test: $(BUILD)/test-vterm-history $(BUILD)/test-session $(BUILD)/test-agent-detect $(BUILD)/test-hook $(BUILD)/test-hook-server $(BUILD)/test-pomodoro $(BUILD)/test-attention $(BUILD)/test-agent-rss $(BUILD)/test-status-context $(BUILD)/test-ssh-profile $(BUILD)/test-hook-install $(BUILD)/test-resume $(BUILD)/test-ui $(APP_ICON) $(PROJECT_ICON_TOOL)
	rm -f $(BUILD)/ui-smoke.png $(BUILD)/ui-smoke-report.txt
	$(BUILD)/test-vterm-history
	$(BUILD)/test-session
	$(BUILD)/test-agent-detect
	$(BUILD)/test-hook
	$(BUILD)/test-hook-install
	$(BUILD)/test-hook-server
	python3 tests/test_hook_helper.py
	$(BUILD)/test-pomodoro
	$(BUILD)/test-attention
	$(BUILD)/test-agent-rss
	$(BUILD)/test-status-context
	$(BUILD)/test-resume
	$(BUILD)/test-ssh-profile
	MICA_PROJECT_ICON_TOOL="$(PROJECT_ICON_TOOL)" MICA_TEST_APP_ICON="$(APP_ICON)" python3 tests/test_desktop_apps.py
	python3 tests/test_memory_processes.py
	MICA_UI_SMOKE_IMAGE=$(BUILD)/ui-smoke.png MICA_UI_SMOKE_REPORT=$(BUILD)/ui-smoke-report.txt $(BUILD)/test-ui
	python3 tests/test_agent_loop.py
	python3 tests/test_worktree.py
	python3 tests/test_release.py

# Offscreen AppKit smoke: exercises menu wiring and enabled state through test-ui;
# it never launches the packaged application bundle.
smoke-app: $(BUILD)/test-ui
	MICA_UI_SMOKE_REPORT=$(BUILD)/smoke-app-report.txt $(BUILD)/test-ui

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
	python3 scripts/install-desktop-apps.py --base-app "$(BASE_APP)"

install-desktop-apps: app
	python3 scripts/install-desktop-apps.py --install --base-app "$(BASE_APP)" --project-icon-tool "$(PROJECT_ICON_TOOL)"

new-instance: app
	python3 scripts/install-desktop-apps.py --new-instance --base-app "$(BASE_APP)" --project-icon-tool "$(PROJECT_ICON_TOOL)"

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
	$(MAKE) checksums

# Hash finalized artifacts; stapling modifies the disk image after packaging.
checksums:
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
	$(MAKE) checksums
	spctl --assess --type execute --verbose $(APP)

# Sanitizer builds: the session tests and the fuzz/stress test run under AddressSanitizer + UBSan.
SAN_FLAGS := -fsanitize=address,undefined -fno-omit-frame-pointer -g -O1

$(BUILD)/test-vterm-history-san: tests/test_vterm_history.c $(VTERM_SAN_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $< $(VTERM_SAN_STATIC) -o $@

$(BUILD)/test-session-san: tests/test_session.c $(CORE) src/mica_agent_detect.c include/mica_agent_detect.h include/mica.h $(VTERM_SAN_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) -DMICA_SESSION_TESTING $(CORE_FRAMEWORK) $(CORE) $(HOOK) src/mica_agent_detect.c tests/test_session.c $(VTERM_SAN_STATIC) -o $@

$(BUILD)/test-agent-detect-san: tests/test_agent_detect.c src/mica_agent_detect.c include/mica_agent_detect.h
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(C_WARNINGS) $(CPPFLAGS) src/mica_agent_detect.c tests/test_agent_detect.c -o $@

$(BUILD)/fuzz-session-san: tests/fuzz_session.c $(CORE) include/mica.h $(VTERM_SAN_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $(CORE_FRAMEWORK) $(CORE) tests/fuzz_session.c $(VTERM_SAN_STATIC) -o $@

$(BUILD)/fuzz-hook-san: tests/fuzz_hook.c $(HOOK) include/mica_hook.h
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(C_WARNINGS) $(CPPFLAGS) $(HOOK) tests/fuzz_hook.c -o $@

$(BUILD)/stress-ui-san: src/mica_agent_detect.c include/mica_agent_detect.h src/mica_agent_state.m src/mica_agent_state.h src/mica_resume.m src/mica_resume.h tests/stress_app_ui.m src/mica_status_item.m src/mica_status_item.h src/mica_app.m src/mica_agent_rss.m src/mica_status_context.m src/mica_ssh_profile.m src/mica_ssh_profile.h src/mica_vocabulary.m src/mica_vocabulary.h src/mica_voice_controller.m src/mica_diagnostics.m src/mica_hook_server.m src/mica_hook_server.h src/mica_hook_install.m src/mica_hook_install.h $(HOOK) $(CORE) $(POMODORO) src/mica_hook_install.m include/mica.h $(VTERM_SAN_STATIC)
	@mkdir -p $(BUILD)
	$(CC) $(SAN_FLAGS) $(MACOSX_VERSION_FLAG) -Wno-deprecated-declarations -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE_FRAMEWORK) $(CORE) src/mica_agent_detect.c $(POMODORO) src/mica_diagnostics.m src/mica_vocabulary.m src/mica_voice_controller.m src/mica_attention.m src/mica_resume.m src/mica_status_item.m src/mica_hook_server.m src/mica_hook_install.m src/mica_agent_state.m src/mica_agent_rss.m src/mica_status_context.m src/mica_ssh_profile.m tests/stress_app_ui.m $(HOOK) $(VTERM_SAN_STATIC) -o $@

# STRESS_SEEDS random seeds of 1500 random user actions each, under the sanitizers.
STRESS_SEEDS ?= 3
stress: $(BUILD)/stress-ui-san
	@i=1; while [ $$i -le $(STRESS_SEEDS) ]; do $(BUILD)/stress-ui-san $$((i * 104729)) 1500 || exit 1; i=$$((i+1)); done

# FUZZ_SEEDS: how many random seeds to run (default 3). Seeds are printed so failures can be replayed.
FUZZ_SEEDS ?= 3
fuzz: $(BUILD)/fuzz-session-san $(BUILD)/fuzz-hook-san
	@i=1; while [ $$i -le $(FUZZ_SEEDS) ]; do $(BUILD)/fuzz-session-san $$((i * 7919)) || exit 1; i=$$((i+1)); done
	@i=1; while [ $$i -le $(FUZZ_SEEDS) ]; do $(BUILD)/fuzz-hook-san $$((i * 7919)) || exit 1; i=$$((i+1)); done

sanitize: $(BUILD)/test-vterm-history-san $(BUILD)/test-session-san $(BUILD)/test-agent-detect-san fuzz
	$(BUILD)/test-vterm-history-san
	$(BUILD)/test-session-san
	$(BUILD)/test-agent-detect-san

# Renders the website/README product images from the real terminal view (fictional project, sample output only).
$(BUILD)/render-marketing: src/mica_agent_detect.c src/mica_agent_state.m src/mica_agent_state.h src/mica_resume.m src/mica_resume.h src/mica_ssh_profile.m src/mica_ssh_profile.h $(VTERM_STATIC) tools/render_marketing.m src/mica_app.m src/mica_status_item.m src/mica_status_item.h src/mica_agent_rss.m src/mica_status_context.m src/mica_vocabulary.m src/mica_vocabulary.h src/mica_voice_controller.m src/mica_diagnostics.m src/mica_hook_server.m src/mica_hook_server.h src/mica_hook_install.m src/mica_hook_install.h $(HOOK) $(CORE) $(POMODORO) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE_FRAMEWORK) $(CORE) src/mica_agent_detect.c $(POMODORO) src/mica_diagnostics.m src/mica_vocabulary.m src/mica_voice_controller.m src/mica_attention.m src/mica_resume.m src/mica_status_item.m src/mica_agent_state.m src/mica_agent_rss.m src/mica_status_context.m src/mica_ssh_profile.m tools/render_marketing.m src/mica_hook_server.m src/mica_hook_install.m $(HOOK) $(VTERM_STATIC) -o $@

$(BUILD)/render-ui-audit: src/mica_agent_state.m src/mica_agent_state.h src/mica_resume.m src/mica_resume.h $(VTERM_STATIC) tools/render_ui_audit.m src/mica_status_item.m src/mica_status_item.h src/mica_app.m src/mica_agent_rss.m src/mica_status_context.m src/mica_vocabulary.m src/mica_vocabulary.h src/mica_voice_controller.m src/mica_diagnostics.m src/mica_hook_server.m src/mica_hook_server.h src/mica_hook_install.m src/mica_hook_install.h $(HOOK) $(CORE) $(POMODORO) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE_FRAMEWORK) $(CORE) $(POMODORO) src/mica_diagnostics.m src/mica_vocabulary.m src/mica_voice_controller.m src/mica_attention.m src/mica_resume.m src/mica_status_item.m src/mica_hook_server.m src/mica_hook_install.m src/mica_agent_state.m src/mica_agent_rss.m src/mica_status_context.m tools/render_ui_audit.m $(HOOK) $(VTERM_STATIC) -o $@

# Renders every surface (states, themes, narrow and crowded windows, settings) into build/ui-audit/ for review.
ui-audit: $(BUILD)/render-ui-audit
	$(BUILD)/render-ui-audit $(BUILD)/ui-audit

$(BUILD)/render-demo: src/mica_agent_detect.c src/mica_agent_state.m src/mica_agent_state.h src/mica_resume.m src/mica_resume.h src/mica_ssh_profile.m src/mica_ssh_profile.h $(VTERM_STATIC) tools/render_demo.m src/mica_status_item.m src/mica_status_item.h src/mica_app.m src/mica_agent_rss.m src/mica_status_context.m src/mica_vocabulary.m src/mica_vocabulary.h src/mica_voice_controller.m src/mica_diagnostics.m src/mica_hook_server.m src/mica_hook_server.h src/mica_hook_install.m src/mica_hook_install.h $(HOOK) $(CORE) $(POMODORO) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework Carbon -framework AVFoundation -framework UserNotifications $(CORE_FRAMEWORK) $(CORE) src/mica_agent_detect.c $(POMODORO) src/mica_diagnostics.m src/mica_vocabulary.m src/mica_voice_controller.m src/mica_attention.m src/mica_resume.m src/mica_status_item.m src/mica_hook_server.m src/mica_hook_install.m src/mica_agent_state.m src/mica_agent_rss.m src/mica_status_context.m src/mica_ssh_profile.m tools/render_demo.m $(HOOK) $(VTERM_STATIC) -o $@

screenshots: $(BUILD)/render-marketing
	$(BUILD)/render-marketing docs/assets

.PHONY: demo-assets
demo-assets:
	scripts/render-demo-assets.sh

clean:
	rm -rf $(BUILD)

CC := clang
PKG_CONFIG ?= pkg-config
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
VOICE_SWIFT_SOURCES := $(shell find voice/Sources -type f -name '*.swift')
VOICE_LICENSES := $(wildcard voice/ThirdPartyLicenses/*)
VTERM_CFLAGS := $(shell $(PKG_CONFIG) --cflags vterm 2>/dev/null)
VTERM_LIBS := $(shell $(PKG_CONFIG) --libs vterm 2>/dev/null)
CFLAGS ?= -O2
C_WARNINGS := -Wall -Wextra -Wpedantic
OBJC_WARNINGS := -Wall -Wextra -Wno-deprecated-declarations
CPPFLAGS := -Iinclude $(VTERM_CFLAGS)
CORE := src/session.c
POMODORO := src/pomodoro.c

.PHONY: all app test test-voice validate preflight clean run memory desktop-apps install-desktop-apps new-instance

all: app

app: $(APP_BIN) $(APP_ICON) $(PROJECT_ICON_TOOL) $(VOICE_BINARY) $(APP_VOICE_HELPER) $(APP_THIRD_PARTY_NOTICES)

$(APP_BIN): src/mica_app.m src/mica_voice_controller.m src/mica_voice_controller.h src/mica_diagnostics.m src/mica_diagnostics.h $(CORE) $(POMODORO) include/mica.h include/mica_pomodoro.h Info.plist
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework AVFoundation -framework UserNotifications $(CORE) $(POMODORO) src/mica_diagnostics.m src/mica_voice_controller.m src/mica_app.m $(VTERM_LIBS) -o $@
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
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc -framework Cocoa $< -o $@

$(BUILD)/test-session: tests/test_session.c $(CORE) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(C_WARNINGS) $(CPPFLAGS) $(CORE) tests/test_session.c $(VTERM_LIBS) -o $@

$(BUILD)/test-pomodoro: tests/test_pomodoro.c $(POMODORO) include/mica_pomodoro.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(C_WARNINGS) $(CPPFLAGS) $(POMODORO) tests/test_pomodoro.c -lm -o $@

$(BUILD)/test-ui: tests/test_app_ui.m src/mica_app.m src/mica_voice_controller.m src/mica_voice_controller.h src/mica_diagnostics.m src/mica_diagnostics.h $(CORE) $(POMODORO) include/mica.h include/mica_pomodoro.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(MACOSX_VERSION_FLAG) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa -framework AVFoundation -framework UserNotifications $(CORE) $(POMODORO) src/mica_diagnostics.m src/mica_voice_controller.m tests/test_app_ui.m $(VTERM_LIBS) -o $@

test: $(BUILD)/test-session $(BUILD)/test-pomodoro $(BUILD)/test-ui $(APP_ICON) $(PROJECT_ICON_TOOL)
	rm -f $(BUILD)/ui-smoke.png $(BUILD)/ui-smoke-report.txt
	$(BUILD)/test-session
	$(BUILD)/test-pomodoro
	MICA_PROJECT_ICON_TOOL="$(PROJECT_ICON_TOOL)" MICA_TEST_APP_ICON="$(APP_ICON)" python3 tests/test_desktop_apps.py
	python3 tests/test_memory_processes.py
	MICA_UI_SMOKE_IMAGE=$(BUILD)/ui-smoke.png MICA_UI_SMOKE_REPORT=$(BUILD)/ui-smoke-report.txt $(BUILD)/test-ui
	python3 tests/test_agent_loop.py

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

clean:
	rm -rf $(BUILD)

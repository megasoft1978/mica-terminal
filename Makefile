CC := clang
PKG_CONFIG ?= pkg-config
BUILD := build
APP := $(BUILD)/Mica.app
APP_BIN := $(APP)/Contents/MacOS/Mica
APP_ICON := $(APP)/Contents/Resources/Mica.icns
PROJECT_ICON_TOOL := $(BUILD)/mica-project-icon
VTERM_CFLAGS := $(shell $(PKG_CONFIG) --cflags vterm 2>/dev/null)
VTERM_LIBS := $(shell $(PKG_CONFIG) --libs vterm 2>/dev/null)
CFLAGS ?= -O2
C_WARNINGS := -Wall -Wextra -Wpedantic
OBJC_WARNINGS := -Wall -Wextra -Wno-deprecated-declarations
CPPFLAGS := -Iinclude $(VTERM_CFLAGS)
CORE := src/session.c

.PHONY: all app test validate preflight clean run memory desktop-apps install-desktop-apps

all: app

app: $(APP_BIN) $(APP_ICON) $(PROJECT_ICON_TOOL)

$(APP_BIN): src/mica_app.m $(CORE) include/mica.h Info.plist
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa $(CORE) src/mica_app.m $(VTERM_LIBS) -o $@
	@mkdir -p $(APP)/Contents
	@cp Info.plist $(APP)/Contents/Info.plist
	@touch $(APP)

$(APP_ICON): assets/mica-icon.png scripts/build-macos-icon.sh
	@mkdir -p $(dir $@)
	scripts/build-macos-icon.sh $< $@

$(PROJECT_ICON_TOOL): scripts/build-project-icon.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(OBJC_WARNINGS) -fobjc-arc -framework Cocoa $< -o $@

$(BUILD)/test-session: tests/test_session.c $(CORE) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(C_WARNINGS) $(CPPFLAGS) $(CORE) tests/test_session.c $(VTERM_LIBS) -o $@

$(BUILD)/test-ui: tests/test_app_ui.m src/mica_app.m $(CORE) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa $(CORE) tests/test_app_ui.m $(VTERM_LIBS) -o $@

test: $(BUILD)/test-session $(BUILD)/test-ui $(APP_ICON) $(PROJECT_ICON_TOOL)
	rm -f $(BUILD)/ui-smoke.png $(BUILD)/ui-smoke-report.txt
	$(BUILD)/test-session
	python3 tests/test_desktop_apps.py
	python3 tests/test_memory_processes.py
	MICA_UI_SMOKE_IMAGE=$(BUILD)/ui-smoke.png MICA_UI_SMOKE_REPORT=$(BUILD)/ui-smoke-report.txt $(BUILD)/test-ui
	python3 tests/test_agent_loop.py

validate:
	$(MAKE) test
	$(MAKE) app
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
	python3 scripts/install-desktop-apps.py --install

clean:
	rm -rf $(BUILD)

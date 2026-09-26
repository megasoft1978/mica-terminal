CC := clang
PKG_CONFIG ?= pkg-config
BUILD := build
APP := $(BUILD)/Mica.app
APP_BIN := $(APP)/Contents/MacOS/Mica
VTERM_CFLAGS := $(shell $(PKG_CONFIG) --cflags vterm 2>/dev/null)
VTERM_LIBS := $(shell $(PKG_CONFIG) --libs vterm 2>/dev/null)
CFLAGS ?= -O2
C_WARNINGS := -Wall -Wextra -Wpedantic
OBJC_WARNINGS := -Wall -Wextra -Wno-deprecated-declarations
CPPFLAGS := -Iinclude $(VTERM_CFLAGS)
CORE := src/session.c

.PHONY: all app test clean run memory import-layouts

all: app

app: $(APP_BIN)

$(APP_BIN): src/mica_app.m $(CORE) include/mica.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(OBJC_WARNINGS) -fobjc-arc $(CPPFLAGS) \
		-framework Cocoa $(CORE) src/mica_app.m $(VTERM_LIBS) -o $@
	@mkdir -p $(APP)/Contents
	@cp Info.plist $(APP)/Contents/Info.plist
	@touch $(APP)

$(BUILD)/test-session: tests/test_session.c $(CORE) include/mica.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(C_WARNINGS) $(CPPFLAGS) $(CORE) tests/test_session.c $(VTERM_LIBS) -o $@

test: $(BUILD)/test-session
	$(BUILD)/test-session

run: app
	$(APP_BIN) $(ARGS)

memory:
	@scripts/memory-sample.sh

import-layouts:
	@scripts/import-zellij-layouts.py "$${ZELLIJ_LAYOUTS:-$$HOME/.config/zellij/layouts}" "$${MICA_LAYOUTS:-$$HOME/.config/mica/layouts}"

clean:
	rm -rf $(BUILD)

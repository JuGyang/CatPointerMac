PROJECT_DIR := $(CURDIR)
MODULE_CACHE := /private/tmp/catpointer-clang-cache
BUILD_DIR := $(PROJECT_DIR)/.build/release
TEST_DIR := $(PROJECT_DIR)/.build/tests
APP_BINARY := $(BUILD_DIR)/CatPointer
TEST_BINARY := $(TEST_DIR)/test_assets
SETTINGS_TEST_BINARY := $(TEST_DIR)/test_settings_logic
CURSOR_DIAGNOSTIC_BINARY := $(TEST_DIR)/current_cursor
VIDEO_FRAME_EXTRACTOR := $(TEST_DIR)/extract_video_frames
FRAME_LIMIT_PROBE := $(TEST_DIR)/probe_frame_limit

CC := clang
CFLAGS := -fobjc-arc -fblocks -fmodules -fmodules-cache-path=$(MODULE_CACHE) \
	-mmacosx-version-min=13.0 -Wall -Wextra -Wno-deprecated-declarations
INCLUDES := -I$(PROJECT_DIR)/Sources/CatPointer
APP_FRAMEWORKS := -framework AppKit -framework ApplicationServices \
	-framework CoreGraphics -framework ImageIO
TEST_FRAMEWORKS := -framework AppKit -framework CoreGraphics -framework ImageIO
APP_SOURCES := \
	Sources/CatPointer/main.m \
	Sources/CatPointer/CursorAssetSequence.m \
	Sources/CatPointer/SystemCursorRegistrar.m

.PHONY: all release debug test diagnostics frame-limit-probe app-icon clean package

all: release

release: CFLAGS += -O2
release: $(APP_BINARY)

debug: CFLAGS += -O0 -g
debug: $(APP_BINARY)

$(APP_BINARY): $(APP_SOURCES) Sources/CatPointer/CursorAssetSequence.h Sources/CatPointer/SystemCursorRegistrar.h
	@mkdir -p $(BUILD_DIR) $(MODULE_CACHE)
	$(CC) $(CFLAGS) $(INCLUDES) $(APP_SOURCES) $(APP_FRAMEWORKS) -o $@

$(TEST_BINARY): Tests/test_assets.m Sources/CatPointer/CursorAssetSequence.m Sources/CatPointer/CursorAssetSequence.h
	@mkdir -p $(TEST_DIR) $(MODULE_CACHE)
	$(CC) $(CFLAGS) -O0 $(INCLUDES) Tests/test_assets.m \
		Sources/CatPointer/CursorAssetSequence.m \
		$(TEST_FRAMEWORKS) -o $@

$(SETTINGS_TEST_BINARY): Tests/test_settings_logic.m $(APP_SOURCES) Sources/CatPointer/CursorAssetSequence.h Sources/CatPointer/SystemCursorRegistrar.h
	@mkdir -p $(TEST_DIR) $(MODULE_CACHE)
	$(CC) $(CFLAGS) -Wno-nullability-completeness -O0 $(INCLUDES) Tests/test_settings_logic.m \
		Sources/CatPointer/CursorAssetSequence.m \
		Sources/CatPointer/SystemCursorRegistrar.m \
		$(APP_FRAMEWORKS) -o $@

test: $(TEST_BINARY) $(SETTINGS_TEST_BINARY)
	$(TEST_BINARY)
	$(SETTINGS_TEST_BINARY)

$(CURSOR_DIAGNOSTIC_BINARY): Tools/current_cursor.m
	@mkdir -p $(TEST_DIR) $(MODULE_CACHE)
	$(CC) $(CFLAGS) -O0 Tools/current_cursor.m \
		-framework Foundation -framework CoreGraphics -o $@

diagnostics: $(CURSOR_DIAGNOSTIC_BINARY)
	$(CURSOR_DIAGNOSTIC_BINARY)

$(FRAME_LIMIT_PROBE): Tools/probe_frame_limit.m
	@mkdir -p $(TEST_DIR) $(MODULE_CACHE)
	$(CC) $(CFLAGS) -O0 Tools/probe_frame_limit.m \
		-framework Foundation -framework CoreGraphics -o $@

frame-limit-probe: $(FRAME_LIMIT_PROBE)
	$(FRAME_LIMIT_PROBE) 24 8 8

app-icon:
	./Scripts/build-app-icon.sh

$(VIDEO_FRAME_EXTRACTOR): Tools/extract_video_frames.m
	@mkdir -p $(TEST_DIR) $(MODULE_CACHE)
	$(CC) $(CFLAGS) -O0 Tools/extract_video_frames.m \
		-framework AVFoundation -framework ImageIO \
		-framework UniformTypeIdentifiers -o $@

package: release
	./Scripts/package-app.sh

clean:
	rm -rf "$(PROJECT_DIR)/.build" "$(PROJECT_DIR)/dist"

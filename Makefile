.PHONY: all clean clean-all copy-headers test

LIB_NAME := libpartial
LIB_VERSION := 0.0.1

CC := clang

CFLAGS ?= -Wall -Werror -Wno-unused-command-line-argument -Iinclude -fPIC -fobjc-arc -O3
LDFLAGS ?= -framework Foundation -framework Security -lz

TARGET ?= macos

ifeq ($(TARGET), macos)
CFLAGS += -arch x86_64 -arch arm64 -mmacosx-version-min=11.0
else ifeq ($(TARGET), ios)
CFLAGS += -arch arm64 -arch arm64e -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=14.0
else
$(error Unsupported target $(TARGET))
endif

BUILD_DIR := build/$(TARGET)
OUTPUT_DIR := output/$(TARGET)

DEBUG ?= 0
ifeq ($(DEBUG), 1)
	CFLAGS += -g -DDEBUG=1 -O0
endif

HEADER_OUTPUT_DIR := $(OUTPUT_DIR)/include

TESTS_SRC_DIR := tests
TESTS_BUILD_DIR := $(BUILD_DIR)/tests
TESTS_OUTPUT_DIR := $(OUTPUT_DIR)/tests

LIB_DIR := $(OUTPUT_DIR)/lib
STATIC_LIB := $(LIB_DIR)/$(LIB_NAME).a
DYNAMIC_LIB := $(LIB_DIR)/$(LIB_NAME).dylib

SRC_DIR := src
SRC_FILES := $(wildcard $(SRC_DIR)/*.m)
OBJ_FILES := $(patsubst $(SRC_DIR)/%.m, $(BUILD_DIR)/%.o, $(SRC_FILES))

DISABLE_TESTS ?= 0

ifeq ($(DISABLE_TESTS), 0)
TESTS_SUBDIRS := $(wildcard $(TESTS_SRC_DIR)/*)
TESTS_BINARIES := $(patsubst $(TESTS_SRC_DIR)/%,$(TESTS_OUTPUT_DIR)/%,$(TESTS_SUBDIRS))
endif

HEADER_OUTPUT_DIR := $(OUTPUT_DIR)/include

all: copy-headers $(STATIC_LIB) $(DYNAMIC_LIB) $(TESTS_BINARIES)

$(STATIC_LIB): $(OBJ_FILES)
	@mkdir -p $(LIB_DIR)
	libtool $^ -o $@

$(DYNAMIC_LIB): LDFLAGS += -install_name @rpath/$(LIB_NAME).dylib -current_version $(LIB_VERSION)
$(DYNAMIC_LIB): $(OBJ_FILES)
	@mkdir -p $(LIB_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -shared -o $@ $^
	@codesign -f -s - $@

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.m
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) $(LDFLAGS) -c $< -o $@

ifeq ($(DISABLE_TESTS), 0)
.SECONDEXPANSION:
$(TESTS_OUTPUT_DIR)/%: $$(wildcard $(TESTS_SRC_DIR)/%/*.m) $(STATIC_LIB)
	@mkdir -p $(@D)
	@rm -rf $@
	$(CC) $(CFLAGS) $(LDFLAGS) -I$(OUTPUT_DIR)/include -o $@ $^
	@if [ "$(TARGET)" = "ios" ]; then \
		codesign -f -s - --entitlements misc/ios_ents.plist $@; \
	fi
endif

test: $(TESTS_BINARIES)
	@for test in $(TESTS_BINARIES); do \
		echo "Running $$test"; \
		$$test; \
	done

copy-headers: include/partial.h
	@rm -rf $(HEADER_OUTPUT_DIR)
	@mkdir -p $(HEADER_OUTPUT_DIR)
	@cp -r include/partial.h $(HEADER_OUTPUT_DIR)/partial.h

clean:
	@rm -rf $(BUILD_DIR)/* $(OUTPUT_DIR)/*

clean-all:
	@rm -rf build output
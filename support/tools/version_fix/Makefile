# Auto-detect repository ARM64 toolchain if present
REPO_CC := $(abspath ../../toolchains/armv8-toolchains/bin/aarch64-none-linux-gnu-gcc)
ifeq ($(wildcard $(REPO_CC)),)
    CROSS_COMPILE ?= aarch64-none-linux-gnu-
else
    CROSS_COMPILE ?= $(abspath ../../toolchains/armv8-toolchains/bin/aarch64-none-linux-gnu-)
endif

CC = $(CROSS_COMPILE)gcc
CFLAGS ?= -O2 -Wall

SRC = version_fix.c
TARGET = version_fix

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $^

clean:
	rm -f $(TARGET)

.PHONY: all clean
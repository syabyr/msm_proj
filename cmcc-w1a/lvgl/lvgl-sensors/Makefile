# Cross-build for the CMCC W1A (MSM8909, armv7).  The board runs musl
# (Alpine), so link statically against the arm-linux-gnueabi toolchain.

CC       := arm-linux-gnueabi-gcc
LVGL     ?= ../lvgl
BUILD    ?= build

CFLAGS   ?= -O2
CFLAGS   += -march=armv7-a -mtune=cortex-a7 -marm -g0 -pthread
CFLAGS   += -DLV_CONF_INCLUDE_SIMPLE -I. -I..
CFLAGS   += -ffunction-sections -fdata-sections
LDFLAGS  ?= -static -Wl,--gc-sections -pthread
LDLIBS   += -lm

# srcs.txt was generated on another machine; rewrite its prefix.
LVGL_SRCS := $(shell sed -n 's#^/home/mybays/develop/build/cmcc-w1a/lvgl/#$(LVGL)/#p' srcs.txt)
LVGL_OBJS := $(patsubst $(LVGL)/%.c,$(BUILD)/lvgl/%.o,$(LVGL_SRCS))
OBJS      := $(BUILD)/main.o $(LVGL_OBJS)

all: lvgl-sensors

lvgl-sensors: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(BUILD)/main.o: main.c lv_conf.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/lvgl/%.o: $(LVGL)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

# Headless host build used to render one frame into /tmp/lvgl-sensors.ppm.
HOSTCC    ?= gcc
HOSTFLAGS ?= -O2
HOSTFLAGS += -DLV_CONF_INCLUDE_SIMPLE -I. -I..
SIM_OBJS  := $(patsubst $(LVGL)/%.c,$(BUILD)/sim/lvgl/%.o,$(LVGL_SRCS))

sim: lvgl-sensors-sim

lvgl-sensors-sim: $(BUILD)/sim/sim.o $(SIM_OBJS)
	$(HOSTCC) -o $@ $^ -lm -pthread

$(BUILD)/sim/sim.o: sim.c main.c lv_conf.h
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTFLAGS) -c -o $@ sim.c

$(BUILD)/sim/lvgl/%.o: $(LVGL)/%.c
	@mkdir -p $(dir $@)
	$(HOSTCC) $(HOSTFLAGS) -c -o $@ $<

clean:
	rm -rf $(BUILD) lvgl-sensors lvgl-sensors-sim

.PHONY: all sim clean

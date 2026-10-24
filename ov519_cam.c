// OV519 bridge + OV76xx sensor control, ported from Linux gspca ov519.c (GPL-2.0-or-later).
#include "ov519_cam.h"
#include <string.h>
#include <unistd.h>

enum { SEN_UNKNOWN, SEN_OV7610, SEN_OV7620, SEN_OV76BE, SEN_OV7640, SEN_OV7670 };

int cam_err;
static int cache[256];
static int sensor = SEN_UNKNOWN;
static int is_7648;

// like gspca's usb_err: after the first failure every access becomes a no-op
static void reg_w(int idx, int val) {
    unsigned char b = val;
    if (cam_err) return;
    usleep(150);
    if (cam_usb_ctrl(0, idx, &b, 1) < 0) { cam_err = 1; cam_log("reg_w 0x%02x failed", idx); }
}

static int reg_r(int idx, int len) {
    unsigned char b[8] = {0};
    if (cam_err) return 0;
    usleep(150);
    if (cam_usb_ctrl(1, idx, b, len) < 0) { cam_err = 1; cam_log("reg_r 0x%02x failed", idx); }
    return b[0];
}

static void reg_w_mask(int idx, int val, int mask) {
    reg_w(idx, (val & mask) | (reg_r(idx, 1) & ~mask));
}

static void i2c_w_raw(int reg, int val) {
    reg_w(0x42, reg);
    reg_w(0x45, val);
    reg_w(0x47, 0x01);
    usleep(4000);
    reg_r(0x47, 8);
}

static int i2c_r_raw(int reg) {
    reg_w(0x43, reg);
    reg_w(0x47, 0x03);
    reg_r(0x47, 8);
    reg_w(0x47, 0x05);
    reg_r(0x47, 8);
    return reg_r(0x45, 1);
}

static void i2c_w(int reg, int val) {
    val &= 0xff;
    if (cache[reg] == val) return;
    i2c_w_raw(reg, val);
    if (reg == 0x12 && (val & 0x80)) memset(cache, 0xff, sizeof cache);
    else cache[reg] = val;
}

static int i2c_r(int reg) {
    if (cache[reg] < 0) cache[reg] = i2c_r_raw(reg);
    return cache[reg];
}

static void i2c_w_mask(int reg, int val, int mask) {
    i2c_w(reg, (val & mask) | (i2c_r(reg) & ~mask));
}

static void write_regs(const unsigned char (*l)[2], size_t n, void (*w)(int, int)) {
    for (size_t i = 0; i < n; i++) w(l[i][0], l[i][1]);
}
#define WRITE_REGS(l, w) write_regs(l, sizeof(l) / sizeof(l[0]), w)

static const unsigned char init_519[][2] = {
    {0x5a, 0x6d}, {0x53, 0x9b}, {0x54, 0xff}, {0x5d, 0x03}, {0x49, 0x01},
    {0x48, 0x00}, {0x72, 0xee}, {0x51, 0x0f}, {0x51, 0x00}, {0x22, 0x00},
};
static const unsigned char norm_7610[][2] = {
    {0x10, 0xff}, {0x16, 0x06}, {0x28, 0x24}, {0x2b, 0xac}, {0x12, 0x00},
    {0x38, 0x81}, {0x28, 0x24}, {0x0f, 0x85}, {0x15, 0x01}, {0x20, 0x1c},
    {0x23, 0x2a}, {0x24, 0x10}, {0x25, 0x8a}, {0x26, 0xa2}, {0x27, 0xc2},
    {0x2a, 0x04}, {0x2c, 0xfe}, {0x2d, 0x93}, {0x30, 0x71}, {0x31, 0x60},
    {0x32, 0x26}, {0x33, 0x20}, {0x34, 0x48}, {0x12, 0x24}, {0x11, 0x01},
    {0x0c, 0x24}, {0x0d, 0x24},
};
static const unsigned char norm_7620[][2] = {
    {0x12, 0x80}, {0x00, 0x00}, {0x01, 0x80}, {0x02, 0x80}, {0x03, 0xc0},
    {0x06, 0x60}, {0x07, 0x00}, {0x0c, 0x24}, {0x0c, 0x24}, {0x0d, 0x24},
    {0x11, 0x01}, {0x12, 0x24}, {0x13, 0x01}, {0x14, 0x84}, {0x15, 0x01},
    {0x16, 0x03}, {0x17, 0x2f}, {0x18, 0xcf}, {0x19, 0x06}, {0x1a, 0xf5},
    {0x1b, 0x00}, {0x20, 0x18}, {0x21, 0x80}, {0x22, 0x80}, {0x23, 0x00},
    {0x26, 0xa2}, {0x27, 0xea}, {0x28, 0x22}, {0x29, 0x00}, {0x2a, 0x10},
    {0x2b, 0x00}, {0x2c, 0x88}, {0x2d, 0x91}, {0x2e, 0x80}, {0x2f, 0x44},
    {0x60, 0x27}, {0x61, 0x02}, {0x62, 0x5f}, {0x63, 0xd5}, {0x64, 0x57},
    {0x65, 0x83}, {0x66, 0x55}, {0x67, 0x92}, {0x68, 0xcf}, {0x69, 0x76},
    {0x6a, 0x22}, {0x6b, 0x00}, {0x6c, 0x02}, {0x6d, 0x44}, {0x6e, 0x80},
    {0x6f, 0x1d}, {0x70, 0x8b}, {0x71, 0x00}, {0x72, 0x14}, {0x73, 0x54},
    {0x74, 0x00}, {0x75, 0x8e}, {0x76, 0x00}, {0x77, 0xff}, {0x78, 0x80},
    {0x79, 0x80}, {0x7a, 0x80}, {0x7b, 0xe2}, {0x7c, 0x00},
};
static const unsigned char norm_7640[][2] = {{0x12, 0x80}, {0x12, 0x14}};
static const unsigned char mode_init_519[][2] = {
    {0x5d, 0x03}, {0x53, 0x9f}, {0x54, 0x0f}, {0xa2, 0x20}, {0xa3, 0x18},
    {0xa4, 0x04}, {0xa5, 0x28}, {0x37, 0x00}, {0x55, 0x02}, {0x22, 0x1d},
    {0x17, 0x50}, {0x37, 0x00}, {0x40, 0xff}, {0x46, 0x00}, {0x59, 0x04},
    {0xff, 0x00},
};

static int try_sensor(int sid) {
    reg_w(0x41, sid);
    reg_w(0x44, sid + 1);
    memset(cache, 0xff, sizeof cache);
    i2c_w(0x12, 0x80);
    usleep(150000);
    for (int i = 0; i < 10; i++) {
        int hi = i2c_r_raw(0x1c), lo = i2c_r_raw(0x1d);
        if (hi == 0x7f && lo == 0xa2) return 1;
        i2c_w_raw(0x12, 0x80);
        memset(cache, 0xff, sizeof cache);
        usleep(150000);
    }
    return 0;
}

static const char *detect_7xx0(void) {
    int rc = i2c_r(0x29) & 3, hi, lo;
    switch (rc) {
    case 3:
        hi = i2c_r(0x0a), lo = i2c_r(0x0b);
        sensor = (hi == 0x76 && (lo & 0xf0) == 0x70) ? SEN_OV7670 : SEN_OV7610;
        return sensor == SEN_OV7670 ? "OV7670 (unsupported here)" : "OV7610";
    case 1:
        sensor = (i2c_r(0x15) & 1) ? SEN_OV7620 : SEN_OV76BE;
        return sensor == SEN_OV7620 ? "OV7620AE" : "OV76BE";
    case 0:
        hi = i2c_r(0x0a), lo = i2c_r(0x0b);
        if (hi != 0x76) return sensor = SEN_OV7620, "OV7620";
        if (lo == 0x40 || lo == 0x45 || lo == 0x48) return sensor = SEN_OV7640, is_7648 = lo == 0x48, is_7648 ? "OV7648" : "OV7645";
        return "unsupported OV76xx";
    }
    return "unknown";
}

int cam_init(void) {
    cam_log("init: bridge");
    WRITE_REGS(init_519, reg_w);
    cam_log("init: sensor probe");
    if (!try_sensor(0x42)) {
        cam_log("no OV7xx0 sensor answered");
        return 0;
    }
    cam_log("init: sensor = %s", detect_7xx0());
    switch (sensor) {
    case SEN_OV7640: WRITE_REGS(norm_7640, i2c_w); break;
    case SEN_OV7620: WRITE_REGS(norm_7620, i2c_w); break;
    case SEN_OV7610:
    case SEN_OV76BE: WRITE_REGS(norm_7610, i2c_w); i2c_w_mask(0x0e, 0x00, 0x40); break;
    default: return 0;
    }
    reg_w_mask(0x71, 0, 1); // LED off
    return !cam_err;
}

static void vga_7620_style(void) {
    i2c_w_mask(0x28, 0x20, 0x20);
    i2c_w(0x24, 0x3a);
    i2c_w(0x25, 0x60);
    i2c_w_mask(0x2d, 0x00, 0x40);
    i2c_w_mask(0x67, 0x90, 0xf0);
    i2c_w_mask(0x74, 0x00, 0x20);
    i2c_w_mask(0x13, 0x00, 0x20);
    i2c_w_mask(0x12, 0x04, 0x06);
}

// gspca ov519_mode_init_regs frame-rate table for OV7640/7648 at 640x480: {fps, 0xa4, 0x23, clockdiv}
static const unsigned char fr_7640[][4] = {
    {30, 0x0c, 0xff, 0}, {25, 0x0c, 0x1f, 0}, {20, 0x0c, 0x1b, 0},
    {15, 0x04, 0xff, 1}, {10, 0x04, 0x1f, 1}, {5, 0x04, 0x1b, 1},
};

// 640x480, or 320x240 (qvga, OV7640/7648 only; what the PS2 uses)
void cam_start(int fps, int qvga) {
    qvga = qvga && sensor == SEN_OV7640;
    const int w = qvga ? 320 : 640, hgt = qvga ? 240 : 480;
    int clockdiv = 0, hs, he, vs;
    cam_log("start: bridge mode");
    WRITE_REGS(mode_init_519, reg_w);
    if (sensor == SEN_OV7640) reg_w_mask(0x20, 0x10, 0x10);
    reg_w(0x10, w >> 4);
    reg_w(0x11, hgt >> 3);
    reg_w(0x12, qvga && is_7648); // gspca "Fix 320x240 on ov519 + ov7648"
    for (int r = 0x13; r <= 0x16; r++) reg_w(r, 0);
    reg_w(0x25, 0x03);
    reg_w(0x26, 0x00);
    if (sensor == SEN_OV7640) {
        size_t i = 0; // unknown fps falls back to 30, like the kernel's default case
        for (size_t k = 0; k < sizeof fr_7640 / sizeof fr_7640[0]; k++)
            if (fr_7640[k][0] == fps) i = k;
        reg_w(0xa4, fr_7640[i][1]);
        reg_w(0x23, fr_7640[i][2]);
        clockdiv = fr_7640[i][3];
        // Undocumented: sensor clock divider, fps ~ 120/n (found by register sweep, see sweep.log).
        // gspca's 4 = 12 MHz, half the sensor's rated 24 MHz. 2 gives QVGA 60 fps like the PS2;
        // VGA at 2 starves the bridge, 3 gives VGA 20 fps.
        reg_w(0x59, qvga ? 2 : 3);
    }

    cam_log("start: sensor window %dx%d", w, hgt);
    i2c_w_mask(0x14, qvga ? 0x20 : 0x00, 0x20);
    switch (sensor) {
    case SEN_OV7610:
        hs = 0x38, he = 0x3a, vs = 0x05;
        i2c_w(0x35, 0x9e);
        i2c_w_mask(0x13, 0x00, 0x20);
        i2c_w_mask(0x12, 0x04, 0x06);
        break;
    case SEN_OV76BE:
        hs = 0x38, he = 0x3a, vs = 0x05;
        vga_7620_style();
        i2c_w(0x35, 0x9e);
        break;
    case SEN_OV7620:
        hs = 0x2f, he = 0x2f, vs = 0x05;
        vga_7620_style();
        break;
    default:
        hs = 0x1a, he = 0x1a, vs = 0x03;
        i2c_w_mask(0x28, qvga ? 0x00 : 0x20, 0x20);
        i2c_w_mask(0x2d, qvga ? 0x40 : 0x00, 0x40); // qvga: removes vertical shaking
        i2c_w_mask(0x67, qvga ? 0xf0 : 0x90, 0xf0);
        i2c_w_mask(0x74, qvga ? 0x20 : 0x00, 0x20); // qvga: higher auto gain
        i2c_w_mask(0x12, 0x04, 0x04);
        break;
    }
    i2c_w(0x11, clockdiv);
    i2c_w(0x17, hs);
    i2c_w(0x18, he + (w >> (qvga ? 1 : 2)));
    i2c_w(0x19, vs);
    i2c_w(0x1a, vs + (hgt >> (qvga ? 0 : 1)));

    cam_log("start: restart stream");
    reg_w(0x50, 0x40);
    reg_w(0x50, 0x00);
    reg_w(0x51, 0x0f);
    reg_w(0x51, 0x00);
    reg_w(0x22, 0x1d);
    reg_w_mask(0x71, 1, 1); // LED on
}

void cam_stop(void) {
    reg_w(0x51, 0x0f);
    reg_w(0x51, 0x00);
    reg_w(0x22, 0x00);
    reg_w_mask(0x71, 0, 1);
    reg_w(0x57, 0x23);
}


// gspca setbrightness/setcolors/setfreq_i for OV7610-family sensors.
// Linux defaults: 127, 127, freq 0. freq: 0 off, 1 = 50 Hz, 2 = 60 Hz.
void cam_set_controls(int brightness, int saturation, int freq) {
    i2c_w(0x06, brightness);
    i2c_w(0x03, sensor == SEN_OV7640 ? (saturation & 0xf0) : saturation);
    i2c_w_mask(0x2d, freq ? 0x04 : 0x00, 0x04);
    i2c_w_mask(0x2a, freq == 1 ? 0x80 : 0x00, 0x80);
    if (freq == 1) i2c_w(0x2b, 0xac);
}

// calibration knob: raw sensor register write (masked)
void cam_i2c_set(int reg, int val, int mask) {
    i2c_w_mask(reg, val, mask);
}

void cam_reg_set(int reg, int val, int mask) {
    reg_w_mask(reg, val, mask);
}

int cam_reg_get(int reg) {
    return reg_r(reg, 1);
}

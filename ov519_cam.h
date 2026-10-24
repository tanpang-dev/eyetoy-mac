#pragma once
#include <stdint.h>

// provided by the USB layer: in=1 for vendor IN (0xc0), 0 for OUT (0x40); bRequest 1, wValue 0
int cam_usb_ctrl(int in, uint16_t idx, uint8_t *buf, uint16_t len);
void cam_log(const char *fmt, ...);

extern int cam_err;
int cam_init(void);  // 1 = sensor found and configured
void cam_start(int fps, int qvga); // JPEG 640x480 or 320x240; OV7640/7648 fps: 30/25/20/15/10/5
void cam_stop(void);
void cam_set_controls(int brightness, int saturation, int freq); // 0-255, 0-255, 0 off/1 50Hz/2 60Hz
void cam_i2c_set(int reg, int val, int mask); // raw sensor tweak, e.g. from EYETOY_I2C
void cam_reg_set(int reg, int val, int mask); // raw bridge tweak, e.g. from EYETOY_REG
int cam_reg_get(int reg);

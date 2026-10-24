#pragma once
#import <Foundation/Foundation.h>

// Single EyeToy, single client (ov519_cam.c keeps global state).
// Called on the stream's serial queue for every complete JPEG frame.
typedef void (^EyeToyFrameHandler)(NSData *jpeg);

typedef struct {
    long packets, bytes, errors, sof, eof, bad_eof, frames;
} EyeToyStats;

// Opens interface 0, selects the iso alt setting, initialises the sensor and starts streaming.
BOOL eyetoy_start(int fps, int freq, BOOL qvga, EyeToyFrameHandler handler);
// Stops the camera, lets in-flight requests drain (never aborts) and closes the interface.
void eyetoy_stop(void);
BOOL eyetoy_running(void);
EyeToyStats eyetoy_stats(void);

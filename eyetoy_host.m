// EyeToy capture CLI (debugging; the camera extension uses the same eyetoy_usb.m).
//
//   eyetoy_host [frames] [freq 0/1=50Hz/2=60Hz] [fps] [qvga 0/1]   -> frame_NN.jpg, log in eyetoy.log
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <stdarg.h>
#include "eyetoy_usb.h"
#include "ov519_cam.h"

#define LOG_PATH "eyetoy.log"

static int logfd = -1;

void cam_log(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf - 1, fmt, ap);
    va_end(ap);
    strcat(buf, "\n");
    fputs(buf, stderr);
    if (logfd < 0) return;
    write(logfd, buf, strlen(buf));
    fcntl(logfd, F_FULLFSYNC); // a panic must not eat the last lines
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int want = argc > 1 ? atoi(argv[1]) : 3;
        logfd = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
        cam_log("==== snap %d", want);

        __block int saved = 0;
        __block double t_first = 0, t_last = 0;
        BOOL ok = eyetoy_start(argc > 3 ? atoi(argv[3]) : 30, argc > 2 ? atoi(argv[2]) : 0, argc > 4 && atoi(argv[4]), ^(NSData *jpeg) {
            if (saved >= want) return;
            t_last = CFAbsoluteTimeGetCurrent();
            if (!saved) t_first = t_last;
            [jpeg writeToFile:[NSString stringWithFormat:@"frame_%02d.jpg", saved++] atomically:NO];
        });
        if (!ok) return 1;

        for (int t = 0; saved < want && eyetoy_running() && t < 400; t++) {
            usleep(100000);
            if (t % 10 == 9) cam_log("iso: %ld packets %ld errors, %d frames", eyetoy_stats().packets, eyetoy_stats().errors, saved);
        }
        eyetoy_stop();
        EyeToyStats s = eyetoy_stats();
        if (saved > 1) cam_log("fps: %.2f (SOF %ld, EOF %ld, EOF flagged %ld)", (saved - 1) / (t_last - t_first), s.sof, s.eof, s.bad_eof);
        cam_log("exit");
    }
    return 0;
}

// OV519 bridge register sweep: looking for the sensor clock (fps x2).
// Streams QVGA interlaced (30 fps baseline), flips one bit at a time, measures fps, restores.
//
//   eyetoy_sweep dump            read-only dump of bridge registers
//   eyetoy_sweep [first] [last]  sweep candidate registers in [first,last] (hex)
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <stdarg.h>
#include "eyetoy_usb.h"
#include "ov519_cam.h"

#define LOG_PATH "sweep.log"

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
    fcntl(logfd, F_FULLFSYNC);
}

// registers whose disturbance is hard to recover from or breaks framing
static BOOL excluded(int r) {
    return (r >= 0x10 && r <= 0x16) || r == 0x25 || r == 0x30 || (r >= 0x40 && r <= 0x47) ||
           r == 0x50 || r == 0x51 || r == 0x53 || r == 0x5a || r == 0x5d || r == 0x71 || r == 0x72 || r == 0xa0;
}

static double measure(double secs) {
    long e0 = eyetoy_stats().eof;
    usleep((useconds_t)(secs * 1e6));
    return (eyetoy_stats().eof - e0) / secs;
}

static void restart_stream(void) {
    cam_reg_set(0x51, 0x0f, 0xff);
    cam_reg_set(0x51, 0x00, 0xff);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        logfd = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
        BOOL dump = argc > 1 && !strcmp(argv[1], "dump");
        int first = dump ? 0 : (argc > 1 ? (int)strtol(argv[1], NULL, 16) : 0x17);
        int last = dump ? 0xff : (argc > 2 ? (int)strtol(argv[2], NULL, 16) : 0xbf);
        cam_log("==== sweep %s %02x-%02x", dump ? "dump" : "bits", first, last);

        if (!eyetoy_start(30, 0, YES, ^(NSData *jpeg) {})) return 1;
        double base = measure(2.0);
        cam_log("baseline %.1f fps", base);

        if (dump) {
            for (int r = 0; r <= 0xff; r++) {
                if (r >= 0x40 && r <= 0x47) continue; // I2C data/ctl reads have side effects
                printf("%02x=%02x%s", r, cam_reg_get(r), r % 16 == 15 ? "\n" : " ");
            }
            printf("\n");
        } else {
            for (int r = first; r <= last && !cam_err; r++) {
                if (excluded(r)) continue;
                int orig = cam_reg_get(r);
                for (int b = 0; b < 8 && !cam_err; b++) {
                    cam_reg_set(r, orig ^ (1 << b), 0xff);
                    usleep(300000);
                    double f = measure(1.2);
                    cam_reg_set(r, orig, 0xff);
                    cam_log("%02x orig %02x bit%d -> %5.1f fps%s", r, orig, b, f, f > base * 1.4 ? "   <<<<< FASTER" : "");
                    if (measure(1.0) < base * 0.5) {
                        cam_log("%02x: stream not back, restarting", r);
                        restart_stream();
                        if (measure(1.5) < base * 0.5) { cam_log("stream dead after %02x bit%d; replug needed", r, b); goto out; }
                    }
                }
            }
        }
    out:
        eyetoy_stop();
        cam_log("exit");
    }
    return 0;
}

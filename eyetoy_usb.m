// EyeToy USB transport via IOUSBHost.framework (no libusb).
// Never touches pipes of alt 0, whose iso endpoint has wMaxPacketSize 0:
// libusb's claim queries it and panicked the kernel twice on macOS 27.
#import "eyetoy_usb.h"
#import <IOUSBHost/IOUSBHost.h>
#include "ov519_cam.h"

#define ISO_ALT 4
#define ISO_EP 0x81
#define TX_PER_REQ 32
#define NREQ 2
#define SKIP_FRAMES 3

static IOUSBHostInterface *itf;
static IOUSBHostPipe *pipe_;
static dispatch_queue_t queue;
static EyeToyFrameHandler on_frame;
static volatile int stop_req, inflight;
static uint64_t next_frame;
static NSMutableData *frame;
static int in_frame, skip;
static EyeToyStats st;

int cam_usb_ctrl(int in, uint16_t idx, uint8_t *buf, uint16_t len) {
    IOUSBDeviceRequest req = {.bmRequestType = in ? 0xc0 : 0x40, .bRequest = 1, .wValue = 0, .wIndex = idx, .wLength = len};
    NSMutableData *d = [NSMutableData dataWithBytes:buf length:len];
    NSUInteger n = 0;
    NSError *err = nil;
    if (![itf sendDeviceRequest:req data:d bytesTransferred:&n completionTimeout:0.5 error:&err]) {
        cam_log("ctrl %s 0x%02x: %s", in ? "in" : "out", idx, err.localizedDescription.UTF8String);
        return -1;
    }
    if (in) memcpy(buf, d.bytes, len);
    return (int)n;
}

static io_service_t find_interface0(void) {
    // createMatchingDictionaryWithVendorID: matches nothing here, so filter by hand
    io_service_t svc = IO_OBJECT_NULL, s;
    io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it);
    while (!svc && (s = IOIteratorNext(it))) {
        NSDictionary *p = nil;
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) p = CFBridgingRelease(props);
        int pid = [p[@"idProduct"] intValue];
        if ([p[@"idVendor"] intValue] == 0x054c && (pid == 0x0154 || pid == 0x0155) && [p[@"bInterfaceNumber"] intValue] == 0) svc = s;
        else IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return svc;
}

// ov519_pkt_scan
static void pkt_scan(const uint8_t *d, uint32_t len) {
    if (len >= 16 && d[0] == 0xff && d[1] == 0xff && d[2] == 0xff) {
        if (d[3] == 0x50) {
            st.sof++;
            d += 16, len -= 16;
            in_frame = (d[0] == 0xff || d[1] == 0xd8);
            frame.length = 0;
        } else if (d[3] == 0x51) {
            st.eof++;
            if (d[9]) st.bad_eof++;
            if (in_frame && d[9] == 0 && frame.length) {
                if (skip > 0) skip--;
                else st.frames++, on_frame([frame copy]);
            }
            in_frame = 0;
            return;
        }
    }
    if (!in_frame) return;
    if (frame.length + len > 640 * 480 * 2) { in_frame = 0; return; }
    [frame appendBytes:d length:len];
}

static void submit(NSMutableData *buf, IOUSBHostIsochronousTransaction *tx, int psize);

static void on_complete(NSMutableData *buf, IOUSBHostIsochronousTransaction *tx, int psize, IOReturn status) {
    inflight--;
    if (status != kIOReturnSuccess && status != kIOReturnUnderrun) {
        cam_log("iso request status 0x%08x, stopping", status);
        stop_req = 1;
    }
    for (int i = 0; i < TX_PER_REQ; i++) {
        if (tx[i].status != kIOReturnSuccess && tx[i].status != kIOReturnUnderrun) { st.errors++; continue; }
        if (!tx[i].completeCount) continue;
        st.packets++, st.bytes += tx[i].completeCount;
        pkt_scan((const uint8_t *)buf.bytes + tx[i].offset, tx[i].completeCount);
    }
    if (stop_req) { free(tx); return; }
    submit(buf, tx, psize);
}

static void submit(NSMutableData *buf, IOUSBHostIsochronousTransaction *tx, int psize) {
    for (int i = 0; i < TX_PER_REQ; i++)
        tx[i] = (IOUSBHostIsochronousTransaction){.requestCount = psize, .offset = i * psize};
    NSError *err = nil;
    BOOL ok = [pipe_ enqueueIORequestWithData:buf transactionList:tx transactionListCount:TX_PER_REQ
        firstFrameNumber:next_frame options:IOUSBHostIsochronousTransferOptionsNone error:&err
        completionHandler:^(IOReturn status, IOUSBHostIsochronousTransaction list[]) {
            on_complete(buf, tx, psize, status);
        }];
    if (!ok) {
        cam_log("enqueue at frame %llu: %s", next_frame, err.localizedDescription.UTF8String);
        stop_req = 1;
        free(tx);
        return;
    }
    inflight++;
    next_frame += TX_PER_REQ;
}

// EYETOY_I2C="reg:val:mask,..." (hex): calibration knob for sensor experiments
static void apply_i2c_tweaks(void) {
    const char *tw = getenv("EYETOY_I2C");
    for (NSString *t in tw ? [@(tw) componentsSeparatedByString:@","] : @[]) {
        unsigned r = 0, v = 0, m = 0xff;
        if (sscanf(t.UTF8String, "%x:%x:%x", &r, &v, &m) >= 2) { cam_log("i2c tweak %02x=%02x/%02x", r, v, m); cam_i2c_set(r, v, m); }
    }
}

static void close_interface(void) {
    pipe_ = nil;
    [itf destroy];
    itf = nil;
}

BOOL eyetoy_start(int fps, int freq, EyeToyFrameHandler handler) {
    if (itf) return NO;
    io_service_t svc = find_interface0();
    if (!svc) { cam_log("EyeToy interface 0 not found"); return NO; }

    NSError *err = nil;
    if (!queue) queue = dispatch_queue_create("eyetoy.iso", DISPATCH_QUEUE_SERIAL);
    itf = [[IOUSBHostInterface alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone
                                                  queue:queue error:&err interestHandler:nil];
    IOObjectRelease(svc);
    if (!itf) { cam_log("open failed: %s", err.localizedDescription.UTF8String); return NO; }

    cam_err = 0;
    if (![itf selectAlternateSetting:ISO_ALT error:&err]) {
        cam_log("select alt failed: %s", err.localizedDescription.UTF8String);
        close_interface();
        return NO;
    }
    pipe_ = [itf copyPipeWithAddress:ISO_EP error:&err];
    if (!pipe_ || !cam_init()) {
        cam_log("pipe/init failed: %s", err.localizedDescription.UTF8String ?: "sensor");
        close_interface();
        return NO;
    }
    int psize = (int)pipe_.descriptors->descriptor.wMaxPacketSize & 0x7ff;
    cam_log("iso: ep 0x%02x psize %d, %d requests x %d frames", ISO_EP, psize, NREQ, TX_PER_REQ);

    on_frame = handler;
    frame = [NSMutableData dataWithCapacity:640 * 480 * 2];
    in_frame = 0, skip = SKIP_FRAMES, stop_req = 0, st = (EyeToyStats){0};
    cam_start(fps);
    cam_set_controls(127, 127, freq);
    apply_i2c_tweaks();
    if (cam_err) { close_interface(); return NO; }

    dispatch_sync(queue, ^{
        next_frame = [itf frameNumberWithTime:NULL] + 10;
        for (int i = 0; i < NREQ && !stop_req; i++) {
            NSError *e = nil;
            NSMutableData *buf = [itf ioDataWithCapacity:(NSUInteger)psize * TX_PER_REQ error:&e];
            if (!buf) { cam_log("ioData: %s", e.localizedDescription.UTF8String); stop_req = 1; break; }
            submit(buf, malloc(sizeof(IOUSBHostIsochronousTransaction) * TX_PER_REQ), psize);
        }
    });
    return !stop_req;
}

void eyetoy_stop(void) {
    if (!itf) return;
    stop_req = 1;
    cam_stop();
    for (int t = 0; inflight > 0 && t < 50; t++) usleep(100000);
    cam_log("stop: %d requests left; %ld frames, %ld packets, %ld errors", inflight, st.frames, st.packets, st.errors);
    if (inflight) return; // ponytail: leaks the interface rather than destroying it under live requests
    close_interface();
}

BOOL eyetoy_running(void) {
    return itf && !stop_req;
}

EyeToyStats eyetoy_stats(void) {
    return st;
}

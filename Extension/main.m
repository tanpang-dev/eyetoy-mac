#import <Foundation/Foundation.h>
#import <os/log.h>
#include <stdarg.h>
#import "EyeToyProvider.h"

void cam_log(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    os_log(OS_LOG_DEFAULT, "eyetoy: %{public}s", buf);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        EyeToyProviderSource *providerSource = [[EyeToyProviderSource alloc] initWithClientQueue:nil];
        [CMIOExtensionProvider startServiceWithProvider:providerSource.provider];
        CFRunLoopRun();
    }
    return 0;
}

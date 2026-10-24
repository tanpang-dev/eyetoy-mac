// Installs / removes the EyeToy camera extension. Run from /Applications:
//   /Applications/EyeToyCam.app/Contents/MacOS/EyeToyCam [activate|deactivate]
#import <Foundation/Foundation.h>
#import <SystemExtensions/SystemExtensions.h>

static NSString *const kExtensionID = @"dev.tanpang.EyeToyCam.Extension";

@interface Delegate : NSObject<OSSystemExtensionRequestDelegate>
@end

@implementation Delegate

- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request
                  actionForReplacingExtension:(OSSystemExtensionProperties *)existing
                                withExtension:(OSSystemExtensionProperties *)ext {
    NSLog(@"replacing %@ with %@", existing.bundleVersion, ext.bundleVersion);
    return OSSystemExtensionReplacementActionReplace;
}

- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
    NSLog(@"needs approval: System Settings > General > Login Items & Extensions > Camera Extensions");
}

- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    NSLog(@"done (result %ld)", (long)result);
    exit(0);
}

- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    NSLog(@"failed: %@", error);
    exit(1);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL deactivate = argc > 1 && !strcmp(argv[1], "deactivate");
        dispatch_queue_t q = dispatch_get_main_queue();
        OSSystemExtensionRequest *req = deactivate
            ? [OSSystemExtensionRequest deactivationRequestForExtension:kExtensionID queue:q]
            : [OSSystemExtensionRequest activationRequestForExtension:kExtensionID queue:q];
        Delegate *d = [Delegate new];
        req.delegate = d;
        [OSSystemExtensionManager.sharedManager submitRequest:req];
        dispatch_main();
    }
}

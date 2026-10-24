// Installs / removes the EyeToy camera extension. Double-click it in /Applications, or:
//   /Applications/EyeToyCam.app/Contents/MacOS/EyeToyCam [activate|deactivate]
#import <Foundation/Foundation.h>
#import <SystemExtensions/SystemExtensions.h>

static NSString *const kExtensionID = @"dev.tanpang.EyeToyCam.Extension";
static BOOL deactivating;

// Finder launches show nothing on stdout, so tell the user with a plain dialog.
static void tell(NSString *message, BOOL wait) {
    NSLog(@"%@", message);
    CFStringRef title = CFSTR("EyeToy Cam");
    if (wait) {
        CFOptionFlags response;
        CFUserNotificationDisplayAlert(0, kCFUserNotificationNoteAlertLevel, NULL, NULL, NULL, title, (__bridge CFStringRef)message, NULL, NULL, NULL, &response);
    } else {
        CFUserNotificationDisplayNotice(0, kCFUserNotificationNoteAlertLevel, NULL, NULL, NULL, title, (__bridge CFStringRef)message, NULL);
    }
}

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
    tell(@"システム設定 → 一般 → ログイン項目と機能拡張 → カメラ拡張機能 で「EyeToy」をオンにしてください。", NO);
}

- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    tell(result == OSSystemExtensionRequestCompleted
             ? (deactivating ? @"アンインストールしました。" : @"完了しました。カメラアプリで「EyeToy」を選んでください。")
             : @"Mac を再起動すると完了します。", YES);
    exit(0);
}

- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    tell([NSString stringWithFormat:@"失敗しました: %@", error.localizedDescription], YES);
    exit(1);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL deactivate = deactivating = argc > 1 && !strcmp(argv[1], "deactivate");
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

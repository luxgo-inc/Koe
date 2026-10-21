#import "KoeObjC.h"
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void (^gReportHandler)(NSException *) = nil;
static IMP gOriginalReportException = NULL;

static void KoeReportException(id self, SEL _cmd, NSException *exception) {
    if (gReportHandler) { gReportHandler(exception); }
    if (gOriginalReportException) {
        ((void (*)(id, SEL, NSException *))gOriginalReportException)(self, _cmd, exception);
    }
}
#endif

NSErrorDomain const KoeObjCExceptionErrorDomain = @"jp.luxgo.koe.objc-exception";
NSString * const KoeObjCExceptionNameKey = @"KoeObjCExceptionName";

@implementation KoeObjCException

+ (BOOL)catchingException:(NS_NOESCAPE void (^)(void))block
                    error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:KoeObjCExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                KoeObjCExceptionNameKey: exception.name,
            }];
        }
        return NO;
    }
}

#if TARGET_OS_OSX
+ (void)observeAppKitReportedExceptions:(void (^)(NSException *exception))handler {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gReportHandler = [handler copy];
        Method m = class_getInstanceMethod([NSApplication class], @selector(reportException:));
        if (m) {
            gOriginalReportException = method_setImplementation(m, (IMP)KoeReportException);
        }
    });
}
#endif

@end

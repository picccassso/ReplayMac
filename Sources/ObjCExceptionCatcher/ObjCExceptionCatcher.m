#import "ObjCExceptionCatcher.h"

NSErrorDomain const RCObjCExceptionErrorDomain = @"RCObjCExceptionErrorDomain";

@implementation RCObjCException

+ (BOOL)performCatching:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:RCObjCExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                @"ExceptionName": exception.name
            }];
        }
        return NO;
    }
}

@end

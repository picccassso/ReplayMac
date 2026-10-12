#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Turns an Objective-C exception into an `NSError`, so Swift code can recover
/// from framework calls that raise instead of returning an error, such as
/// `-[AVAudioNode installTapOnBus:...]` when the audio hardware is changing.
/// Swift cannot catch these exceptions itself; uncaught, they abort the app.
@interface RCObjCException : NSObject

+ (BOOL)performCatching:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;

@end

FOUNDATION_EXPORT NSErrorDomain const RCObjCExceptionErrorDomain;

NS_ASSUME_NONNULL_END

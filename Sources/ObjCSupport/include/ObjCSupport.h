#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and converts any raised Objective-C `NSException` into an
/// `NSError`, so Swift callers can recover instead of crashing. Swift cannot
/// catch Objective-C exceptions, and some AVFoundation calls (e.g.
/// `-[AVAudioPlayerNode play]`) raise them for runtime audio-graph/hardware
/// states that are outside the caller's control.
///
/// Returns `nil` if `block` completed without raising.
NSError * _Nullable PRRunCatchingObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

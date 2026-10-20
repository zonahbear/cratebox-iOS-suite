#import <Foundation/Foundation.h>
/// Runs a block and returns the Objective-C exception it raised, if any. AVAudioEngine reports a format it
/// can't use (a channel count or sample rate the hardware refuses) by raising one, which Swift can't catch.
NSException * _Nullable CBTry(void (NS_NOESCAPE ^ _Nonnull block)(void));

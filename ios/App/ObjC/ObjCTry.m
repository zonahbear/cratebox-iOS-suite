#import "ObjCTry.h"
NSException * _Nullable CBTry(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try { block(); return nil; }
    @catch (NSException *e) { return e; }
}

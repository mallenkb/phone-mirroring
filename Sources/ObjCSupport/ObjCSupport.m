#import "ObjCSupport.h"

NSError * _Nullable PRRunCatchingObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if (exception.reason != nil) {
            info[NSLocalizedDescriptionKey] = exception.reason;
        }
        if (exception.name != nil) {
            info[@"PRExceptionName"] = exception.name;
        }
        if (exception.userInfo != nil) {
            info[@"PRExceptionUserInfo"] = exception.userInfo;
        }
        return [NSError errorWithDomain:@"PRObjCException" code:1 userInfo:info];
    }
}

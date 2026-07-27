#import "DHAVConferenceTestSupport.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import <dlfcn.h>

NSData *DHCreateSyntheticNegotiatorAnswer(NSData *offer, NSError **error) {
    if (error != nullptr) {
        *error = nil;
    }
    if (dlopen(
            "/System/Library/PrivateFrameworks/AVConference.framework/AVConference",
            RTLD_NOW | RTLD_LOCAL
        )
        == nullptr) {
        return nil;
    }

    Class negotiatorClass = NSClassFromString(@"AVCMediaStreamNegotiator");
    NSDictionary *options = @{
        @"AVCMediaStreamNegotiatorTransportProtocolType" : @2,
        @"AVCMediaStreamNegotiatorAccessNetworkType" : @1,
    };
    id allocated = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
        negotiatorClass,
        sel_registerName("alloc")
    );
    id answerer = reinterpret_cast<id (*)(id, SEL, id, id, NSError **)>(objc_msgSend)(
        allocated,
        sel_registerName("initWithOffer:options:error:"),
        offer,
        options,
        error
    );
    if (answerer == nil) {
        return nil;
    }
    BOOL created = reinterpret_cast<BOOL (*)(id, SEL)>(objc_msgSend)(
        answerer,
        sel_registerName("createAnswer")
    );
    if (!created) {
        return nil;
    }
    id answer = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
        answerer,
        sel_registerName("answer")
    );
    return [answer isKindOfClass:NSData.class] ? answer : nil;
}

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates the answer side of a local mode-5 AVConference negotiation.
NSData *_Nullable DHCreateSyntheticNegotiatorAnswer(
    NSData *offer,
    NSError *_Nullable *_Nullable error
);

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const DHAVConferenceErrorDomain;
FOUNDATION_EXPORT NSString *const DHAVConferenceErrorOperationKey;
FOUNDATION_EXPORT NSString *const DHAVConferenceErrorRuntimeClassKey;
FOUNDATION_EXPORT NSString *const DHAVConferenceErrorRuntimeSelectorKey;
FOUNDATION_EXPORT NSString *const DHAVConferenceErrorUnderlyingDomainKey;
FOUNDATION_EXPORT NSString *const DHAVConferenceErrorUnderlyingCodeKey;

/// Stable, caller-actionable failures emitted by the private media boundary.
typedef NS_ERROR_ENUM(DHAVConferenceErrorDomain, DHAVConferenceErrorCode) {
    DHAVConferenceErrorFrameworkUnavailable = 1,
    DHAVConferenceErrorRuntimeContractMismatch = 2,
    DHAVConferenceErrorInvalidState = 3,
    DHAVConferenceErrorNegotiationFailed = 4,
    DHAVConferenceErrorTransportSetupFailed = 5,
    DHAVConferenceErrorStreamSetupFailed = 6,
    DHAVConferenceErrorStreamFailed = 7,
    DHAVConferenceErrorDatagramRejected = 8,
    DHAVConferenceErrorRuntimeException = 9,
};

/// Observable lifecycle states for one non-reusable receiver session.
typedef NS_ENUM(NSInteger, DHAVConferenceReceiverState) {
    DHAVConferenceReceiverStateIdle = 0,
    DHAVConferenceReceiverStateOfferCreated = 1,
    DHAVConferenceReceiverStateConfigured = 2,
    DHAVConferenceReceiverStateStarting = 3,
    DHAVConferenceReceiverStateStreaming = 4,
    DHAVConferenceReceiverStateFailed = 5,
    DHAVConferenceReceiverStateInvalidated = 6,
};

/// Asynchronous lifecycle events delivered on the callback queue.
typedef NS_ENUM(NSInteger, DHAVConferenceReceiverEvent) {
    DHAVConferenceReceiverEventDidStart = 1,
    DHAVConferenceReceiverEventDidStop = 3,
    DHAVConferenceReceiverEventDidFail = 4,
    DHAVConferenceReceiverEventDidReceiveRTPTimeout = 8,
    DHAVConferenceReceiverEventDidReceiveRTCPTimeout = 9,
    DHAVConferenceReceiverEventDidRecoverFromRTCPTimeout = 10,
};

typedef void (^DHAVConferenceOutboundDatagramHandler)(NSData *datagram);
typedef void (^DHAVConferenceEventHandler)(
    DHAVConferenceReceiverEvent event,
    NSError *_Nullable error
);

/// A runtime-loaded AVConference receiver for a CoreDevice display stream.
///
/// The caller owns the CoreDevice tunnel and forwards its inbound RTP/RTCP
/// datagrams through ``ingestInboundDatagram:error:``. Datagrams emitted by
/// AVConference (principally RTCP feedback) are delivered through the outbound
/// handler and must be forwarded to the remote stream's sender port.
///
/// Each instance is single-use. Call ``invalidate`` for deterministic teardown
/// and create a new instance for another negotiation.
NS_SWIFT_NAME(AVConferenceReceiver)
@interface DHAVConferenceReceiver : NSObject

/// Verifies the iOS 27 runtime contract without starting a media stream or
/// contacting a device.
+ (BOOL)runSyntheticCapabilityProbeWithError:(NSError *_Nullable *_Nullable)error;

/// Validates private-framework availability and every class, selector, and
/// method encoding used by the receiver. Unlike the synthetic probe, this does
/// not require the platform to expose video codec rule collections.
+ (BOOL)validateRuntimeContractWithError:(NSError *_Nullable *_Nullable)error;

- (instancetype)initWithCallbackQueue:(dispatch_queue_t)callbackQueue
           outboundDatagramHandler:(DHAVConferenceOutboundDatagramHandler)outboundDatagramHandler
                      eventHandler:(DHAVConferenceEventHandler _Nullable)eventHandler
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property(nonatomic, readonly) DHAVConferenceReceiverState state;

/// Creates and retains Apple's mode-5 CoreDevice screen-sharing negotiator.
/// The returned binary plist must be used as `negotiatorOffer`.
- (NSData *_Nullable)makeNegotiatorOfferWithError:(NSError *_Nullable *_Nullable)error;

/// Applies the displayservice's `negotiatorAnswer`, derives the native stream
/// configuration, and creates the in-process shared-UDP receiver. This method
/// deliberately does not start decoding.
- (BOOL)configureWithNegotiatorAnswer:(NSData *)answer
                                error:(NSError *_Nullable *_Nullable)error;

/// Starts the configured transport stream. Final success or failure is
/// asynchronous and is reported through the event handler. Compressed video
/// decoding remains entirely app-owned.
- (BOOL)startWithError:(NSError *_Nullable *_Nullable)error;

/// Injects one complete datagram received from the userspace CoreDevice tunnel.
- (BOOL)ingestInboundDatagram:(NSData *)datagram
                        error:(NSError *_Nullable *_Nullable)error;

/// Stops AVConference, cancels callbacks, and closes all owned transport
/// resources. Safe to call more than once and from any thread.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END

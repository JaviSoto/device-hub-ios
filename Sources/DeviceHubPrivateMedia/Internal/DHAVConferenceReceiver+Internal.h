#import <DeviceHubPrivateMedia/DHAVConferenceReceiver.h>

NS_ASSUME_NONNULL_BEGIN

/// Merges AVConference's negotiated stream options with the in-process
/// transport options required by Device Hub's app-owned decoder.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
DHAVConferenceMergedStreamOptions(NSDictionary<NSString *, id> *generatedOptions);

/// The external AVConference lifecycle boundary. Production uses typed
/// `objc_msgSend` calls; hermetic tests substitute a recording implementation.
@protocol DHAVConferenceRuntimeOperations <NSObject>

- (void)setDelegate:(id _Nullable)delegate forVideoStream:(id)videoStream;
- (void)startVideoStream:(id)videoStream;
- (void)stopVideoStream:(id)videoStream;

@end

@interface DHAVConferenceReceiver (Internal)

- (instancetype)initWithCallbackQueue:(dispatch_queue_t)callbackQueue
           outboundDatagramHandler:(DHAVConferenceOutboundDatagramHandler)outboundDatagramHandler
                      eventHandler:(DHAVConferenceEventHandler _Nullable)eventHandler
                 runtimeOperations:(id<DHAVConferenceRuntimeOperations>)runtimeOperations;

@end

NS_ASSUME_NONNULL_END

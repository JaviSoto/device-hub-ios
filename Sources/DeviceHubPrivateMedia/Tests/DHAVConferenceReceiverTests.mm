#import <DeviceHubPrivateMedia/DHAVConferenceReceiver.h>

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../Internal/DHAVConferenceReceiver+Internal.h"
#import "DHAVConferenceTestSupport.h"

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

static DHAVConferenceReceiver *makeReceiver(void) {
    return [[DHAVConferenceReceiver alloc]
        initWithCallbackQueue:dispatch_get_main_queue()
   outboundDatagramHandler:^(__unused NSData *datagram) {
   }
              eventHandler:nil];
}

@interface RecordingRuntimeOperations : NSObject <DHAVConferenceRuntimeOperations>

@property(nonatomic) NSUInteger delegateSetCount;
@property(nonatomic) NSUInteger delegateClearCount;
@property(nonatomic) NSUInteger startCount;
@property(nonatomic) NSUInteger stopCount;

@end

@implementation RecordingRuntimeOperations

- (void)setDelegate:(id)delegate forVideoStream:(__unused id)videoStream {
    if (delegate == nil) {
        self.delegateClearCount += 1;
    } else {
        self.delegateSetCount += 1;
    }
}

- (void)startVideoStream:(__unused id)videoStream {
    self.startCount += 1;
}

- (void)stopVideoStream:(__unused id)videoStream {
    self.stopCount += 1;
}

@end

static void waitUntil(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    require(condition(), @"Timed out waiting for asynchronous receiver work");
}

static void testSyntheticCapabilityProbe(void) {
    NSError *error = nil;
    BOOL runtimeAvailable = [DHAVConferenceReceiver validateRuntimeContractWithError:&error];
    require(runtimeAvailable, error.localizedDescription ?: @"Runtime validation failed");
    require(error == nil, @"Successful runtime validation must clear the error");

    BOOL available = [DHAVConferenceReceiver runSyntheticCapabilityProbeWithError:&error];

    require(available, error.localizedDescription ?: @"Capability probe failed");
    require(error == nil, @"A successful capability probe must clear the error");
}

static void testStreamOptionsSelectInProcessTransport(void) {
    NSDictionary *generatedOptions = @{
        @"avcMediaStreamOptionRunInProcess" : @NO,
        @"generatedOnly" : @"preserved",
    };

    NSDictionary *streamOptions =
        DHAVConferenceMergedStreamOptions(generatedOptions);

    require(
        [streamOptions[@"avcMediaStreamOptionRunInProcess"] isEqual:@YES],
        @"The iOS receiver must keep AVConference transport in the app process"
    );
    require(
        [streamOptions[@"generatedOnly"] isEqual:@"preserved"],
        @"The receiver must preserve AVConference's generated stream options"
    );
    require(
        [streamOptions[@"AVCMediaStreamNegotiatorTransportProtocolType"] isEqual:@2]
            && [streamOptions[@"AVCMediaStreamNegotiatorAccessNetworkType"] isEqual:@1],
        @"The receiver must still provide the CoreDevice transport options"
    );
}

static void testReceiverCreatesMode5Offer(void) {
    DHAVConferenceReceiver *receiver = makeReceiver();
    require(receiver.state == DHAVConferenceReceiverStateIdle, @"A new receiver must be idle");

    NSError *error = nil;
    NSData *offer = [receiver makeNegotiatorOfferWithError:&error];
    require(offer.length > 0, error.localizedDescription ?: @"Offer creation failed");
    require(error == nil, @"Successful offer creation must clear the error");
    require(
        receiver.state == DHAVConferenceReceiverStateOfferCreated,
        @"Offer creation must advance the receiver state"
    );

    NSDictionary *propertyList = [NSPropertyListSerialization
        propertyListWithData:offer
                     options:NSPropertyListImmutable
                      format:nil
                       error:&error];
    require(
        [propertyList[@"avcMediaStreamNegotiatorMode"] integerValue] == 5,
        @"The receiver must create a CoreDevice screen-sharing offer"
    );
    require(
        [propertyList[@"avcMediaStreamOptionCallID"] isKindOfClass:NSString.class]
            && [propertyList[@"avcMediaStreamOptionCallID"] length] > 0,
        @"AVConference must assign the video negotiator its own call identifier"
    );

    NSError *secondOfferError = nil;
    NSData *secondOffer = [receiver makeNegotiatorOfferWithError:&secondOfferError];
    require(secondOffer == nil, @"A receiver must never create a second negotiator offer");
    require(
        [secondOfferError.domain isEqualToString:DHAVConferenceErrorDomain]
            && secondOfferError.code == DHAVConferenceErrorInvalidState,
        @"A second offer must fail with the stable invalid-state error"
    );
    [receiver invalidate];
}

static void requireMethodEncoding(SEL selector, const char *expectedEncoding) {
    Method method = class_getInstanceMethod(DHAVConferenceReceiver.class, selector);
    require(method != nullptr, [NSString stringWithFormat:@"Missing %@", NSStringFromSelector(selector)]);
    require(
        strcmp(method_getTypeEncoding(method), expectedEncoding) == 0,
        [NSString stringWithFormat:@"Unexpected ABI for %@", NSStringFromSelector(selector)]
    );
}

static void testDelegateMethodEncodings(void) {
    requireMethodEncoding(sel_registerName("stream:didStart:error:"), "v36@0:8@16B24@28");
    requireMethodEncoding(sel_registerName("streamDidRTPTimeOut:"), "v24@0:8@16");
    requireMethodEncoding(sel_registerName("streamDidRTCPTimeOut:"), "v24@0:8@16");
    requireMethodEncoding(
        sel_registerName("streamDidRecoverFromRTCPTimeOut:"),
        "v24@0:8@16"
    );
}

static void testReceiverConfiguresWithNegotiatedAnswer(void) {
    DHAVConferenceReceiver *receiver = makeReceiver();
    NSError *error = nil;
    NSData *offer = [receiver makeNegotiatorOfferWithError:&error];
    NSData *answer = DHCreateSyntheticNegotiatorAnswer(offer, &error);
    require(answer.length > 0, error.localizedDescription ?: @"Answer creation failed");

    BOOL configured = [receiver configureWithNegotiatorAnswer:answer error:&error];
    require(configured, error.localizedDescription ?: @"Receiver configuration failed");
    require(error == nil, @"Successful configuration must clear the error");
    require(
        receiver.state == DHAVConferenceReceiverStateConfigured,
        @"Applying an answer must configure the receiver without starting it"
    );
    [receiver invalidate];
}

static void testDatagramIngressHonorsReceiverLifecycle(void) {
    DHAVConferenceReceiver *receiver = makeReceiver();
    NSError *error = nil;
    BOOL accepted = [receiver ingestInboundDatagram:[NSData dataWithBytes:"rtp" length:3]
                                             error:&error];
    require(!accepted, @"An idle receiver must reject tunnel datagrams");
    require(
        error.code == DHAVConferenceErrorInvalidState,
        @"Pre-configuration ingress must return a typed state error"
    );

    NSData *offer = [receiver makeNegotiatorOfferWithError:&error];
    NSData *answer = DHCreateSyntheticNegotiatorAnswer(offer, &error);
    require(
        [receiver configureWithNegotiatorAnswer:answer error:&error],
        error.localizedDescription ?: @"Receiver configuration failed"
    );

    accepted = [receiver ingestInboundDatagram:[NSData dataWithBytes:"rtp" length:3]
                                         error:&error];
    require(accepted, error.localizedDescription ?: @"Configured receiver rejected a datagram");
    require(error == nil, @"Successful datagram ingress must clear the error");

    accepted = [receiver ingestInboundDatagram:NSData.data error:&error];
    require(!accepted, @"The transport must reject an empty UDP datagram");
    require(
        error.code == DHAVConferenceErrorDatagramRejected,
        @"Invalid UDP payloads must return a typed datagram error"
    );

    [receiver invalidate];
    accepted = [receiver ingestInboundDatagram:[NSData dataWithBytes:"rtp" length:3]
                                         error:&error];
    require(!accepted, @"An invalidated receiver must reject tunnel datagrams");
    require(
        error.code == DHAVConferenceErrorInvalidState,
        @"Post-invalidation ingress must return a typed state error"
    );
}

static void testStartUsesAppOwnedDecoderAndInvalidationTearsDownExactlyOnce(void) {
    RecordingRuntimeOperations *operations = [[RecordingRuntimeOperations alloc] init];
    dispatch_queue_t callbackQueue = dispatch_queue_create(
        "DeviceHub.PrivateMediaTests",
        DISPATCH_QUEUE_SERIAL
    );
    DHAVConferenceReceiver *receiver = [[DHAVConferenceReceiver alloc]
              initWithCallbackQueue:callbackQueue
         outboundDatagramHandler:^(__unused NSData *datagram) {
         }
                    eventHandler:nil
               runtimeOperations:operations];

    NSError *error = nil;
    NSData *offer = [receiver makeNegotiatorOfferWithError:&error];
    NSData *answer = DHCreateSyntheticNegotiatorAnswer(offer, &error);
    require(
        [receiver configureWithNegotiatorAnswer:answer error:&error],
        error.localizedDescription ?: @"Receiver configuration failed"
    );
    require(
        [receiver startWithError:&error],
        error.localizedDescription ?: @"Receiver start failed"
    );
    require(
        receiver.state == DHAVConferenceReceiverStateStarting,
        @"Start must wait for AVConference's delegate confirmation"
    );
    require(operations.delegateSetCount == 1, @"Start must install the stream delegate");
    require(operations.startCount == 1, @"Start must activate AVConference exactly once");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        reinterpret_cast<void (*)(id, SEL, id, BOOL, id)>(objc_msgSend)(
            receiver,
            sel_registerName("stream:didStart:error:"),
            nil,
            YES,
            nil
        );
    });
    waitUntil(^BOOL {
        return receiver.state == DHAVConferenceReceiverStateStreaming;
    }, 2);
    require(
        receiver.state == DHAVConferenceReceiverStateStreaming,
        @"A successful start callback must advance the receiver to streaming"
    );
    [receiver invalidate];
    [receiver invalidate];
    require(
        receiver.state == DHAVConferenceReceiverStateInvalidated,
        @"Invalidation must be terminal"
    );
    require(operations.stopCount == 1, @"Teardown must stop the stream once");
    require(operations.delegateClearCount == 1, @"Teardown must clear the stream delegate once");
}

static void testInvalidationSuppressesLateStartCallback(void) {
    RecordingRuntimeOperations *operations = [[RecordingRuntimeOperations alloc] init];
    DHAVConferenceReceiver *receiver = [[DHAVConferenceReceiver alloc]
              initWithCallbackQueue:dispatch_get_main_queue()
         outboundDatagramHandler:^(__unused NSData *datagram) {
         }
                    eventHandler:nil
               runtimeOperations:operations];
    NSError *error = nil;
    NSData *offer = [receiver makeNegotiatorOfferWithError:&error];
    NSData *answer = DHCreateSyntheticNegotiatorAnswer(offer, &error);
    require([receiver configureWithNegotiatorAnswer:answer error:&error], @"Configure failed");
    require([receiver startWithError:&error], @"Start failed");

    dispatch_semaphore_t releaseCallback = dispatch_semaphore_create(0);
    dispatch_semaphore_t callbackFinished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_wait(releaseCallback, DISPATCH_TIME_FOREVER);
        reinterpret_cast<void (*)(id, SEL, id, BOOL, id)>(objc_msgSend)(
            receiver,
            sel_registerName("stream:didStart:error:"),
            nil,
            YES,
            nil
        );
        dispatch_semaphore_signal(callbackFinished);
    });

    [receiver invalidate];
    dispatch_semaphore_signal(releaseCallback);
    __block BOOL callbackObserved = NO;
    waitUntil(^BOOL {
        if (!callbackObserved) {
            callbackObserved =
                dispatch_semaphore_wait(callbackFinished, DISPATCH_TIME_NOW) == 0;
        }
        return callbackObserved;
    }, 2);
    require(
        receiver.state == DHAVConferenceReceiverStateInvalidated,
        @"Invalidation must remain terminal after a late start callback"
    );
}

static void testBackgroundInvalidationNeverWaitsForMainQueue(void) {
    RecordingRuntimeOperations *operations = [[RecordingRuntimeOperations alloc] init];
    DHAVConferenceReceiver *receiver = [[DHAVConferenceReceiver alloc]
              initWithCallbackQueue:dispatch_get_main_queue()
         outboundDatagramHandler:^(__unused NSData *datagram) {
         }
                    eventHandler:nil
               runtimeOperations:operations];
    NSError *error = nil;
    NSData *offer = [receiver makeNegotiatorOfferWithError:&error];
    NSData *answer = DHCreateSyntheticNegotiatorAnswer(offer, &error);
    require([receiver configureWithNegotiatorAnswer:answer error:&error], @"Configure failed");
    require([receiver startWithError:&error], @"Start failed");

    dispatch_semaphore_t invalidationFinished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [receiver invalidate];
        dispatch_semaphore_signal(invalidationFinished);
    });

    require(
        dispatch_semaphore_wait(
            invalidationFinished,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)
        ) == 0,
        @"Background invalidation must not synchronously wait for the main queue"
    );
}

static void testTransportDelegateEventsAndLateCallbackSuppression(void) {
    RecordingRuntimeOperations *operations = [[RecordingRuntimeOperations alloc] init];
    dispatch_queue_t callbackQueue = dispatch_queue_create(
        "DeviceHub.PrivateMediaTests.DecodedEvents",
        DISPATCH_QUEUE_SERIAL
    );
    NSLock *callbackLock = [[NSLock alloc] init];
    NSMutableArray<NSNumber *> *events = [[NSMutableArray alloc] init];
    DHAVConferenceReceiver *receiver = [[DHAVConferenceReceiver alloc]
              initWithCallbackQueue:callbackQueue
         outboundDatagramHandler:^(__unused NSData *datagram) {
         }
                    eventHandler:^(DHAVConferenceReceiverEvent event, __unused NSError *error) {
                        [callbackLock lock];
                        [events addObject:@(event)];
                        [callbackLock unlock];
                    }
               runtimeOperations:operations];

    NSError *error = nil;
    NSData *offer = [receiver makeNegotiatorOfferWithError:&error];
    NSData *answer = DHCreateSyntheticNegotiatorAnswer(offer, &error);
    require([receiver configureWithNegotiatorAnswer:answer error:&error], @"Configure failed");
    require([receiver startWithError:&error], @"Start failed");
    reinterpret_cast<void (*)(id, SEL, id, BOOL, id)>(objc_msgSend)(
        receiver,
        sel_registerName("stream:didStart:error:"),
        nil,
        YES,
        nil
    );
    waitUntil(^BOOL {
        return receiver.state == DHAVConferenceReceiverStateStreaming;
    }, 2);

    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(
        receiver,
        sel_registerName("streamDidRTPTimeOut:"),
        nil
    );
    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(
        receiver,
        sel_registerName("streamDidRTCPTimeOut:"),
        nil
    );
    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(
        receiver,
        sel_registerName("streamDidRecoverFromRTCPTimeOut:"),
        nil
    );

    dispatch_sync(callbackQueue, ^{
    });
    [callbackLock lock];
    NSArray<NSNumber *> *expectedEvents = @[
        @(DHAVConferenceReceiverEventDidStart),
        @(DHAVConferenceReceiverEventDidReceiveRTPTimeout),
        @(DHAVConferenceReceiverEventDidReceiveRTCPTimeout),
        @(DHAVConferenceReceiverEventDidRecoverFromRTCPTimeout),
    ];
    require(
        [events isEqualToArray:expectedEvents],
        @"Transport health events must preserve their callback order"
    );
    [callbackLock unlock];

    [receiver invalidate];
    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(
        receiver,
        sel_registerName("streamDidRTPTimeOut:"),
        nil
    );
    dispatch_sync(callbackQueue, ^{
    });
    [callbackLock lock];
    require(
        [events isEqualToArray:expectedEvents],
        @"Invalidation must suppress late transport events"
    );
    [callbackLock unlock];
}

int main(void) {
    @autoreleasepool {
        testStreamOptionsSelectInProcessTransport();
        testSyntheticCapabilityProbe();
        testReceiverCreatesMode5Offer();
        testDelegateMethodEncodings();
        testReceiverConfiguresWithNegotiatedAnswer();
        testDatagramIngressHonorsReceiverLifecycle();
        testStartUsesAppOwnedDecoderAndInvalidationTearsDownExactlyOnce();
        testInvalidationSuppressesLateStartCallback();
        testBackgroundInvalidationNeverWaitsForMainQueue();
        testTransportDelegateEventsAndLateCallbackSuppression();
        NSLog(@"PASS: AVConference receiver lifecycle");
    }
    return 0;
}

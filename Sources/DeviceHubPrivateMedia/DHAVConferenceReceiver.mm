#import <DeviceHubPrivateMedia/DHAVConferenceReceiver.h>

#import "Internal/DHAVConferenceReceiver+Internal.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <xpc/xpc.h>

#import <arpa/inet.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <stdio.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <unistd.h>

#include <iterator>

NSErrorDomain const DHAVConferenceErrorDomain = @"DeviceHub.AVConference";
NSString *const DHAVConferenceErrorOperationKey = @"operation";
NSString *const DHAVConferenceErrorRuntimeClassKey = @"runtimeClass";
NSString *const DHAVConferenceErrorRuntimeSelectorKey = @"runtimeSelector";
NSString *const DHAVConferenceErrorUnderlyingDomainKey = @"underlyingDomain";
NSString *const DHAVConferenceErrorUnderlyingCodeKey = @"underlyingCode";

namespace {

constexpr char kAVConferencePath[] =
    "/System/Library/PrivateFrameworks/AVConference.framework/AVConference";
constexpr char kSharedSocketKey[] = "avcKeySharedSocket";
constexpr NSUInteger kMaximumUDPDatagramSize = 65'507;
NSString *const kRunInProcessKey = @"avcMediaStreamOptionRunInProcess";
NSString *const kTransportProtocolTypeKey = @"AVCMediaStreamNegotiatorTransportProtocolType";
NSString *const kAccessNetworkTypeKey = @"AVCMediaStreamNegotiatorAccessNetworkType";

NSError *MakeError(
    DHAVConferenceErrorCode code,
    NSString *operation,
    NSString *description,
    NSString *_Nullable runtimeClass = nil,
    NSString *_Nullable runtimeSelector = nil
) {
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey : description,
        DHAVConferenceErrorOperationKey : operation,
    } mutableCopy];
    if (runtimeClass != nil) {
        userInfo[DHAVConferenceErrorRuntimeClassKey] = runtimeClass;
    }
    if (runtimeSelector != nil) {
        userInfo[DHAVConferenceErrorRuntimeSelectorKey] = runtimeSelector;
    }
    return [NSError errorWithDomain:DHAVConferenceErrorDomain code:code userInfo:userInfo];
}

NSError *SanitizedRuntimeError(
    DHAVConferenceErrorCode code,
    NSString *operation,
    NSError *_Nullable runtimeError
) {
    NSString *description = runtimeError == nil
        ? @"AVConference rejected the operation."
        : [NSString stringWithFormat:
              @"AVConference rejected the operation (%@:%ld).",
              runtimeError.domain,
              (long)runtimeError.code];
    NSError *error = MakeError(code, operation, description);
    if (runtimeError == nil) {
        return error;
    }

    NSMutableDictionary *userInfo = [error.userInfo mutableCopy];
    userInfo[DHAVConferenceErrorUnderlyingDomainKey] = runtimeError.domain;
    userInfo[DHAVConferenceErrorUnderlyingCodeKey] = @(runtimeError.code);
    return [NSError errorWithDomain:error.domain code:error.code userInfo:userInfo];
}

void AssignError(NSError *_Nullable *_Nullable output, NSError *_Nullable error) {
    if (output != nullptr) {
        *output = error;
    }
}

struct MethodContract {
    const char *selector;
    const char *encoding;
};

BOOL ValidateMethods(
    Class runtimeClass,
    const MethodContract *contracts,
    size_t count,
    NSError *_Nullable *_Nullable error
) {
    NSString *className = NSStringFromClass(runtimeClass);
    for (size_t index = 0; index < count; ++index) {
        SEL selector = sel_registerName(contracts[index].selector);
        Method method = class_getInstanceMethod(runtimeClass, selector);
        if (method == nullptr) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorRuntimeContractMismatch,
                    @"validateRuntime",
                    @"An AVConference method required by the iOS 27 receiver is unavailable.",
                    className,
                    NSStringFromSelector(selector)
                )
            );
            return NO;
        }

        const char *actualEncoding = method_getTypeEncoding(method);
        if (actualEncoding == nullptr || strcmp(actualEncoding, contracts[index].encoding) != 0) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorRuntimeContractMismatch,
                    @"validateRuntime",
                    @"An AVConference method signature does not match the iOS 27 contract.",
                    className,
                    NSStringFromSelector(selector)
                )
            );
            return NO;
        }
    }
    return YES;
}

id SendObject(id receiver, const char *selector) {
    return reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
        receiver,
        sel_registerName(selector)
    );
}

BOOL SendBool(id receiver, const char *selector) {
    return reinterpret_cast<BOOL (*)(id, SEL)>(objc_msgSend)(
        receiver,
        sel_registerName(selector)
    );
}

id InitNegotiator(
    id receiver,
    NSInteger mode,
    NSDictionary *options,
    NSError **error
) {
    return reinterpret_cast<id (*)(id, SEL, NSInteger, id, NSError **)>(objc_msgSend)(
        receiver,
        sel_registerName("initWithMode:options:error:"),
        mode,
        options,
        error
    );
}

id InitNegotiatorWithOffer(
    id receiver,
    NSData *offer,
    NSDictionary *options,
    NSError **error
) {
    return reinterpret_cast<id (*)(id, SEL, id, id, NSError **)>(objc_msgSend)(
        receiver,
        sel_registerName("initWithOffer:options:error:"),
        offer,
        options,
        error
    );
}

BOOL SetNegotiatorAnswer(id receiver, NSData *answer, NSError **error) {
    return reinterpret_cast<BOOL (*)(id, SEL, id, NSError **)>(objc_msgSend)(
        receiver,
        sel_registerName("setAnswer:withError:"),
        answer,
        error
    );
}

id GenerateNegotiatorObject(id receiver, const char *selector, NSError **error) {
    return reinterpret_cast<id (*)(id, SEL, NSError **)>(objc_msgSend)(
        receiver,
        sel_registerName(selector),
        error
    );
}

id InitVideoStream(
    id receiver,
    id networkSockets,
    NSDictionary *options,
    NSError **error
) {
    return reinterpret_cast<id (*)(id, SEL, id, id, NSError **)>(objc_msgSend)(
        receiver,
        sel_registerName("initWithNetworkSockets:options:error:"),
        networkSockets,
        options,
        error
    );
}

BOOL ConfigureVideoStream(id receiver, id configuration, NSError **error) {
    return reinterpret_cast<BOOL (*)(id, SEL, id, NSError **)>(objc_msgSend)(
        receiver,
        sel_registerName("configure:error:"),
        configuration,
        error
    );
}

void SendVoid(id receiver, const char *selector) {
    reinterpret_cast<void (*)(id, SEL)>(objc_msgSend)(
        receiver,
        sel_registerName(selector)
    );
}

void SendVoidObject(id receiver, const char *selector, id _Nullable object) {
    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(
        receiver,
        sel_registerName(selector),
        object
    );
}

NSDictionary *NegotiatorOptions(void) {
    return @{
        kTransportProtocolTypeKey : @2,
        kAccessNetworkTypeKey : @1,
    };
}

BOOL CreateBoundLoopbackSocket(int *outputFileDescriptor, NSError **error) {
    int fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (fileDescriptor < 0) {
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorTransportSetupFailed,
                @"createSharedSocket",
                @"Could not create the local AVConference datagram socket."
            )
        );
        return NO;
    }

    sockaddr_in address = {};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(fileDescriptor, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
        close(fileDescriptor);
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorTransportSetupFailed,
                @"createSharedSocket",
                @"Could not bind the local AVConference datagram socket."
            )
        );
        return NO;
    }

    *outputFileDescriptor = fileDescriptor;
    return YES;
}

BOOL SetNonblocking(int fileDescriptor, NSError **error) {
    int flags = fcntl(fileDescriptor, F_GETFL);
    if (flags < 0 || fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorTransportSetupFailed,
                @"configureDatagramSocket",
                @"Could not configure the local AVConference datagram socket."
            )
        );
        return NO;
    }
    return YES;
}

BOOL BoundAddress(int fileDescriptor, sockaddr_in *outputAddress, NSError **error) {
    socklen_t addressLength = sizeof(*outputAddress);
    if (getsockname(
            fileDescriptor,
            reinterpret_cast<sockaddr *>(outputAddress),
            &addressLength
        )
        != 0) {
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorTransportSetupFailed,
                @"readDatagramSocketAddress",
                @"Could not inspect the local AVConference datagram socket."
            )
        );
        return NO;
    }
    return YES;
}

} // namespace

NSDictionary<NSString *, id> *
DHAVConferenceMergedStreamOptions(NSDictionary<NSString *, id> *generatedOptions) {
    NSMutableDictionary<NSString *, id> *streamOptions = [generatedOptions mutableCopy];
    [streamOptions addEntriesFromDictionary:NegotiatorOptions()];
    streamOptions[kRunInProcessKey] = @YES;
    return [streamOptions copy];
}

@interface DHAVConferenceRuntime : NSObject <DHAVConferenceRuntimeOperations>

@property(nonatomic, readonly) Class negotiatorClass;
@property(nonatomic, readonly) Class videoStreamClass;

+ (instancetype)sharedRuntime;
- (BOOL)validateWithError:(NSError **)error;

@end

@implementation DHAVConferenceRuntime {
    void *_frameworkHandle;
    Class _negotiatorClass;
    Class _videoStreamClass;
}

+ (instancetype)sharedRuntime {
    static DHAVConferenceRuntime *runtime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        runtime = [[self alloc] init];
    });
    return runtime;
}

- (BOOL)validateWithError:(NSError **)error {
    AssignError(error, nil);

    static dispatch_once_t onceToken;
    static BOOL validated;
    static NSError *validationError;
    dispatch_once(&onceToken, ^{
        self->_frameworkHandle = dlopen(kAVConferencePath, RTLD_NOW | RTLD_LOCAL);
        if (self->_frameworkHandle == nullptr) {
            validationError = MakeError(
                DHAVConferenceErrorFrameworkUnavailable,
                @"loadFramework",
                @"AVConference is unavailable on this operating system."
            );
            return;
        }

        self->_negotiatorClass = NSClassFromString(@"AVCMediaStreamNegotiator");
        self->_videoStreamClass = NSClassFromString(@"AVCVideoStream");
        NSArray<Class> *classes = @[
            self->_negotiatorClass ?: NSClassFromString(@"NSObject"),
            self->_videoStreamClass ?: NSClassFromString(@"NSObject"),
        ];
        NSArray<NSString *> *classNames = @[
            @"AVCMediaStreamNegotiator",
            @"AVCVideoStream",
        ];
        for (NSUInteger index = 0; index < classNames.count; ++index) {
            if (classes[index] == NSClassFromString(@"NSObject")) {
                validationError = MakeError(
                    DHAVConferenceErrorRuntimeContractMismatch,
                    @"validateRuntime",
                    @"An AVConference class required by the iOS 27 receiver is unavailable.",
                    classNames[index],
                    nil
                );
                return;
            }
        }

        constexpr MethodContract negotiatorMethods[] = {
            {"initWithMode:options:error:", "@40@0:8q16@24^@32"},
            {"initWithOffer:options:error:", "@40@0:8@16@24^@32"},
            {"createOffer", "B16@0:8"},
            {"offer", "@16@0:8"},
            {"createAnswer", "B16@0:8"},
            {"answer", "@16@0:8"},
            {"setAnswer:withError:", "B32@0:8@16^@24"},
            {"generateMediaStreamConfigurationWithError:", "@24@0:8^@16"},
            {"generateMediaStreamInitOptionsWithError:", "@24@0:8^@16"},
        };
        NSError *methodError = nil;
        if (!ValidateMethods(
                self->_negotiatorClass,
                negotiatorMethods,
                std::size(negotiatorMethods),
                &methodError
            )) {
            validationError = methodError;
            return;
        }

        constexpr MethodContract videoStreamMethods[] = {
            {"initWithNetworkSockets:options:error:", "@40@0:8@16@24^@32"},
            {"configure:error:", "B32@0:8@16^@24"},
            {"setDelegate:", "v24@0:8@16"},
            {"start", "v16@0:8"},
            {"stop", "v16@0:8"},
        };
        if (!ValidateMethods(
                self->_videoStreamClass,
                videoStreamMethods,
                std::size(videoStreamMethods),
                &methodError
            )) {
            validationError = methodError;
            return;
        }

        validated = YES;
    });

    if (!validated) {
        AssignError(error, validationError);
    }
    return validated;
}

- (Class)negotiatorClass {
    return _negotiatorClass;
}

- (Class)videoStreamClass {
    return _videoStreamClass;
}

- (void)setDelegate:(id)delegate forVideoStream:(id)videoStream {
    SendVoidObject(videoStream, "setDelegate:", delegate);
}

- (void)startVideoStream:(id)videoStream {
    SendVoid(videoStream, "start");
}

- (void)stopVideoStream:(id)videoStream {
    SendVoid(videoStream, "stop");
}

@end

/// Owns the real loopback socket boundary between AVConference and the
/// caller-supplied CoreDevice tunnel datagram callbacks.
@interface DHAVConferenceDatagramBridge : NSObject

@property(nonatomic, strong, readonly) id networkSockets;

- (instancetype)initWithCallbackQueue:(dispatch_queue_t)callbackQueue
              outboundDatagramHandler:(DHAVConferenceOutboundDatagramHandler)handler
                                 error:(NSError **)error;
- (BOOL)ingestDatagram:(NSData *)datagram error:(NSError **)error;
- (void)invalidate;
- (void)drainOutboundDatagrams;

@end

@implementation DHAVConferenceDatagramBridge {
    NSLock *_lock;
    dispatch_queue_t _callbackQueue;
    DHAVConferenceOutboundDatagramHandler _outboundDatagramHandler;
    dispatch_source_t _readSource;
    int _relayFileDescriptor;
    id _networkSockets;
    BOOL _invalidated;
}

- (instancetype)initWithCallbackQueue:(dispatch_queue_t)callbackQueue
              outboundDatagramHandler:(DHAVConferenceOutboundDatagramHandler)handler
                                 error:(NSError **)error {
    AssignError(error, nil);
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _lock = [[NSLock alloc] init];
    _callbackQueue = callbackQueue;
    _outboundDatagramHandler = [handler copy];
    _relayFileDescriptor = -1;

    int avConferenceFileDescriptor = -1;
    int relayFileDescriptor = -1;
    if (!CreateBoundLoopbackSocket(&avConferenceFileDescriptor, error)) {
        return nil;
    }
    if (!CreateBoundLoopbackSocket(&relayFileDescriptor, error)) {
        close(avConferenceFileDescriptor);
        return nil;
    }

    sockaddr_in avConferenceAddress = {};
    sockaddr_in relayAddress = {};
    if (!BoundAddress(avConferenceFileDescriptor, &avConferenceAddress, error)
        || !BoundAddress(relayFileDescriptor, &relayAddress, error)
        || !SetNonblocking(avConferenceFileDescriptor, error)
        || !SetNonblocking(relayFileDescriptor, error)) {
        close(avConferenceFileDescriptor);
        close(relayFileDescriptor);
        return nil;
    }

    if (connect(
            avConferenceFileDescriptor,
            reinterpret_cast<const sockaddr *>(&relayAddress),
            sizeof(relayAddress)
        )
            != 0
        || connect(
               relayFileDescriptor,
               reinterpret_cast<const sockaddr *>(&avConferenceAddress),
               sizeof(avConferenceAddress)
           )
            != 0) {
        close(avConferenceFileDescriptor);
        close(relayFileDescriptor);
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorTransportSetupFailed,
                @"connectDatagramSockets",
                @"Could not connect the local AVConference datagram sockets."
            )
        );
        return nil;
    }

    xpc_object_t networkSockets = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_fd(networkSockets, kSharedSocketKey, avConferenceFileDescriptor);
    close(avConferenceFileDescriptor);
    _networkSockets = networkSockets;
    _relayFileDescriptor = relayFileDescriptor;

    _readSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ,
        static_cast<uintptr_t>(relayFileDescriptor),
        0,
        callbackQueue
    );
    if (_readSource == nil) {
        close(relayFileDescriptor);
        _relayFileDescriptor = -1;
        _networkSockets = nil;
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorTransportSetupFailed,
                @"monitorOutboundDatagrams",
                @"Could not monitor AVConference's outbound datagrams."
            )
        );
        return nil;
    }

    __weak DHAVConferenceDatagramBridge *weakSelf = self;
    dispatch_source_set_event_handler(_readSource, ^{
        [weakSelf drainOutboundDatagrams];
    });
    dispatch_source_set_cancel_handler(_readSource, ^{
        close(relayFileDescriptor);
    });
    dispatch_resume(_readSource);
    return self;
}

- (id)networkSockets {
    return _networkSockets;
}

- (BOOL)ingestDatagram:(NSData *)datagram error:(NSError **)error {
    AssignError(error, nil);
    if (datagram.length == 0 || datagram.length > kMaximumUDPDatagramSize) {
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorDatagramRejected,
                @"ingestInboundDatagram",
                @"The CoreDevice tunnel produced an invalid UDP datagram."
            )
        );
        return NO;
    }

    [_lock lock];
    if (_invalidated || _relayFileDescriptor < 0) {
        [_lock unlock];
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorInvalidState,
                @"ingestInboundDatagram",
                @"The AVConference datagram transport is no longer active."
            )
        );
        return NO;
    }

    ssize_t sent = send(
        _relayFileDescriptor,
        datagram.bytes,
        datagram.length,
        MSG_DONTWAIT
    );
    int sendError = errno;
    [_lock unlock];
    if (sent != static_cast<ssize_t>(datagram.length)) {
        NSString *description = sendError == EAGAIN || sendError == ENOBUFS
            ? @"The AVConference datagram transport is temporarily full."
            : @"The AVConference datagram transport rejected an inbound datagram.";
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorDatagramRejected,
                @"ingestInboundDatagram",
                description
            )
        );
        return NO;
    }
    return YES;
}

- (void)drainOutboundDatagrams {
    while (YES) {
        [_lock lock];
        BOOL invalidated = _invalidated;
        int fileDescriptor = _relayFileDescriptor;
        DHAVConferenceOutboundDatagramHandler handler = _outboundDatagramHandler;
        [_lock unlock];
        if (invalidated || fileDescriptor < 0 || handler == nil) {
            return;
        }

        uint8_t bytes[kMaximumUDPDatagramSize];
        ssize_t received = recv(fileDescriptor, bytes, sizeof(bytes), MSG_DONTWAIT);
        if (received > 0) {
            handler([NSData dataWithBytes:bytes length:static_cast<NSUInteger>(received)]);
            continue;
        }
        if (received < 0 && errno == EINTR) {
            continue;
        }
        return;
    }
}

- (void)invalidate {
    [_lock lock];
    if (_invalidated) {
        [_lock unlock];
        return;
    }
    _invalidated = YES;
    _outboundDatagramHandler = nil;
    _relayFileDescriptor = -1;
    dispatch_source_t source = _readSource;
    _readSource = nil;
    _networkSockets = nil;
    [_lock unlock];

    if (source != nil) {
        dispatch_source_cancel(source);
    }
}

- (void)dealloc {
    [self invalidate];
}

@end

@class AVCVideoStream;

@interface DHAVConferenceReceiver ()

@property(nonatomic, strong) NSRecursiveLock *stateLock;
@property(nonatomic) DHAVConferenceReceiverState mutableState;
@property(nonatomic, strong) dispatch_queue_t callbackQueue;
@property(nonatomic, copy, nullable)
    DHAVConferenceOutboundDatagramHandler outboundDatagramHandler;
@property(nonatomic, copy, nullable) DHAVConferenceEventHandler eventHandler;
@property(nonatomic, strong, nullable) id negotiator;
@property(nonatomic, strong, nullable) id videoStream;
@property(nonatomic, strong, nullable) DHAVConferenceDatagramBridge *datagramBridge;
@property(nonatomic, strong) id<DHAVConferenceRuntimeOperations> runtimeOperations;
@property(nonatomic) BOOL delegateInstalled;
@property(nonatomic) BOOL startInvoked;

- (void)emitEvent:(DHAVConferenceReceiverEvent)event error:(NSError *_Nullable)error;
- (void)tearDownMediaResources;

@end

@implementation DHAVConferenceReceiver

+ (BOOL)validateRuntimeContractWithError:(NSError **)error {
    AssignError(error, nil);
    return [[DHAVConferenceRuntime sharedRuntime] validateWithError:error];
}

+ (BOOL)runSyntheticCapabilityProbeWithError:(NSError **)error {
    AssignError(error, nil);
    DHAVConferenceRuntime *runtime = [DHAVConferenceRuntime sharedRuntime];
    if (![runtime validateWithError:error]) {
        return NO;
    }

    @try {
        NSDictionary *negotiatorOptions = NegotiatorOptions();
        NSError *runtimeError = nil;
        id offerer = InitNegotiator(
            SendObject(runtime.negotiatorClass, "alloc"),
            5,
            negotiatorOptions,
            &runtimeError
        );
        if (offerer == nil) {
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"createSyntheticOfferer",
                    runtimeError
                )
            );
            return NO;
        }
        if (!SendBool(offerer, "createOffer")) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"createSyntheticOffer",
                    @"AVConference could not create a synthetic screen-sharing offer."
                )
            );
            return NO;
        }
        NSData *offer = SendObject(offerer, "offer");
        if (![offer isKindOfClass:NSData.class] || offer.length == 0) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorRuntimeContractMismatch,
                    @"createSyntheticOffer",
                    @"AVConference returned an invalid synthetic offer."
                )
            );
            return NO;
        }

        runtimeError = nil;
        id answerer = InitNegotiatorWithOffer(
            SendObject(runtime.negotiatorClass, "alloc"),
            offer,
            negotiatorOptions,
            &runtimeError
        );
        if (answerer == nil || !SendBool(answerer, "createAnswer")) {
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"createSyntheticAnswer",
                    runtimeError
                )
            );
            return NO;
        }
        NSData *answer = SendObject(answerer, "answer");
        if (![answer isKindOfClass:NSData.class] || answer.length == 0) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorRuntimeContractMismatch,
                    @"createSyntheticAnswer",
                    @"AVConference returned an invalid synthetic answer."
                )
            );
            return NO;
        }

        runtimeError = nil;
        if (!SetNegotiatorAnswer(offerer, answer, &runtimeError)) {
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"applySyntheticAnswer",
                    runtimeError
                )
            );
            return NO;
        }

        runtimeError = nil;
        id configuration = GenerateNegotiatorObject(
            offerer,
            "generateMediaStreamConfigurationWithError:",
            &runtimeError
        );
        if (configuration == nil) {
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"generateSyntheticConfiguration",
                    runtimeError
                )
            );
            return NO;
        }
        NSDictionary *generatedOptions = GenerateNegotiatorObject(
            offerer,
            "generateMediaStreamInitOptionsWithError:",
            &runtimeError
        );
        if (![generatedOptions isKindOfClass:NSDictionary.class]) {
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"generateSyntheticOptions",
                    runtimeError
                )
            );
            return NO;
        }

        NSDictionary *streamOptions =
            DHAVConferenceMergedStreamOptions(generatedOptions);

        int fileDescriptor = -1;
        if (!CreateBoundLoopbackSocket(&fileDescriptor, error)) {
            return NO;
        }
        xpc_object_t networkSockets = xpc_dictionary_create(nullptr, nullptr, 0);
        xpc_dictionary_set_fd(networkSockets, kSharedSocketKey, fileDescriptor);
        close(fileDescriptor);

        id allocatedStream = SendObject(runtime.videoStreamClass, "alloc");
        runtimeError = nil;
        id stream = InitVideoStream(allocatedStream, networkSockets, streamOptions, &runtimeError);
        if (stream == nil) {
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorStreamSetupFailed,
                    @"createSyntheticStream",
                    runtimeError
                )
            );
            return NO;
        }

        runtimeError = nil;
        if (!ConfigureVideoStream(stream, configuration, &runtimeError)) {
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorStreamSetupFailed,
                    @"configureSyntheticStream",
                    runtimeError
                )
            );
            return NO;
        }
        return YES;
    } @catch (__unused NSException *exception) {
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorRuntimeException,
                @"runSyntheticCapabilityProbe",
                @"AVConference raised an exception while validating the receiver."
            )
        );
        return NO;
    }
}

- (instancetype)initWithCallbackQueue:(dispatch_queue_t)callbackQueue
           outboundDatagramHandler:(DHAVConferenceOutboundDatagramHandler)outboundDatagramHandler
                      eventHandler:(DHAVConferenceEventHandler)eventHandler {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _stateLock = [[NSRecursiveLock alloc] init];
    _mutableState = DHAVConferenceReceiverStateIdle;
    _callbackQueue = callbackQueue;
    _outboundDatagramHandler = [outboundDatagramHandler copy];
    _eventHandler = [eventHandler copy];
    _runtimeOperations = [DHAVConferenceRuntime sharedRuntime];
    return self;
}

- (instancetype)initWithCallbackQueue:(dispatch_queue_t)callbackQueue
           outboundDatagramHandler:(DHAVConferenceOutboundDatagramHandler)outboundDatagramHandler
                      eventHandler:(DHAVConferenceEventHandler)eventHandler
                 runtimeOperations:
                     (id<DHAVConferenceRuntimeOperations>)runtimeOperations {
    self = [self initWithCallbackQueue:callbackQueue
           outboundDatagramHandler:outboundDatagramHandler
                      eventHandler:eventHandler];
    if (self != nil) {
        _runtimeOperations = runtimeOperations;
    }
    return self;
}

- (DHAVConferenceReceiverState)state {
    [self.stateLock lock];
    DHAVConferenceReceiverState state = self.mutableState;
    [self.stateLock unlock];
    return state;
}

- (NSData *)makeNegotiatorOfferWithError:(NSError **)error {
    AssignError(error, nil);
    [self.stateLock lock];
    @try {
        if (self.mutableState != DHAVConferenceReceiverStateIdle) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorInvalidState,
                    @"makeNegotiatorOffer",
                    @"A receiver can create exactly one negotiator offer."
                )
            );
            return nil;
        }

        DHAVConferenceRuntime *runtime = [DHAVConferenceRuntime sharedRuntime];
        if (![runtime validateWithError:error]) {
            return nil;
        }

        NSError *runtimeError = nil;
        id negotiator = InitNegotiator(
            SendObject(runtime.negotiatorClass, "alloc"),
            5,
            NegotiatorOptions(),
            &runtimeError
        );
        if (negotiator == nil) {
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"createOfferer",
                    runtimeError
                )
            );
            return nil;
        }
        if (!SendBool(negotiator, "createOffer")) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"createOffer",
                    @"AVConference could not create the CoreDevice screen-sharing offer."
                )
            );
            return nil;
        }

        NSData *offer = SendObject(negotiator, "offer");
        if (![offer isKindOfClass:NSData.class] || offer.length == 0) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorRuntimeContractMismatch,
                    @"createOffer",
                    @"AVConference returned an invalid CoreDevice screen-sharing offer."
                )
            );
            return nil;
        }

        self.negotiator = negotiator;
        self.mutableState = DHAVConferenceReceiverStateOfferCreated;
        return [offer copy];
    } @catch (__unused NSException *exception) {
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorRuntimeException,
                @"makeNegotiatorOffer",
                @"AVConference raised an exception while creating the offer."
            )
        );
        return nil;
    } @finally {
        [self.stateLock unlock];
    }
}

- (BOOL)configureWithNegotiatorAnswer:(NSData *)answer error:(NSError **)error {
    AssignError(error, nil);
    [self.stateLock lock];
    @try {
        if (self.mutableState != DHAVConferenceReceiverStateOfferCreated
            || self.negotiator == nil) {
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorInvalidState,
                    @"configureWithNegotiatorAnswer",
                    @"The receiver must create its offer before applying an answer."
                )
            );
            return NO;
        }
        if (answer.length == 0) {
            self.mutableState = DHAVConferenceReceiverStateFailed;
            AssignError(
                error,
                MakeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"configureWithNegotiatorAnswer",
                    @"The displayservice returned an empty negotiator answer."
                )
            );
            return NO;
        }

        NSError *runtimeError = nil;
        if (!SetNegotiatorAnswer(self.negotiator, answer, &runtimeError)) {
            self.mutableState = DHAVConferenceReceiverStateFailed;
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"applyNegotiatorAnswer",
                    runtimeError
                )
            );
            return NO;
        }

        runtimeError = nil;
        id configuration = GenerateNegotiatorObject(
            self.negotiator,
            "generateMediaStreamConfigurationWithError:",
            &runtimeError
        );
        if (configuration == nil) {
            self.mutableState = DHAVConferenceReceiverStateFailed;
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"generateStreamConfiguration",
                    runtimeError
                )
            );
            return NO;
        }

        runtimeError = nil;
        NSDictionary *generatedOptions = GenerateNegotiatorObject(
            self.negotiator,
            "generateMediaStreamInitOptionsWithError:",
            &runtimeError
        );
        if (![generatedOptions isKindOfClass:NSDictionary.class]) {
            self.mutableState = DHAVConferenceReceiverStateFailed;
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorNegotiationFailed,
                    @"generateStreamOptions",
                    runtimeError
                )
            );
            return NO;
        }

        DHAVConferenceDatagramBridge *bridge = [[DHAVConferenceDatagramBridge alloc]
                  initWithCallbackQueue:self.callbackQueue
            outboundDatagramHandler:self.outboundDatagramHandler
                               error:error];
        if (bridge == nil) {
            self.mutableState = DHAVConferenceReceiverStateFailed;
            return NO;
        }

        NSDictionary *streamOptions =
            DHAVConferenceMergedStreamOptions(generatedOptions);

        DHAVConferenceRuntime *runtime = [DHAVConferenceRuntime sharedRuntime];
        id allocatedStream = SendObject(runtime.videoStreamClass, "alloc");
        runtimeError = nil;
        id stream = InitVideoStream(
            allocatedStream,
            bridge.networkSockets,
            streamOptions,
            &runtimeError
        );
        if (stream == nil) {
            [bridge invalidate];
            self.mutableState = DHAVConferenceReceiverStateFailed;
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorStreamSetupFailed,
                    @"createVideoStream",
                    runtimeError
                )
            );
            return NO;
        }

        runtimeError = nil;
        if (!ConfigureVideoStream(stream, configuration, &runtimeError)) {
            [bridge invalidate];
            self.mutableState = DHAVConferenceReceiverStateFailed;
            AssignError(
                error,
                SanitizedRuntimeError(
                    DHAVConferenceErrorStreamSetupFailed,
                    @"configureVideoStream",
                    runtimeError
                )
            );
            return NO;
        }

        self.datagramBridge = bridge;
        self.videoStream = stream;
        self.mutableState = DHAVConferenceReceiverStateConfigured;
        return YES;
    } @catch (__unused NSException *exception) {
        self.mutableState = DHAVConferenceReceiverStateFailed;
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorRuntimeException,
                @"configureWithNegotiatorAnswer",
                @"AVConference raised an exception while configuring the stream."
            )
        );
        return NO;
    } @finally {
        [self.stateLock unlock];
    }
}

- (BOOL)startWithError:(NSError **)error {
    AssignError(error, nil);
    [self.stateLock lock];
    if (self.mutableState != DHAVConferenceReceiverStateConfigured
        || self.videoStream == nil) {
        [self.stateLock unlock];
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorInvalidState,
                @"start",
                @"The receiver must be configured before it can start."
            )
        );
        return NO;
    }

    @try {
        [self.runtimeOperations setDelegate:self forVideoStream:self.videoStream];
        self.delegateInstalled = YES;
        self.mutableState = DHAVConferenceReceiverStateStarting;
        self.startInvoked = YES;
        [self.runtimeOperations startVideoStream:self.videoStream];
        [self.stateLock unlock];
        return YES;
    } @catch (__unused NSException *exception) {
        self.mutableState = DHAVConferenceReceiverStateFailed;
        [self.stateLock unlock];
        [self tearDownMediaResources];
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorRuntimeException,
                @"start",
                @"AVConference raised an exception while starting the stream."
            )
        );
        return NO;
    }
}

- (void)stream:(__unused AVCVideoStream *)stream
      didStart:(BOOL)didStart
         error:(NSError *)runtimeError {
    [self.stateLock lock];
    if (self.mutableState != DHAVConferenceReceiverStateStarting) {
        [self.stateLock unlock];
        return;
    }
    if (!didStart || runtimeError != nil) {
        self.mutableState = DHAVConferenceReceiverStateFailed;
        [self.stateLock unlock];
        NSError *eventError = SanitizedRuntimeError(
            DHAVConferenceErrorStreamFailed,
            @"streamDidStart",
            runtimeError
        );
        [self tearDownMediaResources];
        [self emitEvent:DHAVConferenceReceiverEventDidFail error:eventError];
        return;
    }
    self.mutableState = DHAVConferenceReceiverStateStreaming;
    [self.stateLock unlock];
    [self emitEvent:DHAVConferenceReceiverEventDidStart error:nil];
}

- (void)streamDidStop:(__unused AVCVideoStream *)stream {
    [self.stateLock lock];
    if (self.mutableState == DHAVConferenceReceiverStateInvalidated) {
        [self.stateLock unlock];
        return;
    }
    self.mutableState = DHAVConferenceReceiverStateFailed;
    self.startInvoked = NO;
    [self.stateLock unlock];
    [self tearDownMediaResources];
    [self emitEvent:DHAVConferenceReceiverEventDidStop error:nil];
}

- (void)streamDidServerDie:(__unused AVCVideoStream *)stream {
    [self.stateLock lock];
    if (self.mutableState == DHAVConferenceReceiverStateInvalidated) {
        [self.stateLock unlock];
        return;
    }
    self.mutableState = DHAVConferenceReceiverStateFailed;
    self.startInvoked = NO;
    [self.stateLock unlock];
    [self tearDownMediaResources];
    [self emitEvent:
              DHAVConferenceReceiverEventDidFail
              error:MakeError(
                        DHAVConferenceErrorStreamFailed,
                        @"streamDidServerDie",
                        @"The AVConference video service stopped unexpectedly."
                    )];
}

- (void)streamDidRTPTimeOut:(__unused AVCVideoStream *)stream {
    [self.stateLock lock];
    BOOL active =
        self.mutableState == DHAVConferenceReceiverStateStarting
        || self.mutableState == DHAVConferenceReceiverStateStreaming;
    [self.stateLock unlock];
    if (active) {
        [self emitEvent:DHAVConferenceReceiverEventDidReceiveRTPTimeout error:nil];
    }
}

- (void)streamDidRTCPTimeOut:(__unused AVCVideoStream *)stream {
    [self.stateLock lock];
    BOOL active =
        self.mutableState == DHAVConferenceReceiverStateStarting
        || self.mutableState == DHAVConferenceReceiverStateStreaming;
    [self.stateLock unlock];
    if (active) {
        [self emitEvent:DHAVConferenceReceiverEventDidReceiveRTCPTimeout error:nil];
    }
}

- (void)streamDidRecoverFromRTCPTimeOut:(__unused AVCVideoStream *)stream {
    [self.stateLock lock];
    BOOL active =
        self.mutableState == DHAVConferenceReceiverStateStarting
        || self.mutableState == DHAVConferenceReceiverStateStreaming;
    [self.stateLock unlock];
    if (active) {
        [self emitEvent:
                  DHAVConferenceReceiverEventDidRecoverFromRTCPTimeout
                  error:nil];
    }
}

- (void)emitEvent:(DHAVConferenceReceiverEvent)event error:(NSError *)error {
    dispatch_queue_t callbackQueue = self.callbackQueue;
    __weak DHAVConferenceReceiver *weakSelf = self;
    dispatch_async(callbackQueue, ^{
        DHAVConferenceReceiver *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf.stateLock lock];
        BOOL invalidated =
            strongSelf.mutableState == DHAVConferenceReceiverStateInvalidated;
        DHAVConferenceEventHandler handler = strongSelf.eventHandler;
        [strongSelf.stateLock unlock];
        if (!invalidated && handler != nil) {
            handler(event, error);
        }
    });
}

- (void)tearDownMediaResources {
    [self.stateLock lock];
    id videoStream = self.videoStream;
    DHAVConferenceDatagramBridge *datagramBridge = self.datagramBridge;
    BOOL delegateInstalled = self.delegateInstalled;
    BOOL startInvoked = self.startInvoked;

    self.videoStream = nil;
    self.datagramBridge = nil;
    self.delegateInstalled = NO;
    self.startInvoked = NO;
    [self.stateLock unlock];

    @try {
        if (videoStream != nil && delegateInstalled) {
            [self.runtimeOperations setDelegate:nil forVideoStream:videoStream];
        }
        if (videoStream != nil && startInvoked) {
            [self.runtimeOperations stopVideoStream:videoStream];
        }
    } @catch (__unused NSException *exception) {
        os_log_error(
            OS_LOG_DEFAULT,
            "AVConference teardown raised a runtime exception"
        );
    }
    [datagramBridge invalidate];
}

- (BOOL)ingestInboundDatagram:(NSData *)datagram error:(NSError **)error {
    AssignError(error, nil);
    [self.stateLock lock];
    DHAVConferenceReceiverState state = self.mutableState;
    BOOL acceptsDatagrams =
        state == DHAVConferenceReceiverStateConfigured
        || state == DHAVConferenceReceiverStateStarting
        || state == DHAVConferenceReceiverStateStreaming;
    if (!acceptsDatagrams || self.datagramBridge == nil) {
        [self.stateLock unlock];
        AssignError(
            error,
            MakeError(
                DHAVConferenceErrorInvalidState,
                @"ingestInboundDatagram",
                @"The receiver is not configured to accept tunnel datagrams."
            )
        );
        return NO;
    }

    BOOL ingested = [self.datagramBridge ingestDatagram:datagram error:error];
    [self.stateLock unlock];
    return ingested;
}

- (void)invalidate {
    [self.stateLock lock];
    if (self.mutableState == DHAVConferenceReceiverStateInvalidated) {
        [self.stateLock unlock];
        return;
    }
    self.mutableState = DHAVConferenceReceiverStateInvalidated;
    self.negotiator = nil;
    self.outboundDatagramHandler = nil;
    self.eventHandler = nil;
    [self.stateLock unlock];
    [self tearDownMediaResources];
}

- (void)dealloc {
    [self invalidate];
}

@end

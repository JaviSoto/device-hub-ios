#import <DeviceHubPrivateMedia/DHAVConferenceReceiver.h>

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#include <stdlib.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

static int RunPrivateMediaProbe(void) {
    @autoreleasepool {
        NSError *runtimeError = nil;
        BOOL runtimeContractReady =
            [DHAVConferenceReceiver validateRuntimeContractWithError:&runtimeError];

        NSError *negotiationError = nil;
        BOOL syntheticNegotiationReady =
            runtimeContractReady
            && [DHAVConferenceReceiver
                runSyntheticCapabilityProbeWithError:&negotiationError];

        BOOL expectedSimulatorNegotiationLimitation = NO;
#if TARGET_OS_SIMULATOR
        expectedSimulatorNegotiationLimitation =
            !syntheticNegotiationReady
            && [negotiationError.domain isEqualToString:DHAVConferenceErrorDomain]
            && negotiationError.code == DHAVConferenceErrorNegotiationFailed
            && [negotiationError.userInfo[DHAVConferenceErrorOperationKey]
                isEqualToString:@"createSyntheticOfferer"]
            && [negotiationError.userInfo[DHAVConferenceErrorUnderlyingDomainKey]
                isEqualToString:@"GKVoiceChatServiceErrorDomain"]
            && [negotiationError.userInfo[DHAVConferenceErrorUnderlyingCodeKey]
                integerValue] == 32032;
#endif

        BOOL passed =
            runtimeContractReady
            && (syntheticNegotiationReady
                || expectedSimulatorNegotiationLimitation);
        NSError *reportedError = runtimeError ?: negotiationError;
        NSDictionary *result = @{
            @"passed" : @(passed),
            @"runtimeContractReady" : @(runtimeContractReady),
            @"syntheticNegotiationReady" : @(syntheticNegotiationReady),
            @"expectedSimulatorNegotiationLimitation" :
                @(expectedSimulatorNegotiationLimitation),
            @"errorDomain" : reportedError.domain ?: @"",
            @"errorCode" : @(reportedError.code),
            @"errorDescription" : reportedError.localizedDescription ?: @"",
            @"operation" :
                reportedError.userInfo[DHAVConferenceErrorOperationKey] ?: @"",
            @"runtimeClass" :
                reportedError.userInfo[DHAVConferenceErrorRuntimeClassKey] ?: @"",
            @"runtimeSelector" :
                reportedError.userInfo[DHAVConferenceErrorRuntimeSelectorKey] ?: @"",
            @"underlyingDomain" :
                reportedError.userInfo[DHAVConferenceErrorUnderlyingDomainKey] ?: @"",
            @"underlyingCode" :
                reportedError.userInfo[DHAVConferenceErrorUnderlyingCodeKey] ?: @0,
        };
        NSString *resultPath =
            NSProcessInfo.processInfo.environment[
                @"DEVICE_HUB_PRIVATE_MEDIA_RESULT_PATH"
            ];
        if (resultPath.length == 0) {
            resultPath = [
                [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                stringByAppendingPathComponent:@"private-media-probe.plist"
            ];
        }
        BOOL wroteResult = [result writeToFile:resultPath atomically:YES];
        NSLog(
            @"DEVICE_HUB_PRIVATE_MEDIA_PROBE passed=%d runtime=%d "
             "negotiation=%d expectedSimulatorLimitation=%d wroteResult=%d error=%@",
            passed,
            runtimeContractReady,
            syntheticNegotiationReady,
            expectedSimulatorNegotiationLimitation,
            wroteResult,
            reportedError.localizedDescription ?: @"none"
        );
        return passed && wroteResult ? EXIT_SUCCESS : EXIT_FAILURE;
    }
}

#if TARGET_OS_IOS

@interface DHPrivateMediaProbeDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation DHPrivateMediaProbeDelegate
@end

@interface DHPrivateMediaProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>

@property(nonatomic, strong) UIWindow *window;

@end

@implementation DHPrivateMediaProbeSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(__unused UISceneSession *)session
                 options:(__unused UISceneConnectionOptions *)connectionOptions {
    NSAssert(
        [scene isKindOfClass:UIWindowScene.class],
        @"The private-media probe requires a window scene"
    );
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        exit(RunPrivateMediaProbe());
    });
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (getenv("DEVICE_HUB_PRIVATE_MEDIA_DIRECT") != nullptr) {
            return RunPrivateMediaProbe();
        }
        return UIApplicationMain(
            argc,
            argv,
            nil,
            NSStringFromClass(DHPrivateMediaProbeDelegate.class)
        );
    }
}

#else

int main(void) {
    return RunPrivateMediaProbe();
}

#endif

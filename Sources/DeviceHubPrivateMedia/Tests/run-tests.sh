#!/usr/bin/env bash

set -euo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
module_dir=$(cd "$tests_dir/.." && pwd)
repository_root=$(cd "$tests_dir/../../.." && pwd)
process_guard="$repository_root/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$process_guard"
devicehub_require_guard private-media-tests 900 "$0" "$@"

ROOT="$repository_root"
# shellcheck source=BuildSupport/simulator_guard.sh
source "$repository_root/BuildSupport/simulator_guard.sh"
devicehub_require_simulator device-hub-private-media-tests 900 "$0" "$@"

temp_root=${TMPDIR:-/tmp}
work_dir=$(mktemp -d "$temp_root/devicehub-private-media.XXXXXX")
simulator_udid=${DEVICE_HUB_SIMULATOR_UDID:?simulator lease did not provide a UDID}

cleanup() {
  local status=$?
  case "$work_dir" in
    "$temp_root"/devicehub-private-media.*)
      if ! rm -rf -- "$work_dir"; then
        status=1
      fi
      ;;
    *)
      printf 'Refusing to remove unexpected work directory: %s\n' "$work_dir" >&2
      status=1
      ;;
  esac
  if ! devicehub_cleanup_simulator; then
    status=125
  fi
  return "$status"
}
trap cleanup EXIT

if [[ $(uname -s) != Darwin ]]; then
  printf 'DeviceHubPrivateMedia tests require macOS and Xcode 27.\n' >&2
  exit 1
fi

iphoneos_version=$(xcrun --sdk iphoneos --show-sdk-version)
iphonesimulator_version=$(xcrun --sdk iphonesimulator --show-sdk-version)
if [[ ${iphoneos_version%%.*} != 27 || ${iphonesimulator_version%%.*} != 27 ]]; then
  printf 'Expected iOS 27 SDKs, found device=%s simulator=%s.\n' \
    "$iphoneos_version" "$iphonesimulator_version" >&2
  exit 1
fi

common_sources=(
  "$module_dir/DHAVConferenceReceiver.mm"
)
common_flags=(
  -std=c++20
  -fobjc-arc
  -fmodules
  -Wall
  -Wextra
  -Werror
  -framework Foundation
  -framework QuartzCore
  -I "$module_dir/include"
  -I "$module_dir"
)

printf 'Running macOS negotiation and lifecycle tests...\n'
xcrun --sdk macosx clang++ \
  "${common_flags[@]}" \
  -framework CoreGraphics \
  "${common_sources[@]}" \
  "$tests_dir/DHAVConferenceTestSupport.mm" \
  "$tests_dir/DHAVConferenceReceiverTests.mm" \
  -o "$work_dir/DeviceHubPrivateMediaTests"
"$work_dir/DeviceHubPrivateMediaTests"

printf 'Compiling and linking the iPhoneOS 27 probe with warnings as errors...\n'
iphoneos_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang++ \
  "${common_flags[@]}" \
  -framework UIKit \
  -target arm64-apple-ios27.0 \
  -isysroot "$iphoneos_sdk" \
  "${common_sources[@]}" \
  "$module_dir/Probe/main.mm" \
  -o "$work_dir/DeviceHubPrivateMediaDeviceProbe"

simulator_runtime_version=$(
  xcrun simctl getenv "$simulator_udid" SIMULATOR_RUNTIME_VERSION
)
if [[ ${simulator_runtime_version%%.*} != 27 ]]; then
  printf 'Expected an iOS 27 simulator, found %s (%s).\n' \
    "$simulator_runtime_version" "$simulator_udid" >&2
  exit 1
fi

printf 'Running the fail-closed iOS 27 Simulator runtime probe...\n'
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
simulator_arch=$(uname -m)
case "$simulator_arch" in
  arm64 | x86_64) ;;
  *)
    printf 'Unsupported simulator host architecture: %s\n' "$simulator_arch" >&2
    exit 1
    ;;
esac

probe_app="$work_dir/DeviceHubPrivateMediaProbe.app"
mkdir -p "$probe_app"
cp "$module_dir/Probe/Info.plist" "$probe_app/Info.plist"
xcrun --sdk iphonesimulator clang++ \
  "${common_flags[@]}" \
  -framework UIKit \
  -target "$simulator_arch-apple-ios27.0-simulator" \
  -isysroot "$simulator_sdk" \
  "${common_sources[@]}" \
  "$module_dir/Probe/main.mm" \
  -o "$probe_app/DeviceHubPrivateMediaProbe"
codesign --force --sign - "$probe_app" >/dev/null

probe_home="$work_dir/probe-home"
mkdir -p "$probe_home/Documents"
probe_result="$probe_home/Documents/private-media-probe.plist"
SIMCTL_CHILD_DEVICE_HUB_PRIVATE_MEDIA_DIRECT=1 \
  SIMCTL_CHILD_DEVICE_HUB_PRIVATE_MEDIA_RESULT_PATH="$probe_result" \
  SIMCTL_CHILD_CFFIXED_USER_HOME="$probe_home" \
  SIMCTL_CHILD_HOME="$probe_home" \
  xcrun simctl spawn \
    "$simulator_udid" "$probe_app/DeviceHubPrivateMediaProbe"

if [[ ! -f "$probe_result" ]]; then
  printf 'The Simulator probe did not produce its result plist.\n' >&2
  exit 1
fi

passed=$(plutil -extract passed raw -o - "$probe_result")
runtime_ready=$(plutil -extract runtimeContractReady raw -o - "$probe_result")
negotiation_ready=$(
  plutil -extract syntheticNegotiationReady raw -o - "$probe_result"
)
expected_simulator_limit=$(
  plutil -extract expectedSimulatorNegotiationLimitation raw -o - "$probe_result"
)
if [[ "$passed" != true || "$runtime_ready" != true ]]; then
  plutil -p "$probe_result" >&2
  exit 1
fi
if [[ "$negotiation_ready" != true && "$expected_simulator_limit" != true ]]; then
  plutil -p "$probe_result" >&2
  exit 1
fi

plutil -p "$probe_result"
printf 'PASS: DeviceHubPrivateMedia macOS, iPhoneOS, and Simulator gates.\n'

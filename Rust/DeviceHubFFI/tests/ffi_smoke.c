#include "device_hub_ffi.h"

#include <stdbool.h>

_Static_assert(sizeof(DhBytes) == 16, "DhBytes ABI drift");
_Static_assert(sizeof(DhGeneration) == 16, "DhGeneration ABI drift");
_Static_assert(sizeof(DhControllerIdentity) == 72,
               "DhControllerIdentity ABI drift");
_Static_assert(sizeof(DhResolvedEndpoint) == 32,
               "DhResolvedEndpoint ABI drift");
_Static_assert(sizeof(DhTargetPairingRecord) == 128,
               "DhTargetPairingRecord ABI drift");
_Static_assert(sizeof(DhValidatedRemoteService) == 80,
               "DhValidatedRemoteService ABI drift");
_Static_assert(sizeof(DhVerifiedPeer) == 112, "DhVerifiedPeer ABI drift");
_Static_assert(sizeof(DhRsdMetadata) == 104, "DhRsdMetadata ABI drift");
_Static_assert(sizeof(DhVideoConfiguration) == 72,
               "DhVideoConfiguration ABI drift");
_Static_assert(sizeof(DhVideoAccessUnit) == 64,
               "DhVideoAccessUnit ABI drift");
_Static_assert(sizeof(DhVideoDatagram) == 24, "DhVideoDatagram ABI drift");
_Static_assert(sizeof(DhDisplayGeometry) == 24,
               "DhDisplayGeometry ABI drift");
_Static_assert(sizeof(DhEvent) == 136, "DhEvent ABI drift");
_Static_assert(sizeof(DhPairingSessionConfig) == 88,
               "DhPairingSessionConfig ABI drift");
_Static_assert(sizeof(DhRemoteSessionConfig) == 104,
               "DhRemoteSessionConfig ABI drift");
_Static_assert(sizeof(DhTouchInput) == 40, "DhTouchInput ABI drift");
_Static_assert(sizeof(DhKeyboardInput) == 32, "DhKeyboardInput ABI drift");
_Static_assert(sizeof(DhHardwareButtonInput) == 40,
               "DhHardwareButtonInput ABI drift");
_Static_assert(sizeof(DhVideoControlDatagram) == 40,
               "DhVideoControlDatagram ABI drift");
_Static_assert(sizeof(DhRotationInput) == 32, "DhRotationInput ABI drift");
_Static_assert(sizeof(DhReleaseAllInput) == 24,
               "DhReleaseAllInput ABI drift");

_Static_assert(offsetof(DhResolvedEndpoint, scope_id) == 24,
               "DhResolvedEndpoint.scope_id ABI drift");
_Static_assert(offsetof(DhTargetPairingRecord, completion) == 120,
               "DhTargetPairingRecord.completion ABI drift");
_Static_assert(offsetof(DhValidatedRemoteService, auth_tags) == 56,
               "DhValidatedRemoteService.auth_tags ABI drift");
_Static_assert(offsetof(DhRsdMetadata, operating_system_version) == 16,
               "DhRsdMetadata.operating_system_version ABI drift");
_Static_assert(offsetof(DhRsdMetadata, build_version) == 32,
               "DhRsdMetadata.build_version ABI drift");
_Static_assert(offsetof(DhRsdMetadata, unique_device_id) == 48,
               "DhRsdMetadata.unique_device_id ABI drift");
_Static_assert(offsetof(DhRsdMetadata, product_type) == 64,
               "DhRsdMetadata.product_type ABI drift");
_Static_assert(offsetof(DhRsdMetadata, protocol_version) == 80,
               "DhRsdMetadata.protocol_version ABI drift");
_Static_assert(offsetof(DhVideoAccessUnit, geometry) == 40,
               "DhVideoAccessUnit.geometry ABI drift");
_Static_assert(offsetof(DhEvent, sequence) == 24,
               "DhEvent.sequence ABI drift");
_Static_assert(offsetof(DhEvent, request_id) == 48,
               "DhEvent.request_id ABI drift");
_Static_assert(offsetof(DhEvent, payload) == 64, "DhEvent.payload ABI drift");
_Static_assert(offsetof(DhEvent, video_configuration) == 96,
               "DhEvent.video_configuration ABI drift");
_Static_assert(offsetof(DhEvent, image_width) == 128,
               "DhEvent.image_width ABI drift");
_Static_assert(offsetof(DhPairingSessionConfig, callback) == 72,
               "DhPairingSessionConfig.callback ABI drift");
_Static_assert(offsetof(DhRemoteSessionConfig, video_negotiator_offer) == 56,
               "DhRemoteSessionConfig.video_negotiator_offer ABI drift");
_Static_assert(offsetof(DhRemoteSessionConfig, callback) == 72,
               "DhRemoteSessionConfig.callback ABI drift");
_Static_assert(offsetof(DhRemoteSessionConfig, media_callback) == 88,
               "DhRemoteSessionConfig.media_callback ABI drift");
_Static_assert(offsetof(DhKeyboardInput, usage) == 28,
               "DhKeyboardInput.usage ABI drift");
_Static_assert(offsetof(DhKeyboardInput, modifiers) == 30,
               "DhKeyboardInput.modifiers ABI drift");
_Static_assert(offsetof(DhKeyboardInput, reserved) == 31,
               "DhKeyboardInput.reserved ABI drift");

_Static_assert(DH_CAPABILITY_SESSION_LIFECYCLE == ((DhCapabilities)1 << 0),
               "capability ABI drift");
_Static_assert(DH_CAPABILITY_PNG_SCREENSHOT == ((DhCapabilities)1 << 7),
               "capability ABI drift");
_Static_assert(DH_CAPABILITY_RELEASE_ALL_INPUT == ((DhCapabilities)1 << 18),
               "capability ABI drift");
_Static_assert(DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS ==
                   ((DhCapabilities)1 << 19),
               "capability ABI drift");
_Static_assert((DH_REQUIRED_CAPABILITIES_PAIRING &
                DH_CAPABILITY_PAIRABLE_HOST) != 0,
               "pairing capability group drift");
_Static_assert((DH_REQUIRED_CAPABILITIES_LIVE_CONTROL &
                DH_CAPABILITY_SPLIT_MEDIA_CALLBACK) != 0,
               "live capability group drift");
_Static_assert((DH_REQUIRED_CAPABILITIES_LIVE_CONTROL &
                DH_CAPABILITY_PNG_SCREENSHOT) != 0,
               "live screenshot capability group drift");
_Static_assert((DH_REQUIRED_CAPABILITIES_LIVE_CONTROL &
                DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS) != 0,
               "live geometry capability group drift");
_Static_assert(DH_EVENT_PAIR_RECORD_PROVISIONAL == 5, "event ABI drift");
_Static_assert(DH_EVENT_SESSION_CANCELLED == 12, "event ABI drift");
_Static_assert(DH_EVENT_DISPLAY_GEOMETRY == 19, "event ABI drift");
_Static_assert(DH_TOUCH_PHASE_TAP == 5, "touch ABI drift");
_Static_assert(DH_KEYBOARD_PHASE_TAP == 4, "keyboard ABI drift");
_Static_assert(DH_BUTTON_PHASE_TAP == 4, "button phase ABI drift");
_Static_assert(DH_HARDWARE_BUTTON_SIRI == 6, "button ABI drift");
_Static_assert(DH_SESSION_STATE_WAITING_FOR_PERSISTENCE == 3,
               "state ABI drift");
_Static_assert(DH_CONNECTION_PHASE_CAPTURING_SCREENSHOT == 8,
               "phase ABI drift");

static bool consume_error(DhError **error) {
  const char *json = dh_error_json(*error);
  const bool valid = json != NULL;
  dh_error_free(error);
  dh_error_free(error);
  return valid && *error == NULL;
}

int main(void) {
  DhSession *session = NULL;
  DhError *error = NULL;

  const uint32_t abi = dh_ffi_abi_version();
  const DhCapabilities capabilities = dh_ffi_capabilities();
  const char *version = dh_ffi_version();
  const char *revision = dh_ffi_idevice_revision();

  const DhStatus pairing_status =
      dh_pairing_session_create(NULL, &session, &error);
  const bool pairing_error_owned =
      pairing_status == DH_STATUS_INVALID_ARGUMENT && session == NULL &&
      error != NULL && consume_error(&error);

  const DhStatus remote_status =
      dh_remote_session_create(NULL, &session, &error);
  const bool remote_error_owned =
      remote_status == DH_STATUS_INVALID_ARGUMENT && session == NULL &&
      error != NULL && consume_error(&error);

  const DhStatus start_status = dh_session_start(session, &error);
  const bool start_error_owned =
      start_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);

  const DhStatus persistence_status = dh_session_complete_persistence(
      session, 1, DH_PERSISTENCE_SUCCEEDED, &error);
  const bool persistence_error_owned =
      persistence_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);

  const DhGeneration generation = {0, 0};
  const DhStatus negotiation_status = dh_session_complete_video_negotiation(
      session, generation, DH_VIDEO_NEGOTIATION_SUCCEEDED, &error);
  const bool negotiation_error_owned =
      negotiation_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);

  const DhStatus touch_status = dh_session_send_touch(session, NULL, &error);
  const bool touch_error_owned =
      touch_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);
  const DhStatus keyboard_status =
      dh_session_send_keyboard(session, NULL, &error);
  const bool keyboard_error_owned =
      keyboard_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);
  const DhStatus button_status =
      dh_session_send_hardware_button(session, NULL, &error);
  const bool button_error_owned =
      button_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);
  const DhStatus rotation_status = dh_session_rotate(session, NULL, &error);
  const bool rotation_error_owned =
      rotation_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);
  const DhStatus release_status =
      dh_session_release_all_input(session, NULL, &error);
  const bool release_error_owned =
      release_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);
  const DhStatus video_control_status =
      dh_session_send_video_control_datagram(session, NULL, &error);
  const bool video_control_error_owned =
      video_control_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);

  const DhStatus cancel_status = dh_session_cancel(session, &error);
  const bool cancel_error_owned =
      cancel_status == DH_STATUS_INVALID_ARGUMENT && error != NULL &&
      consume_error(&error);

  const DhStatus first_free_status = dh_session_free(&session);
  const DhStatus second_free_status = dh_session_free(&session);
  const DhStatus null_storage_status = dh_session_free(NULL);

  return (abi == DH_ABI_VERSION && capabilities != 0 && version != NULL &&
          revision != NULL && pairing_error_owned && remote_error_owned &&
          start_error_owned && persistence_error_owned && cancel_error_owned &&
          negotiation_error_owned && touch_error_owned && keyboard_error_owned &&
          button_error_owned && rotation_error_owned && release_error_owned &&
          video_control_error_owned &&
          first_free_status == DH_STATUS_OK &&
          second_free_status == DH_STATUS_OK &&
          null_storage_status == DH_STATUS_INVALID_ARGUMENT && session == NULL &&
          error == NULL && dh_error_json(NULL) == NULL)
             ? 0
             : 1;
}

use std::{
    fs,
    mem::{align_of, offset_of, size_of},
    path::PathBuf,
};

use device_hub_ffi::{
    DhButtonPhase, DhBytes, DhConnectionPhase, DhControllerIdentity, DhDisplayGeometry, DhEvent,
    DhEventKind, DhGeneration, DhHardwareButton, DhHardwareButtonInput, DhIpFamily,
    DhKeyboardInput, DhKeyboardPhase, DhOrientation, DhPairingCompletion, DhPairingSessionConfig,
    DhPersistenceOutcome, DhReleaseAllInput, DhRemoteOperation, DhRemoteSessionConfig,
    DhResolvedEndpoint, DhRotationDirection, DhRotationInput, DhRsdMetadata, DhSessionState,
    DhTargetPairingRecord, DhTouchInput, DhTouchPhase, DhValidatedRemoteService, DhVerifiedPeer,
    DhVideoAccessUnit, DhVideoConfiguration, DhVideoControlDatagram, DhVideoDatagram,
    DhVideoDiscontinuity, DhVideoNegotiationOutcome,
};

#[test]
fn public_header_declares_the_complete_exported_surface() {
    let header = fs::read_to_string(header_path()).expect("public header must be readable");
    for symbol in [
        "dh_ffi_abi_version",
        "dh_ffi_capabilities",
        "dh_ffi_version",
        "dh_ffi_idevice_revision",
        "dh_pairing_session_create",
        "dh_remote_session_create",
        "dh_session_start",
        "dh_session_complete_persistence",
        "dh_session_complete_video_negotiation",
        "dh_session_send_touch",
        "dh_session_send_keyboard",
        "dh_session_send_hardware_button",
        "dh_session_rotate",
        "dh_session_release_all_input",
        "dh_session_send_video_control_datagram",
        "dh_session_cancel",
        "dh_session_free",
        "dh_error_json",
        "dh_error_free",
    ] {
        assert!(
            header.contains(symbol),
            "public header is missing exported symbol {symbol}"
        );
    }
    assert!(
        !header.contains("dh_session_create("),
        "the retired generic constructor must not remain in the public ABI"
    );

    for declaration in [
        "DhControllerIdentity",
        "DhResolvedEndpoint",
        "DhTargetPairingRecord",
        "DhValidatedRemoteService",
        "DhVerifiedPeer",
        "DhRsdMetadata",
        "DhVideoConfiguration",
        "DhVideoAccessUnit",
        "DhVideoDatagram",
        "DhDisplayGeometry",
        "DhEvent",
        "DhPairingSessionConfig",
        "DhRemoteSessionConfig",
        "DhTouchInput",
        "DhKeyboardInput",
        "DhHardwareButtonInput",
        "DhRotationInput",
        "DhReleaseAllInput",
        "DhVideoControlDatagram",
    ] {
        assert!(
            header.contains(declaration),
            "public header is missing ABI type {declaration}"
        );
    }

    for rsd_field in [
        "operating_system_version",
        "build_version",
        "unique_device_id",
        "product_type",
    ] {
        assert!(
            header.contains(rsd_field),
            "public RSD metadata is missing authenticated field {rsd_field}"
        );
    }

    for capability in [
        "DH_CAPABILITY_SESSION_LIFECYCLE",
        "DH_CAPABILITY_GENERATION_TAGGED_EVENTS",
        "DH_CAPABILITY_SENSITIVE_INPUT_COPY",
        "DH_CAPABILITY_PAIRABLE_HOST",
        "DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS",
        "DH_CAPABILITY_AUTHENTICATED_RECONNECT",
        "DH_CAPABILITY_RSD_METADATA",
        "DH_CAPABILITY_PNG_SCREENSHOT",
        "DH_CAPABILITY_DEVELOPER_READINESS",
        "DH_CAPABILITY_CONTROL_STREAM",
        "DH_CAPABILITY_VIDEO_NEGOTIATION",
        "DH_CAPABILITY_RAW_VIDEO_DATAGRAMS",
        "DH_CAPABILITY_HEVC_ACCESS_UNITS",
        "DH_CAPABILITY_TOUCH_INPUT",
        "DH_CAPABILITY_KEYBOARD_INPUT",
        "DH_CAPABILITY_HARDWARE_BUTTON_INPUT",
        "DH_CAPABILITY_ROTATION",
        "DH_CAPABILITY_SPLIT_MEDIA_CALLBACK",
        "DH_CAPABILITY_RELEASE_ALL_INPUT",
        "DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS",
        "DH_CAPABILITY_PAIR_VERIFY_DISCOVERY",
        "DH_REQUIRED_CAPABILITIES_PAIRING",
        "DH_REQUIRED_CAPABILITIES_SCREENSHOT",
        "DH_REQUIRED_CAPABILITIES_LIVE_CONTROL",
    ] {
        assert!(
            header.contains(capability),
            "public header is missing capability {capability}"
        );
    }

    assert!(
        header.contains("#define DH_ABI_VERSION ((uint32_t)3)"),
        "the access-unit layout change must fail closed as ABI version 2"
    );
    assert!(
        header.contains("#define DH_REMOTE_OPERATION_PAIR_VERIFY ((DhRemoteOperation)3)"),
        "the public header must expose the Pair Verify discovery operation"
    );
    assert!(
        header.contains("DhDisplayGeometry geometry;"),
        "each access unit must carry its authoritative geometry snapshot"
    );
    let live_control_capabilities = header
        .split("#define DH_REQUIRED_CAPABILITIES_LIVE_CONTROL")
        .nth(1)
        .expect("live-control capability group")
        .split("typedef uint32_t DhIpFamily")
        .next()
        .expect("live-control capability body");
    assert!(
        live_control_capabilities.contains("DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS"),
        "live control must reject a native library without media geometry snapshots"
    );
}

#[test]
fn documented_64_bit_sizes_and_alignments_match_rust() {
    assert_layout::<DhBytes>(16, 8);
    assert_layout::<DhGeneration>(16, 8);
    assert_layout::<DhControllerIdentity>(72, 8);
    assert_layout::<DhResolvedEndpoint>(32, 4);
    assert_layout::<DhTargetPairingRecord>(128, 8);
    assert_layout::<DhValidatedRemoteService>(80, 8);
    assert_layout::<DhVerifiedPeer>(112, 8);
    assert_layout::<DhRsdMetadata>(104, 8);
    assert_layout::<DhVideoConfiguration>(72, 8);
    assert_layout::<DhVideoAccessUnit>(64, 8);
    assert_layout::<DhVideoDatagram>(24, 8);
    assert_layout::<DhDisplayGeometry>(24, 4);
    assert_layout::<DhEvent>(136, 8);
    assert_layout::<DhPairingSessionConfig>(88, 8);
    assert_layout::<DhRemoteSessionConfig>(104, 8);
    assert_layout::<DhTouchInput>(40, 8);
    assert_layout::<DhKeyboardInput>(32, 8);
    assert_layout::<DhHardwareButtonInput>(40, 8);
    assert_layout::<DhVideoControlDatagram>(40, 8);
    assert_layout::<DhRotationInput>(32, 8);
    assert_layout::<DhReleaseAllInput>(24, 8);

    for size in [
        size_of::<DhIpFamily>(),
        size_of::<DhPairingCompletion>(),
        size_of::<DhSessionState>(),
        size_of::<DhConnectionPhase>(),
        size_of::<DhEventKind>(),
        size_of::<DhRemoteOperation>(),
        size_of::<DhVideoNegotiationOutcome>(),
        size_of::<DhVideoDiscontinuity>(),
        size_of::<DhTouchPhase>(),
        size_of::<DhKeyboardPhase>(),
        size_of::<DhHardwareButton>(),
        size_of::<DhButtonPhase>(),
        size_of::<DhRotationDirection>(),
        size_of::<DhOrientation>(),
        size_of::<DhPersistenceOutcome>(),
    ] {
        assert_eq!(size, 4, "all public discriminants must be uint32_t");
    }
}

#[test]
fn documented_64_bit_field_offsets_match_rust() {
    assert_eq!(offset_of!(DhControllerIdentity, identifier), 8);
    assert_eq!(offset_of!(DhControllerIdentity, long_term_secret_key), 40);
    assert_eq!(offset_of!(DhControllerIdentity, alternate_irk), 56);

    assert_eq!(offset_of!(DhResolvedEndpoint, address), 8);
    assert_eq!(offset_of!(DhResolvedEndpoint, scope_id), 24);
    assert_eq!(offset_of!(DhResolvedEndpoint, port), 28);

    assert_eq!(offset_of!(DhTargetPairingRecord, device_id), 8);
    assert_eq!(offset_of!(DhTargetPairingRecord, peer_public_key), 56);
    assert_eq!(offset_of!(DhTargetPairingRecord, completion), 120);

    assert_eq!(offset_of!(DhValidatedRemoteService, endpoint), 8);
    assert_eq!(offset_of!(DhValidatedRemoteService, identifier), 40);
    assert_eq!(offset_of!(DhValidatedRemoteService, auth_tags), 56);
    assert_eq!(
        offset_of!(DhValidatedRemoteService, wire_protocol_version),
        72
    );

    assert_eq!(offset_of!(DhRsdMetadata, operating_system_version), 16);
    assert_eq!(offset_of!(DhRsdMetadata, build_version), 32);
    assert_eq!(offset_of!(DhRsdMetadata, unique_device_id), 48);
    assert_eq!(offset_of!(DhRsdMetadata, product_type), 64);
    assert_eq!(offset_of!(DhRsdMetadata, protocol_version), 80);
    assert_eq!(offset_of!(DhRsdMetadata, screenshot_service_available), 96);

    assert_eq!(offset_of!(DhVideoConfiguration, pixel_width), 8);
    assert_eq!(offset_of!(DhVideoConfiguration, orientation), 16);
    assert_eq!(offset_of!(DhVideoConfiguration, video_parameter_set), 24);
    assert_eq!(offset_of!(DhVideoAccessUnit, parameter_set_revision), 16);
    assert_eq!(offset_of!(DhVideoAccessUnit, is_sync), 36);
    assert_eq!(offset_of!(DhVideoAccessUnit, geometry), 40);
    assert_eq!(offset_of!(DhVideoDatagram, source_port), 16);
    assert_eq!(offset_of!(DhDisplayGeometry, orientation), 8);
    assert_eq!(offset_of!(DhDisplayGeometry, orientation_locked), 16);

    assert_eq!(offset_of!(DhEvent, generation), 8);
    assert_eq!(offset_of!(DhEvent, sequence), 24);
    assert_eq!(offset_of!(DhEvent, request_id), 48);
    assert_eq!(offset_of!(DhEvent, payload), 64);
    assert_eq!(offset_of!(DhEvent, video_configuration), 96);
    assert_eq!(offset_of!(DhEvent, video_access_unit), 104);
    assert_eq!(offset_of!(DhEvent, video_datagram), 112);
    assert_eq!(offset_of!(DhEvent, display_geometry), 120);
    assert_eq!(offset_of!(DhEvent, image_width), 128);

    assert_eq!(offset_of!(DhPairingSessionConfig, controller_identity), 24);
    assert_eq!(offset_of!(DhPairingSessionConfig, requested_port), 64);
    assert_eq!(offset_of!(DhPairingSessionConfig, callback), 72);
    assert_eq!(offset_of!(DhRemoteSessionConfig, controller_identity), 24);
    assert_eq!(offset_of!(DhRemoteSessionConfig, operation), 48);
    assert_eq!(
        offset_of!(DhRemoteSessionConfig, video_negotiator_offer),
        56
    );
    assert_eq!(offset_of!(DhRemoteSessionConfig, callback), 72);
    assert_eq!(offset_of!(DhRemoteSessionConfig, media_callback), 88);

    assert_eq!(offset_of!(DhTouchInput, phase), 24);
    assert_eq!(offset_of!(DhTouchInput, reserved), 32);
    assert_eq!(offset_of!(DhKeyboardInput, usage), 28);
    assert_eq!(offset_of!(DhKeyboardInput, modifiers), 30);
    assert_eq!(offset_of!(DhKeyboardInput, reserved), 31);
    assert_eq!(offset_of!(DhHardwareButtonInput, reserved), 32);
    assert_eq!(offset_of!(DhVideoControlDatagram, bytes), 24);
    assert_eq!(offset_of!(DhRotationInput, direction), 24);
}

fn assert_layout<T>(expected_size: usize, expected_alignment: usize) {
    assert_eq!(size_of::<T>(), expected_size);
    assert_eq!(align_of::<T>(), expected_alignment);
}

fn header_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("include")
        .join("device_hub_ffi.h")
}

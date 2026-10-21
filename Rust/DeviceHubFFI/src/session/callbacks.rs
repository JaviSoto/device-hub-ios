use super::*;
pub(super) fn invoke_callback(
    message: &EventMessage,
    generation: DhGeneration,
    sequence: u64,
    callback: unsafe extern "C" fn(*const DhEvent, *mut c_void),
    callback_context: usize,
) {
    let mut peer_view = None;
    let mut rsd_view = None;
    let mut display_geometry_view = None;
    let (kind, state, phase, request_id, value, payload, dimensions) = match message {
        EventMessage::Started => (
            DhEventKind::SessionStarted,
            DhSessionState::Running,
            DhConnectionPhase::Idle,
            0,
            0,
            DhBytes::empty(),
            None,
        ),
        EventMessage::Phase { phase, state } => (
            DhEventKind::PhaseChanged,
            *state,
            *phase,
            0,
            0,
            DhBytes::empty(),
            None,
        ),
        EventMessage::ListenerReady(port) => (
            DhEventKind::PairingListenerReady,
            DhSessionState::Running,
            DhConnectionPhase::AwaitingPairingPeer,
            0,
            u64::from(*port),
            DhBytes::empty(),
            None,
        ),
        EventMessage::PairingCode(code) => (
            DhEventKind::PairingCode,
            DhSessionState::Running,
            DhConnectionPhase::Pairing,
            0,
            0,
            DhBytes::from_slice(code.as_bytes()),
            None,
        ),
        EventMessage::PairRecord {
            kind,
            request_id,
            peer,
        } => {
            peer_view = Some(peer_view_for(peer));
            (
                *kind,
                DhSessionState::WaitingForPersistence,
                DhConnectionPhase::PersistingPairRecord,
                *request_id,
                0,
                DhBytes::empty(),
                None,
            )
        }
        EventMessage::Authenticated => (
            DhEventKind::Authenticated,
            DhSessionState::Connected,
            DhConnectionPhase::VerifyingPairing,
            0,
            0,
            DhBytes::empty(),
            None,
        ),
        EventMessage::RsdReady(snapshot) => {
            rsd_view = Some(DhRsdMetadata {
                uuid: DhBytes::from_slice(snapshot.uuid.as_bytes()),
                operating_system_version: DhBytes::from_slice(
                    snapshot.operating_system_version.as_bytes(),
                ),
                build_version: DhBytes::from_slice(snapshot.build_version.as_bytes()),
                unique_device_id: DhBytes::from_slice(snapshot.unique_device_id.as_bytes()),
                product_type: DhBytes::from_slice(snapshot.product_type.as_bytes()),
                protocol_version: snapshot.protocol_version,
                service_count: snapshot.service_count,
                screenshot_service_available: u8::from(snapshot.screenshot_service_available),
                reserved: [0; 7],
            });
            (
                DhEventKind::RsdReady,
                DhSessionState::Connected,
                DhConnectionPhase::DiscoveringServices,
                0,
                0,
                DhBytes::empty(),
                None,
            )
        }
        EventMessage::Screenshot { bytes, dimensions } => (
            DhEventKind::ScreenshotPng,
            DhSessionState::Connected,
            DhConnectionPhase::CapturingScreenshot,
            0,
            0,
            DhBytes::from_slice(bytes),
            Some(*dimensions),
        ),
        EventMessage::InputReady => (
            DhEventKind::InputReady,
            DhSessionState::Connected,
            DhConnectionPhase::Streaming,
            0,
            0,
            DhBytes::empty(),
            None,
        ),
        EventMessage::DisplayGeometry(geometry) => {
            display_geometry_view = Some(*geometry);
            (
                DhEventKind::DisplayGeometry,
                DhSessionState::Connected,
                DhConnectionPhase::Streaming,
                0,
                0,
                DhBytes::empty(),
                None,
            )
        }
        EventMessage::Completed => (
            DhEventKind::SessionCompleted,
            DhSessionState::Completed,
            DhConnectionPhase::Ready,
            0,
            0,
            DhBytes::empty(),
            None,
        ),
        EventMessage::Failed(payload) => (
            DhEventKind::SessionFailed,
            DhSessionState::Failed,
            DhConnectionPhase::Idle,
            0,
            0,
            DhBytes::from_slice(payload),
            None,
        ),
        EventMessage::Cancelled => (
            DhEventKind::SessionCancelled,
            DhSessionState::Cancelled,
            DhConnectionPhase::Idle,
            0,
            0,
            DhBytes::empty(),
            None,
        ),
        EventMessage::Barrier(_) | EventMessage::Shutdown => return,
    };
    let event = DhEvent {
        struct_size: size_of::<DhEvent>() as u32,
        abi_version: DH_ABI_VERSION,
        generation,
        sequence,
        kind,
        state,
        phase,
        reserved: 0,
        request_id,
        value,
        payload,
        peer: peer_view
            .as_ref()
            .map_or(std::ptr::null(), std::ptr::from_ref),
        rsd: rsd_view
            .as_ref()
            .map_or(std::ptr::null(), std::ptr::from_ref),
        video_configuration: std::ptr::null(),
        video_access_unit: std::ptr::null(),
        video_datagram: std::ptr::null(),
        display_geometry: display_geometry_view
            .as_ref()
            .map_or(std::ptr::null(), std::ptr::from_ref),
        image_width: dimensions.map_or(0, |image| image.width),
        image_height: dimensions.map_or(0, |image| image.height),
    };
    let _scope = CallbackScope::enter();
    // SAFETY: Session creation establishes callback/context lifetime and the
    // callback contract forbids unwinding. Every borrowed view remains alive
    // for the complete invocation.
    unsafe { callback(&event, callback_context as *mut c_void) };
}

pub(super) fn invoke_media_callback(
    message: &MediaEventMessage,
    generation: DhGeneration,
    sequence: u64,
    callback: unsafe extern "C" fn(*const DhEvent, *mut c_void),
    callback_context: usize,
) {
    let mut configuration_view = None;
    let mut access_unit_view = None;
    let mut datagram_view = None;
    let (kind, value) = match message {
        MediaEventMessage::Datagram { bytes, source_port } => {
            datagram_view = Some(DhVideoDatagram {
                bytes: DhBytes::from_slice(bytes),
                source_port: *source_port,
                reserved: [0; 6],
            });
            (DhEventKind::VideoDatagram, 0)
        }
        MediaEventMessage::Configuration {
            configuration,
            orientation,
        } => {
            configuration_view = Some(DhVideoConfiguration {
                revision: configuration.revision,
                pixel_width: configuration.pixel_width,
                pixel_height: configuration.pixel_height,
                orientation: *orientation as u32,
                reserved: 0,
                video_parameter_set: DhBytes::from_slice(&configuration.video_parameter_set),
                sequence_parameter_set: DhBytes::from_slice(&configuration.sequence_parameter_set),
                picture_parameter_set: DhBytes::from_slice(&configuration.picture_parameter_set),
            });
            (DhEventKind::VideoConfiguration, configuration.revision)
        }
        MediaEventMessage::AccessUnit {
            access_unit,
            geometry,
        } => {
            access_unit_view = Some(DhVideoAccessUnit {
                bytes: DhBytes::from_slice(&access_unit.bytes),
                parameter_set_revision: access_unit.parameter_set_revision,
                ssrc: access_unit.ssrc,
                rtp_timestamp: access_unit.rtp_timestamp,
                first_sequence_number: access_unit.first_sequence_number,
                last_sequence_number: access_unit.last_sequence_number,
                is_sync: u8::from(access_unit.is_sync),
                reserved: [0; 3],
                geometry: *geometry,
            });
            (
                DhEventKind::VideoAccessUnit,
                access_unit.parameter_set_revision,
            )
        }
        MediaEventMessage::Discontinuity(discontinuity) => {
            (DhEventKind::VideoDiscontinuity, *discontinuity as u64)
        }
    };
    let event = DhEvent {
        struct_size: size_of::<DhEvent>() as u32,
        abi_version: DH_ABI_VERSION,
        generation,
        sequence,
        kind,
        state: DhSessionState::Connected,
        phase: DhConnectionPhase::Streaming,
        reserved: 0,
        request_id: 0,
        value,
        payload: DhBytes::empty(),
        peer: std::ptr::null(),
        rsd: std::ptr::null(),
        video_configuration: configuration_view
            .as_ref()
            .map_or(std::ptr::null(), std::ptr::from_ref),
        video_access_unit: access_unit_view
            .as_ref()
            .map_or(std::ptr::null(), std::ptr::from_ref),
        video_datagram: datagram_view
            .as_ref()
            .map_or(std::ptr::null(), std::ptr::from_ref),
        display_geometry: std::ptr::null(),
        image_width: 0,
        image_height: 0,
    };
    let _scope = MediaCallbackScope::enter();
    // SAFETY: Session creation establishes callback/context lifetime and every
    // borrowed media view remains alive for this synchronous invocation.
    unsafe { callback(&event, callback_context as *mut c_void) };
}

fn peer_view_for(peer: &PeerRecord) -> DhVerifiedPeer {
    DhVerifiedPeer {
        device_id: DhBytes::from_slice(peer.device_id.as_bytes()),
        account_identifier: DhBytes::from_slice(peer.account_identifier.as_bytes()),
        peer_identifier: DhBytes::from_slice(peer.peer_identifier.as_bytes()),
        peer_public_key: DhBytes::from_slice(&peer.peer_public_key),
        peer_alternate_irk: DhBytes::from_slice(&peer.peer_alternate_irk),
        display_name: DhBytes::from_slice(peer.display_name.as_bytes()),
        product_type: DhBytes::from_slice(peer.product_type.as_bytes()),
    }
}

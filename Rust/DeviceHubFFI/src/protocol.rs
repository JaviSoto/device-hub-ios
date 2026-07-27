//! Real iOS 27 pairing, authenticated tunnel, RSD, and screenshot operations.

use std::{
    collections::{BTreeMap, BTreeSet},
    future::Future,
    net::{IpAddr, Ipv6Addr, SocketAddr, SocketAddrV6},
    time::Duration,
};

use idevice::{
    IdeviceError, RsdService,
    core_device::{
        ButtonState, CallInfoBlob, DisplayServiceClient, HardwareButton, HevcAccessUnitAssembler,
        HevcDepacketizerEvent, HevcDiscontinuity, HevcPacketRejection, HidError, ImageFormat,
        IndigoHidClient, KeyboardServiceConfiguration, KeyboardUsage, Orientation,
        OrientationServiceClient, OrientationState, RotationDirection, RtpPacket,
        ScreenCaptureServiceClient, ScreenVideoAnswerError, TouchEvent, TouchPoint,
        UniversalHidServiceClient, build_frame_ack, build_keyframe_request, build_rctl,
        build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters,
        build_start_video_parameters, is_rtcp, parse_screen_video_answer,
    },
    provider::RsdProvider,
    remote_pairing::{
        PairRecordState, PairableHost, PairableHostInfo, RemotePairingClient, RpPairingSocket,
        connect_tls_psk_tunnel_native, errors::RemotePairingError,
    },
    rsd::RsdHandshake,
    services::mobile_image_mounter::ImageMounter,
    tcp,
};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::{TcpListener, TcpStream};

use crate::{
    abi::{
        DhButtonPhase, DhConnectionPhase, DhDisplayGeometry, DhEventKind, DhHardwareButton,
        DhOrientation, DhPairingCompletion, DhSessionState, DhVideoDiscontinuity,
    },
    model::{
        KeyboardIntent, Operation, PairingOperation, PeerRecord, RemoteMode, RemoteOperation,
        RotationIntent, TouchIntent, ValidationError,
    },
    png::validate_png,
    session::{
        ControlCommand, ControlGate, EventEmitter, MediaEmitter, PersistenceGate, PublicFailure,
        RsdSnapshot,
    },
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(12);
const PAIR_SETUP_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const PAIR_VERIFY_TIMEOUT: Duration = Duration::from_secs(30);
const TUNNEL_TIMEOUT: Duration = Duration::from_secs(30);
const RSD_TIMEOUT: Duration = Duration::from_secs(30);
const DEVELOPER_READINESS_TIMEOUT: Duration = Duration::from_secs(30);
const SCREENSHOT_TIMEOUT: Duration = Duration::from_secs(30);
const MEDIA_START_TIMEOUT: Duration = Duration::from_secs(30);
const FIRST_VIDEO_FRAME_TIMEOUT: Duration = Duration::from_secs(30);
const VIDEO_FEEDBACK_INTERVAL: Duration = Duration::from_millis(50);
const INPUT_TIMEOUT: Duration = Duration::from_secs(12);
const INPUT_CLEANUP_TIMEOUT: Duration = Duration::from_secs(3);
const INPUT_TAP_HOLD: Duration = Duration::from_millis(50);
const LOCK_BUTTON_HOLD: Duration = Duration::from_millis(300);
const SIRI_BUTTON_HOLD: Duration = Duration::from_secs(1);
const PERSISTENCE_TIMEOUT: Duration = Duration::from_secs(30);
const MIN_IPV6_MTU: u16 = 1_280;
const TCP_OVERHEAD_BUDGET: usize = 60;
const MAX_RSD_VERSION_BYTES: usize = 64;
const MAX_RSD_BUILD_BYTES: usize = 64;
const MAX_RSD_DEVICE_ID_BYTES: usize = 256;
const MAX_RSD_PRODUCT_TYPE_BYTES: usize = 128;
const SCREENSHOT_SERVICE: &str = "com.apple.coredevice.screencaptureservice";
const DISPLAY_SERVICE: &str = "com.apple.coredevice.displayservice";
const UNIVERSAL_HID_SERVICE: &str = "com.apple.coredevice.hid.universalhidservice";
const INDIGO_HID_SERVICE: &str = "com.apple.coredevice.hid.indigo";
const ORIENTATION_SERVICE: &str = "com.apple.coredevice.devicecontrol";
const CLIENT_SUPPORTED_FEATURES: u64 = 140;
const AUDIO_SENDER_PORT: u16 = 50_000;
const VIDEO_SENDER_PORT: u16 = 50_001;
const PRIMARY_DISPLAY_ID: i64 = 1;
const MAX_NEGOTIATOR_ANSWER_BYTES: usize = 1024 * 1024;

struct DeveloperReady;

#[derive(Clone, Copy)]
enum DeveloperReadinessProbe {
    DeveloperModeStatus,
    PersonalizedImageLookup,
}

/// Executes the selected real protocol operation.
pub(crate) async fn run(
    operation: Operation,
    emitter: EventEmitter,
    media: MediaEmitter,
    persistence: PersistenceGate,
    controls: ControlGate,
    cancellation: Option<tokio::sync::watch::Receiver<bool>>,
) -> Result<(), PublicFailure> {
    match operation {
        Operation::Pairing(operation) => run_pairing(operation, emitter, persistence).await,
        Operation::Remote(operation) => {
            run_remote(
                *operation,
                emitter,
                media,
                persistence,
                controls,
                cancellation,
            )
            .await
        }
    }
}

async fn run_pairing(
    operation: PairingOperation,
    emitter: EventEmitter,
    persistence: PersistenceGate,
) -> Result<(), PublicFailure> {
    emitter.phase(
        DhConnectionPhase::BindingPairingListener,
        DhSessionState::Running,
    )?;
    let listener = bind_pairing_listener(operation.requested_port)?;
    let port = listener
        .local_addr()
        .map_err(|_| {
            PublicFailure::new(
                "pairing_listener_address_failed",
                "pairing_listener",
                true,
                "Unable to inspect the native pairing listener.",
            )
        })?
        .port();
    if port == 0 {
        return Err(PublicFailure::new(
            "pairing_listener_invalid_port",
            "pairing_listener",
            false,
            "The native pairing listener returned an invalid port.",
        ));
    }
    emitter.listener_ready(port)?;
    emitter.phase(
        DhConnectionPhase::AwaitingPairingPeer,
        DhSessionState::Running,
    )?;

    let (stream, _) = listener.accept().await.map_err(|_| {
        PublicFailure::new(
            "pairing_listener_accept_failed",
            "pairing_listener",
            true,
            "Unable to accept the device pairing connection.",
        )
    })?;
    emitter.phase(DhConnectionPhase::Pairing, DhSessionState::Running)?;

    let mut pairing_file = operation.controller.pairing_file(None);
    let host_info = PairableHostInfo {
        name: operation.display_name,
        model: operation.model,
        udid: operation.controller.udid.clone(),
        identifier: operation.controller.identifier.clone(),
        wire_protocol_version: 26,
        alt_irk: *operation.controller.alternate_irk,
    };
    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);
    let pin_emitter = emitter.clone();
    let persist_gate = persistence.clone();

    stage(
        PAIR_SETUP_TIMEOUT,
        PublicFailure::new(
            "pair_setup_failed",
            "pair_setup",
            false,
            "The authenticated Pair Setup exchange failed.",
        ),
        host.accept_fallible(
            &mut pairing_file,
            move |pin| {
                let pin_emitter = pin_emitter.clone();
                async move {
                    pin_emitter
                        .pairing_code(pin)
                        .map_err(event_failure_as_idevice)
                }
            },
            move |state, peer| {
                let persist_gate = persist_gate.clone();
                async move {
                    let mut record =
                        PeerRecord::from_verified(&peer).map_err(validation_as_idevice)?;
                    let kind = match state {
                        PairRecordState::Provisional => DhEventKind::PairRecordProvisional,
                        PairRecordState::Committed => {
                            record.completion = DhPairingCompletion::Committed;
                            DhEventKind::PairRecordCommitted
                        }
                    };
                    tokio::time::timeout(PERSISTENCE_TIMEOUT, persist_gate.persist(kind, record))
                        .await
                        .map_err(|_| {
                            idevice::IdeviceError::RemotePairing(
                            idevice::remote_pairing::errors::RemotePairingError::
                                PairRecordPersistenceFailed,
                        )
                        })?
                }
            },
        ),
    )
    .await?;

    emitter.phase(DhConnectionPhase::Ready, DhSessionState::Completed)
}

async fn run_remote(
    operation: RemoteOperation,
    emitter: EventEmitter,
    media: MediaEmitter,
    persistence: PersistenceGate,
    controls: ControlGate,
    cancellation: Option<tokio::sync::watch::Receiver<bool>>,
) -> Result<(), PublicFailure> {
    emitter.phase(DhConnectionPhase::VerifyingPairing, DhSessionState::Running)?;
    let stream = stage(
        CONNECT_TIMEOUT,
        PublicFailure::new(
            "remote_pairing_connect_failed",
            "pair_verify",
            true,
            "Unable to connect to the authenticated remote-pairing endpoint.",
        ),
        TcpStream::connect(operation.service.endpoint),
    )
    .await?;
    let socket = RpPairingSocket::new(stream);
    let mut pairing_file = operation
        .controller
        .pairing_file(Some(&operation.target.peer_alternate_irk));
    let verified_peer = operation.target.verified_identity();
    let mut client = RemotePairingClient::new(socket, &operation.controller.identifier);
    match tokio::time::timeout(PAIR_VERIFY_TIMEOUT, client.attempt_pair_verify()).await {
        Ok(Ok(_)) => {}
        Ok(Err(error)) => return Err(pair_verify_failure(error)),
        Err(_) => {
            return Err(PublicFailure::new(
                "pair_verify_failed",
                "pair_verify_timeout",
                true,
                "The authenticated Pair Verify exchange timed out.",
            ));
        }
    }
    match tokio::time::timeout(
        PAIR_VERIFY_TIMEOUT,
        client.validate_pairing(&mut pairing_file, &verified_peer),
    )
    .await
    {
        Ok(Ok(())) => {}
        Ok(Err(error)) => return Err(pair_verify_failure(error)),
        Err(_) => {
            return Err(PublicFailure::new(
                "pair_verify_failed",
                "pair_verify_timeout",
                true,
                "The authenticated Pair Verify exchange timed out.",
            ));
        }
    }

    if should_promote_provisional_record(&operation.mode, operation.target.completion) {
        let mut committed = operation.target.clone();
        committed.completion = DhPairingCompletion::Committed;
        stage(
            PERSISTENCE_TIMEOUT,
            PublicFailure::new(
                "pair_record_commit_failed",
                "pair_record_persistence",
                true,
                "Unable to promote the authenticated provisional pair record.",
            ),
            persistence.persist(DhEventKind::PairRecordCommitted, committed),
        )
        .await?;
    }
    emitter.authenticated()?;

    if complete_pair_verify_discovery(&operation.mode, &emitter)? {
        return Ok(());
    }

    emitter.phase(DhConnectionPhase::OpeningTunnel, DhSessionState::Connected)?;
    let tunnel_port = stage(
        TUNNEL_TIMEOUT,
        PublicFailure::new(
            "tunnel_listener_failed",
            "tunnel_listener",
            true,
            "The target did not create a secure tunnel listener.",
        ),
        client.create_tcp_listener(),
    )
    .await?;
    if tunnel_port == 0 {
        return Err(PublicFailure::new(
            "tunnel_listener_invalid_port",
            "tunnel_listener",
            false,
            "The target returned an invalid tunnel listener.",
        ));
    }
    let tunnel_endpoint = operation.service.endpoint_with_port(tunnel_port);
    let tunnel_stream = stage(
        CONNECT_TIMEOUT,
        PublicFailure::new(
            "tunnel_connect_failed",
            "tls_psk_tunnel",
            true,
            "Unable to connect to the target's secure tunnel listener.",
        ),
        TcpStream::connect(tunnel_endpoint),
    )
    .await?;
    let tunnel = stage(
        TUNNEL_TIMEOUT,
        PublicFailure::new(
            "tls_psk_tunnel_failed",
            "tls_psk_tunnel",
            false,
            "The authenticated TLS-PSK tunnel failed.",
        ),
        connect_tls_psk_tunnel_native(tunnel_stream, client.encryption_key()),
    )
    .await?;
    let client_ip = parse_tunnel_ip(&tunnel.info.client_address)?;
    let server_ip = parse_tunnel_ip(&tunnel.info.server_address)?;
    if client_ip == server_ip || tunnel.info.mtu < MIN_IPV6_MTU || tunnel.info.server_rsd_port == 0
    {
        return Err(PublicFailure::new(
            "invalid_tunnel_parameters",
            "cd_tunnel",
            false,
            "The target returned invalid tunnel parameters.",
        ));
    }
    let maximum_segment_size = usize::from(tunnel.info.mtu)
        .checked_sub(TCP_OVERHEAD_BUDGET)
        .ok_or_else(|| {
            PublicFailure::new(
                "invalid_tunnel_mtu",
                "cd_tunnel",
                false,
                "The target returned an invalid tunnel MTU.",
            )
        })?;
    let rsd_port = tunnel.info.server_rsd_port;
    let raw_stream = tunnel.into_inner();
    let mut adapter = tcp::adapter::Adapter::new(Box::new(raw_stream), client_ip, server_ip);
    adapter.set_mss(maximum_segment_size);
    let mut adapter = adapter.to_async_handle();

    emitter.phase(
        DhConnectionPhase::DiscoveringServices,
        DhSessionState::Connected,
    )?;
    let rsd_stream = stage(
        RSD_TIMEOUT,
        PublicFailure::new(
            "rsd_connect_failed",
            "rsd_handshake",
            true,
            "Unable to connect through the userspace tunnel to RSD.",
        ),
        adapter.connect(rsd_port),
    )
    .await?;
    let mut handshake = stage(
        RSD_TIMEOUT,
        PublicFailure::new(
            "rsd_handshake_failed",
            "rsd_handshake",
            true,
            "The Remote Service Discovery handshake failed.",
        ),
        RsdHandshake::new(rsd_stream),
    )
    .await?;
    let snapshot = rsd_snapshot(&handshake, &operation.target)?;
    emitter.rsd_ready(snapshot)?;

    emitter.phase(
        DhConnectionPhase::PreparingDevice,
        DhSessionState::Connected,
    )?;
    let readiness = verify_developer_readiness(&mut adapter, &mut handshake).await?;

    match operation.mode {
        RemoteMode::Screenshot => {
            capture_screenshot(&readiness, &mut adapter, &mut handshake, &emitter).await?;
            stage(
                CONNECT_TIMEOUT,
                PublicFailure::new(
                    "tunnel_shutdown_failed",
                    "session_teardown",
                    true,
                    "Unable to close the userspace tunnel cleanly.",
                ),
                adapter.close(),
            )
            .await?;
            emitter.phase(DhConnectionPhase::Ready, DhSessionState::Completed)
        }
        RemoteMode::ControlStream => {
            let cancellation = cancellation.ok_or_else(|| {
                PublicFailure::new(
                    "invalid_state",
                    "control_stream",
                    false,
                    "A control stream requires an owned cancellation channel.",
                )
            })?;
            require_control_services(&handshake)?;
            capture_screenshot(&readiness, &mut adapter, &mut handshake, &emitter).await?;
            run_control_stream(
                &mut adapter,
                &mut handshake,
                &emitter,
                &media,
                controls,
                cancellation,
            )
            .await
        }
        RemoteMode::PairVerify => {
            unreachable!("Pair Verify-only sessions complete before tunnel creation")
        }
    }
}

/// Returns whether this native session owns durable M6 promotion.
///
/// Pair Verify-only discovery proves peer identity and leaves promotion to the
/// Swift persistence owner after the authenticated probe completes.
fn should_promote_provisional_record(mode: &RemoteMode, completion: DhPairingCompletion) -> bool {
    completion == DhPairingCompletion::Provisional && !matches!(mode, RemoteMode::PairVerify)
}

/// Completes the authenticated discovery probe before any tunnel work begins.
fn complete_pair_verify_discovery(
    mode: &RemoteMode,
    emitter: &EventEmitter,
) -> Result<bool, PublicFailure> {
    if !matches!(mode, RemoteMode::PairVerify) {
        return Ok(false);
    }
    emitter.phase(DhConnectionPhase::Ready, DhSessionState::Completed)?;
    Ok(true)
}

async fn capture_screenshot(
    readiness: &DeveloperReady,
    provider: &mut impl RsdProvider,
    handshake: &mut RsdHandshake,
    emitter: &EventEmitter,
) -> Result<(), PublicFailure> {
    emitter.phase(
        DhConnectionPhase::CapturingScreenshot,
        DhSessionState::Connected,
    )?;
    let mut screenshot_client = open_screenshot_service(readiness, provider, handshake).await?;
    let screenshot = stage(
        SCREENSHOT_TIMEOUT,
        PublicFailure::new(
            "screenshot_capture_failed",
            "screenshot",
            true,
            "The target did not return a screenshot.",
        ),
        screenshot_client.take_screenshot(None, ImageFormat::Png),
    )
    .await?;
    let dimensions = validate_png(&screenshot).map_err(|_| {
        PublicFailure::new(
            "invalid_screenshot_png",
            "screenshot",
            false,
            "The target returned an invalid PNG screenshot.",
        )
    })?;
    emitter.screenshot(screenshot, dimensions)
}

fn nonzero_video_ssrc(identifier: uuid::Uuid) -> u32 {
    let value = identifier.as_u128() as u32;
    value.max(1)
}

fn build_userspace_video_offer(
    call_id: &str,
    call_info: &CallInfoBlob,
    our_ssrc: u32,
) -> Result<Vec<u8>, PublicFailure> {
    if our_ssrc == 0 {
        return Err(media_start_failure());
    }
    build_screen_video_offer(call_id, call_info, our_ssrc).map_err(|_| media_start_failure())
}

async fn run_control_stream(
    adapter: &mut tcp::handle::AdapterHandle,
    handshake: &mut RsdHandshake,
    emitter: &EventEmitter,
    media: &MediaEmitter,
    mut controls: ControlGate,
    mut cancellation: tokio::sync::watch::Receiver<bool>,
) -> Result<(), PublicFailure> {
    require_control_services(handshake)?;
    emitter.phase(
        DhConnectionPhase::StartingDisplayStream,
        DhSessionState::Connected,
    )?;
    let mut display = stage(
        MEDIA_START_TIMEOUT,
        display_service_connection_failed(),
        DisplayServiceClient::connect_rsd(adapter, handshake),
    )
    .await?;
    let audio_udp = stage(
        MEDIA_START_TIMEOUT,
        media_start_failure(),
        adapter.bind_udp(0),
    )
    .await?;
    let video_udp = stage(
        MEDIA_START_TIMEOUT,
        media_start_failure(),
        adapter.bind_udp(0),
    )
    .await?;
    let receiver_ip = adapter.host_ip().to_string();
    let sender_ip = adapter.peer_ip().to_string();
    let call_info = CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    };
    let client_session_id = uuid::Uuid::new_v4();
    let audio_call_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let audio_offer =
        build_screen_audio_offer(&audio_call_id, &call_info).map_err(|_| media_start_failure())?;
    let audio_parameters = build_start_audio_parameters(
        &receiver_ip,
        audio_udp.local_port(),
        &sender_ip,
        AUDIO_SENDER_PORT,
        audio_offer,
        CLIENT_SUPPORTED_FEATURES,
        client_session_id,
    );
    stage(
        MEDIA_START_TIMEOUT,
        media_start_failure(),
        display.start_media_stream(audio_parameters),
    )
    .await?;

    let video_call_id = uuid::Uuid::new_v4().to_string().to_uppercase();
    let our_video_ssrc = nonzero_video_ssrc(uuid::Uuid::new_v4());
    let video_negotiator_offer =
        build_userspace_video_offer(&video_call_id, &call_info, our_video_ssrc)?;
    let video_parameters = build_start_video_parameters(
        &receiver_ip,
        video_udp.local_port(),
        &sender_ip,
        VIDEO_SENDER_PORT,
        video_negotiator_offer,
        CLIENT_SUPPORTED_FEATURES,
        PRIMARY_DISPLAY_ID,
        client_session_id,
    );
    let response = stage(
        MEDIA_START_TIMEOUT,
        video_negotiation_rejected(),
        display.start_media_stream(video_parameters),
    )
    .await?;
    let answer = extract_negotiator_answer(&response)?;
    let negotiated_video = parse_negotiated_video(&answer)?;

    emitter.phase(DhConnectionPhase::OpeningInput, DhSessionState::Connected)?;
    let mut universal_hid = stage(
        INPUT_TIMEOUT,
        input_service_connection_failed(),
        UniversalHidServiceClient::connect_rsd(adapter, handshake),
    )
    .await?;
    let mut indigo_hid = stage(
        INPUT_TIMEOUT,
        input_service_connection_failed(),
        IndigoHidClient::connect_rsd(adapter, handshake),
    )
    .await?;
    let mut orientation = stage(
        INPUT_TIMEOUT,
        orientation_service_connection_failed(),
        OrientationServiceClient::connect_rsd(adapter, handshake),
    )
    .await?;
    let initial_orientation = stage(
        INPUT_TIMEOUT,
        orientation_state_failed(),
        orientation.current_orientation(),
    )
    .await?;
    let keyboard_service_id = stage(
        INPUT_TIMEOUT,
        input_service_connection_failed(),
        universal_hid.create_keyboard_service(&KeyboardServiceConfiguration::default()),
    )
    .await?;
    tokio::time::sleep(Duration::from_millis(300)).await;
    controls.enable_input();
    emitter.input_ready()?;
    emitter.phase(DhConnectionPhase::Streaming, DhSessionState::Connected)?;

    let mut video = LiveVideoState {
        assembler: HevcAccessUnitAssembler::new(
            negotiated_video.payload_type,
            negotiated_video.ssrc,
        ),
        last_configuration_revision: 0,
        geometry: DhDisplayGeometry {
            pixel_width: 0,
            pixel_height: 0,
            orientation: DhOrientation::Unknown as u32,
            non_flat_orientation: DhOrientation::Unknown as u32,
            orientation_locked: 0,
            reserved: [0; 7],
        },
    };
    update_geometry_orientation(&mut video.geometry, &initial_orientation)?;
    let _audio_udp = audio_udp;
    let _display = display;
    let mut cleanup = InputCleanupState::default();
    let first_video_frame_deadline = tokio::time::sleep(FIRST_VIDEO_FRAME_TIMEOUT);
    tokio::pin!(first_video_frame_deadline);
    let mut has_emitted_video_access_unit = false;
    let feedback_started_at = tokio::time::Instant::now();
    let mut feedback_timer = tokio::time::interval_at(
        feedback_started_at + VIDEO_FEEDBACK_INTERVAL,
        VIDEO_FEEDBACK_INTERVAL,
    );
    feedback_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut feedback =
        VideoFeedbackState::new(our_video_ssrc, negotiated_video.ssrc, video_call_id);

    let result = 'stream: loop {
        tokio::select! {
            biased;
            changed = cancellation.changed() => {
                let _ = changed;
                break Ok(());
            }
            datagram = video_udp.recv() => {
                match datagram {
                    Ok(datagram) => {
                        match process_live_video_datagram(
                            datagram.data,
                            datagram.source_port,
                            &mut video,
                            &mut orientation,
                            media,
                            emitter,
                        ).await {
                            Ok(outcome) => {
                                has_emitted_video_access_unit |= outcome.emitted_access_unit;
                                for feedback_datagram in feedback.consume(&outcome) {
                                    if video_udp
                                        .send_to(VIDEO_SENDER_PORT, feedback_datagram)
                                        .await
                                        .is_err()
                                    {
                                        break 'stream Err(video_control_delivery_failed());
                                    }
                                }
                            }
                            Err(failure) => break Err(failure),
                        }
                    }
                    Err(_) => {
                        break Err(PublicFailure::new(
                            "video_stream_receive_failed",
                            "video_stream",
                            true,
                            "The authenticated video datagram stream closed unexpectedly.",
                        ));
                    }
                }
            }
            _ = feedback_timer.tick() => {
                if let Some(report) = feedback.periodic_report(
                    feedback_started_at.elapsed(),
                ) {
                    if video_udp.send_to(VIDEO_SENDER_PORT, report).await.is_err() {
                        break Err(video_control_delivery_failed());
                    }
                }
            }
            () = &mut first_video_frame_deadline, if !has_emitted_video_access_unit => {
                break Err(PublicFailure::new(
                    "video_stream_start_timed_out",
                    "video_stream",
                    true,
                    "The authenticated display stream did not produce a complete video frame in time.",
                ));
            }
            command = controls.receive() => {
                let Some(command) = command else {
                    break Err(PublicFailure::new(
                        "control_channel_closed",
                        "control_stream",
                        false,
                        "The native control channel closed unexpectedly.",
                    ));
                };
                let trace_label = input_trace_label(&command);
                if let Err(failure) = handle_control_command(
                        command,
                        &video_udp,
                        VIDEO_SENDER_PORT,
                        &mut universal_hid,
                        keyboard_service_id,
                        &mut indigo_hid,
                        &mut orientation,
                        &mut cleanup,
                    )
                    .await
                {
                    break Err(failure);
                }
                if let Some(trace_label) = trace_label {
                    input_trace("delivered", &trace_label);
                }
            }
        }
    };

    cleanup_inputs(
        &mut cleanup,
        &mut universal_hid,
        keyboard_service_id,
        &mut indigo_hid,
    )
    .await;
    result
}

fn input_trace_label(command: &ControlCommand) -> Option<String> {
    match command {
        ControlCommand::Touch(TouchIntent::Tap { .. }) => Some("touch_tap".into()),
        ControlCommand::Touch(_) => Some("touch_edge".into()),
        ControlCommand::Keyboard(KeyboardIntent::Tap { .. }) => Some("keyboard_tap".into()),
        ControlCommand::Keyboard(_) => Some("keyboard_edge".into()),
        ControlCommand::HardwareButton(intent) => Some(
            match intent.button {
                DhHardwareButton::Home => "button_home",
                DhHardwareButton::Lock => "button_lock",
                DhHardwareButton::VolumeUp => "button_volume_up",
                DhHardwareButton::VolumeDown => "button_volume_down",
                DhHardwareButton::Mute => "button_mute",
                DhHardwareButton::Siri => "button_siri",
            }
            .into(),
        ),
        ControlCommand::Rotate(_) => Some("rotation".into()),
        ControlCommand::ReleaseAllInput => Some("release_all".into()),
        ControlCommand::VideoNegotiation | ControlCommand::VideoControlDatagram(_) => None,
    }
}

fn input_trace(outcome: &str, label: &str) {
    if std::env::var_os("DEVICE_HUB_BOOTSTRAP_TRACE").as_deref() == Some(std::ffi::OsStr::new("1"))
    {
        eprintln!("devicehub.rust input_{outcome} kind={label}");
    }
}

fn require_control_services(handshake: &RsdHandshake) -> Result<(), PublicFailure> {
    for service_name in [
        DISPLAY_SERVICE,
        UNIVERSAL_HID_SERVICE,
        INDIGO_HID_SERVICE,
        ORIENTATION_SERVICE,
    ] {
        require_prepared_service(handshake, service_name)?;
    }
    Ok(())
}

/// Successfully delivered held-input state that must be balanced before the
/// authenticated input services are released.
#[derive(Default)]
struct InputCleanupState {
    touch_active: bool,
    pressed_keys: BTreeMap<u16, u8>,
    pressed_buttons: Vec<HardwareButton>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InputReleaseAction {
    Touch,
    Keyboard,
    HardwareButton(HardwareButton),
}

impl InputCleanupState {
    fn release_plan(&self) -> Vec<InputReleaseAction> {
        let mut plan = Vec::with_capacity(2 + self.pressed_buttons.len());
        if self.touch_active {
            plan.push(InputReleaseAction::Touch);
        }
        if !self.pressed_keys.is_empty() {
            plan.push(InputReleaseAction::Keyboard);
        }
        plan.extend(
            self.pressed_buttons
                .iter()
                .rev()
                .copied()
                .map(InputReleaseAction::HardwareButton),
        );
        plan
    }

    fn did_release(&mut self, action: InputReleaseAction) {
        match action {
            InputReleaseAction::Touch => self.touch_active = false,
            InputReleaseAction::Keyboard => self.pressed_keys.clear(),
            InputReleaseAction::HardwareButton(button) => {
                if let Some(index) = self
                    .pressed_buttons
                    .iter()
                    .rposition(|candidate| *candidate == button)
                {
                    self.pressed_buttons.remove(index);
                }
            }
        }
    }
}

trait InputReleaseSink {
    async fn release(&mut self, action: InputReleaseAction) -> Result<(), HidError>;
}

struct HidInputReleaseSink<'a> {
    universal_hid: &'a mut UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>,
    keyboard_service_id: u64,
    indigo_hid: &'a mut IndigoHidClient<Box<dyn idevice::ReadWrite>>,
}

impl InputReleaseSink for HidInputReleaseSink<'_> {
    async fn release(&mut self, action: InputReleaseAction) -> Result<(), HidError> {
        match action {
            InputReleaseAction::Touch => {
                self.universal_hid
                    .send_touch(TouchEvent::Cancel, None)
                    .await
            }
            InputReleaseAction::Keyboard => {
                self.universal_hid
                    .cancel_keyboard(self.keyboard_service_id, None)
                    .await
            }
            InputReleaseAction::HardwareButton(button) => {
                self.indigo_hid
                    .send_hardware_button(button, ButtonState::Canceled)
                    .await
            }
        }
    }
}

async fn cleanup_inputs(
    cleanup: &mut InputCleanupState,
    universal_hid: &mut UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>,
    keyboard_service_id: u64,
    indigo_hid: &mut IndigoHidClient<Box<dyn idevice::ReadWrite>>,
) {
    let _ =
        release_all_inputs_bounded(cleanup, universal_hid, keyboard_service_id, indigo_hid).await;
}

async fn release_all_inputs_bounded(
    cleanup: &mut InputCleanupState,
    universal_hid: &mut UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>,
    keyboard_service_id: u64,
    indigo_hid: &mut IndigoHidClient<Box<dyn idevice::ReadWrite>>,
) -> Result<(), PublicFailure> {
    tokio::time::timeout(
        INPUT_CLEANUP_TIMEOUT,
        release_all_inputs(cleanup, universal_hid, keyboard_service_id, indigo_hid),
    )
    .await
    .map_err(|_| {
        PublicFailure::new(
            "input_cleanup_timeout",
            "input_cleanup",
            true,
            "Releasing native held input exceeded the bounded cleanup window.",
        )
    })?
}

async fn release_all_inputs(
    cleanup: &mut InputCleanupState,
    universal_hid: &mut UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>,
    keyboard_service_id: u64,
    indigo_hid: &mut IndigoHidClient<Box<dyn idevice::ReadWrite>>,
) -> Result<(), PublicFailure> {
    let mut sink = HidInputReleaseSink {
        universal_hid,
        keyboard_service_id,
        indigo_hid,
    };
    release_all_inputs_with_sink(cleanup, &mut sink).await
}

async fn release_all_inputs_with_sink(
    cleanup: &mut InputCleanupState,
    sink: &mut impl InputReleaseSink,
) -> Result<(), PublicFailure> {
    let mut first_failure = None;
    for action in cleanup.release_plan() {
        match sink.release(action).await {
            Ok(()) => cleanup.did_release(action),
            Err(error) => {
                if first_failure.is_none() {
                    first_failure = Some(classify_hid_error(error, "input_cleanup"));
                }
            }
        }
    }
    match first_failure {
        Some(failure) => Err(failure),
        None => Ok(()),
    }
}

trait KeyboardStateSink {
    async fn replace(&mut self, pressed: BTreeSet<KeyboardUsage>) -> Result<(), HidError>;
}

struct HidKeyboardStateSink<'a> {
    universal_hid: &'a mut UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>,
    keyboard_service_id: u64,
}

impl KeyboardStateSink for HidKeyboardStateSink<'_> {
    async fn replace(&mut self, pressed: BTreeSet<KeyboardUsage>) -> Result<(), HidError> {
        self.universal_hid
            .set_keyboard_usages(self.keyboard_service_id, pressed, None)
            .await
    }
}

fn keyboard_usages(
    pressed_keys: &BTreeMap<u16, u8>,
) -> Result<BTreeSet<KeyboardUsage>, PublicFailure> {
    let mut usages = BTreeSet::new();
    for (&usage, &modifiers) in pressed_keys {
        usages.insert(
            KeyboardUsage::new(usage)
                .map_err(|error| classify_hid_error(error.into(), "keyboard_input"))?,
        );
        for bit in 0..8 {
            if modifiers & (1 << bit) != 0 {
                usages.insert(
                    KeyboardUsage::new(0xE0 + bit)
                        .map_err(|error| classify_hid_error(error.into(), "keyboard_input"))?,
                );
            }
        }
    }
    Ok(usages)
}

async fn handle_keyboard_intent_with_sink(
    intent: KeyboardIntent,
    cleanup: &mut InputCleanupState,
    sink: &mut impl KeyboardStateSink,
) -> Result<(), PublicFailure> {
    let previous = cleanup.pressed_keys.clone();
    let mut next = previous.clone();
    match intent {
        KeyboardIntent::Down { usage, modifiers } => {
            if next.insert(usage, modifiers).is_some() {
                return Err(invalid_keyboard_transition());
            }
            sink.replace(keyboard_usages(&next)?)
                .await
                .map_err(|error| classify_hid_error(error, "keyboard_input"))?;
            cleanup.pressed_keys = next;
        }
        KeyboardIntent::Up { usage, modifiers } => {
            if next.get(&usage) != Some(&modifiers) {
                return Err(invalid_keyboard_transition());
            }
            next.remove(&usage);
            sink.replace(keyboard_usages(&next)?)
                .await
                .map_err(|error| classify_hid_error(error, "keyboard_input"))?;
            cleanup.pressed_keys = next;
        }
        KeyboardIntent::CancelAll => {
            sink.replace(BTreeSet::new())
                .await
                .map_err(|error| classify_hid_error(error, "keyboard_input"))?;
            cleanup.pressed_keys.clear();
        }
        KeyboardIntent::Tap { usage, modifiers } => {
            if next.insert(usage, modifiers).is_some() {
                return Err(invalid_keyboard_transition());
            }
            sink.replace(keyboard_usages(&next)?)
                .await
                .map_err(|error| classify_hid_error(error, "keyboard_input"))?;
            cleanup.pressed_keys = next;
            tokio::time::sleep(INPUT_TAP_HOLD).await;
            sink.replace(keyboard_usages(&previous)?)
                .await
                .map_err(|error| classify_hid_error(error, "keyboard_input"))?;
            cleanup.pressed_keys = previous;
        }
    }
    Ok(())
}

trait HardwareButtonSink {
    async fn send(&mut self, button: HardwareButton, state: ButtonState) -> Result<(), HidError>;
}

/// Returns the minimum press duration iOS requires for a semantic button tap.
///
/// The side and Siri buttons intentionally distinguish a press-and-hold from
/// the shorter debounce-safe tap used by Home and media controls.
fn hardware_button_tap_hold(button: HardwareButton) -> Duration {
    match button {
        HardwareButton::Lock => LOCK_BUTTON_HOLD,
        HardwareButton::Siri => SIRI_BUTTON_HOLD,
        HardwareButton::Home
        | HardwareButton::VolumeUp
        | HardwareButton::VolumeDown
        | HardwareButton::Mute => INPUT_TAP_HOLD,
    }
}

impl HardwareButtonSink for IndigoHidClient<Box<dyn idevice::ReadWrite>> {
    async fn send(&mut self, button: HardwareButton, state: ButtonState) -> Result<(), HidError> {
        self.send_hardware_button(button, state).await
    }
}

async fn handle_hardware_button_with_sink(
    intent: crate::model::HardwareButtonIntent,
    cleanup: &mut InputCleanupState,
    sink: &mut impl HardwareButtonSink,
) -> Result<(), PublicFailure> {
    let button = match intent.button {
        DhHardwareButton::Home => HardwareButton::Home,
        DhHardwareButton::Lock => HardwareButton::Lock,
        DhHardwareButton::VolumeUp => HardwareButton::VolumeUp,
        DhHardwareButton::VolumeDown => HardwareButton::VolumeDown,
        DhHardwareButton::Mute => HardwareButton::Mute,
        DhHardwareButton::Siri => HardwareButton::Siri,
    };
    match intent.phase {
        DhButtonPhase::Down => {
            sink.send(button, ButtonState::Down)
                .await
                .map_err(|error| classify_hid_error(error, "hardware_button_input"))?;
            cleanup.pressed_buttons.push(button);
        }
        DhButtonPhase::Up | DhButtonPhase::Cancel => {
            let state = if intent.phase == DhButtonPhase::Up {
                ButtonState::Up
            } else {
                ButtonState::Canceled
            };
            sink.send(button, state)
                .await
                .map_err(|error| classify_hid_error(error, "hardware_button_input"))?;
            remove_last_button(&mut cleanup.pressed_buttons, button);
        }
        DhButtonPhase::Tap => {
            sink.send(button, ButtonState::Down)
                .await
                .map_err(|error| classify_hid_error(error, "hardware_button_input"))?;
            cleanup.pressed_buttons.push(button);
            tokio::time::sleep(hardware_button_tap_hold(button)).await;
            sink.send(button, ButtonState::Up)
                .await
                .map_err(|error| classify_hid_error(error, "hardware_button_input"))?;
            remove_last_button(&mut cleanup.pressed_buttons, button);
        }
    }
    Ok(())
}

fn remove_last_button(buttons: &mut Vec<HardwareButton>, button: HardwareButton) {
    if let Some(index) = buttons.iter().rposition(|candidate| *candidate == button) {
        buttons.remove(index);
    }
}

#[allow(clippy::too_many_arguments)]
async fn handle_control_command(
    command: ControlCommand,
    video_udp: &tcp::handle::UdpSocketHandle,
    remote_video_port: u16,
    universal_hid: &mut UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>,
    keyboard_service_id: u64,
    indigo_hid: &mut IndigoHidClient<Box<dyn idevice::ReadWrite>>,
    orientation: &mut OrientationServiceClient<Box<dyn idevice::ReadWrite>>,
    cleanup: &mut InputCleanupState,
) -> Result<(), PublicFailure> {
    match command {
        ControlCommand::VideoControlDatagram(datagram) => video_udp
            .send_to(remote_video_port, datagram.bytes)
            .await
            .map_err(|_| video_control_delivery_failed()),
        ControlCommand::Touch(intent) => {
            match intent {
                TouchIntent::Tap { x, y } => {
                    // Pessimistically mark active before the compound operation
                    // so a failed release is balanced by teardown.
                    cleanup.touch_active = true;
                    universal_hid
                        .tap(x, y)
                        .await
                        .map_err(|error| classify_hid_error(error, "touch_input"))?;
                    cleanup.touch_active = false;
                }
                TouchIntent::Down { x, y } => {
                    universal_hid
                        .send_touch(TouchEvent::Down(TouchPoint::new(x, y)), None)
                        .await
                        .map_err(|error| classify_hid_error(error, "touch_input"))?;
                    cleanup.touch_active = true;
                }
                TouchIntent::Move { x, y } => {
                    universal_hid
                        .send_touch(TouchEvent::Move(TouchPoint::new(x, y)), None)
                        .await
                        .map_err(|error| classify_hid_error(error, "touch_input"))?;
                }
                TouchIntent::Up { x, y } => {
                    universal_hid
                        .send_touch(TouchEvent::Up(TouchPoint::new(x, y)), None)
                        .await
                        .map_err(|error| classify_hid_error(error, "touch_input"))?;
                    cleanup.touch_active = false;
                }
                TouchIntent::Cancel => {
                    universal_hid
                        .send_touch(TouchEvent::Cancel, None)
                        .await
                        .map_err(|error| classify_hid_error(error, "touch_input"))?;
                    cleanup.touch_active = false;
                }
            }
            Ok(())
        }
        ControlCommand::Keyboard(intent) => {
            let mut sink = HidKeyboardStateSink {
                universal_hid,
                keyboard_service_id,
            };
            handle_keyboard_intent_with_sink(intent, cleanup, &mut sink).await
        }
        ControlCommand::HardwareButton(intent) => {
            handle_hardware_button_with_sink(intent, cleanup, indigo_hid).await
        }
        ControlCommand::Rotate(intent) => {
            let direction = match intent {
                RotationIntent::Left => RotationDirection::Left,
                RotationIntent::Right => RotationDirection::Right,
            };
            orientation.rotate(direction).await.map_err(|_| {
                PublicFailure::new(
                    "rotation_failed",
                    "rotation",
                    true,
                    "The authenticated orientation service rejected the rotation.",
                )
            })?;
            // A successful control reply does not prove that the encoded
            // display changed. The next video configuration owns geometry.
            Ok(())
        }
        ControlCommand::ReleaseAllInput => {
            release_all_inputs_bounded(cleanup, universal_hid, keyboard_service_id, indigo_hid)
                .await
        }
        ControlCommand::VideoNegotiation => Err(PublicFailure::new(
            "stale_video_negotiation",
            "video_negotiation",
            false,
            "A duplicate video negotiation acknowledgement was received.",
        )),
    }
}

struct PreparedVideoDatagram {
    events: Vec<HevcDepacketizerEvent>,
    sequence_number: Option<u16>,
}

impl PreparedVideoDatagram {
    fn has_new_configuration(&self, last_configuration_revision: u64) -> bool {
        self.events.iter().any(|event| {
            matches!(
                event,
                HevcDepacketizerEvent::AccessUnit(access_unit)
                    if access_unit.parameter_set_revision > last_configuration_revision
            )
        })
    }
}

/// Mutable state that must advance atomically across live video datagrams.
struct LiveVideoState {
    assembler: HevcAccessUnitAssembler,
    last_configuration_revision: u64,
    geometry: DhDisplayGeometry,
}

#[derive(Default)]
struct VideoDatagramOutcome {
    completed_frame_timestamps: Vec<u32>,
    emitted_access_unit: bool,
    highest_sequence_number: Option<u16>,
    requires_keyframe: bool,
}

/// Complete receiver-side feedback state for one negotiated video stream.
///
/// The sender and receiver SSRCs have different ownership: `our_ssrc` is
/// declared in our offer and identifies feedback, while `media_ssrc` comes from
/// the authenticated answer and identifies the device encoder.
struct VideoFeedbackState {
    base_sequence_number: Option<u16>,
    cname: String,
    fir_sequence_number: u8,
    frame_count: u16,
    highest_extended_sequence_number: u32,
    media_ssrc: u32,
    our_ssrc: u32,
}

impl VideoFeedbackState {
    fn new(our_ssrc: u32, media_ssrc: u32, cname: String) -> Self {
        Self {
            base_sequence_number: None,
            cname,
            fir_sequence_number: 0,
            frame_count: 0,
            highest_extended_sequence_number: 0,
            media_ssrc,
            our_ssrc,
        }
    }

    fn consume(&mut self, outcome: &VideoDatagramOutcome) -> Vec<Vec<u8>> {
        if let Some(sequence_number) = outcome.highest_sequence_number {
            self.observe_sequence_number(sequence_number);
        }

        let mut datagrams = Vec::with_capacity(
            outcome.completed_frame_timestamps.len() + usize::from(outcome.requires_keyframe),
        );
        for timestamp in &outcome.completed_frame_timestamps {
            self.frame_count = self.frame_count.wrapping_add(1);
            datagrams.push(build_frame_ack(self.our_ssrc, *timestamp));
        }
        if outcome.requires_keyframe {
            datagrams.push(build_keyframe_request(
                self.our_ssrc,
                &self.cname,
                self.media_ssrc,
                &[],
                self.fir_sequence_number,
            ));
            self.fir_sequence_number = self.fir_sequence_number.wrapping_add(1);
        }
        datagrams
    }

    fn periodic_report(&self, elapsed: Duration) -> Option<Vec<u8>> {
        self.base_sequence_number?;
        let clock_ms = (elapsed.as_millis() & u128::from(u16::MAX)) as u16;
        Some(build_rctl(
            self.our_ssrc,
            clock_ms,
            self.frame_count,
            self.highest_extended_sequence_number as u16,
        ))
    }

    fn observe_sequence_number(&mut self, sequence_number: u16) {
        let Some(base) = self.base_sequence_number else {
            self.base_sequence_number = Some(sequence_number);
            self.highest_extended_sequence_number = 0;
            return;
        };
        let current = base.wrapping_add(self.highest_extended_sequence_number as u16);
        let forward = sequence_number.wrapping_sub(current);
        if forward != 0 && forward < 0x8000 {
            self.highest_extended_sequence_number = self
                .highest_extended_sequence_number
                .wrapping_add(u32::from(forward));
        }
    }
}

async fn process_live_video_datagram(
    bytes: Vec<u8>,
    source_port: u16,
    video: &mut LiveVideoState,
    orientation: &mut OrientationServiceClient<Box<dyn idevice::ReadWrite>>,
    media: &MediaEmitter,
    emitter: &EventEmitter,
) -> Result<VideoDatagramOutcome, PublicFailure> {
    let Some(prepared) = prepare_video_datagram(
        bytes,
        source_port,
        &mut video.assembler,
        &mut video.last_configuration_revision,
        media,
    )?
    else {
        return Ok(VideoDatagramOutcome::default());
    };
    let authoritative_orientation =
        if prepared.has_new_configuration(video.last_configuration_revision) {
            Some(
                stage(
                    INPUT_TIMEOUT,
                    orientation_state_failed(),
                    orientation.current_orientation(),
                )
                .await?,
            )
        } else {
            None
        };
    emit_prepared_video_datagram(
        prepared,
        &video.assembler,
        &mut video.last_configuration_revision,
        &mut video.geometry,
        authoritative_orientation.as_ref(),
        media,
        emitter,
    )
}

fn prepare_video_datagram(
    bytes: Vec<u8>,
    _source_port: u16,
    assembler: &mut HevcAccessUnitAssembler,
    _last_configuration_revision: &mut u64,
    _media: &MediaEmitter,
) -> Result<Option<PreparedVideoDatagram>, PublicFailure> {
    let (events, sequence_number) = if is_rtcp(&bytes) {
        return Ok(None);
    } else {
        match RtpPacket::parse_checked(&bytes) {
            Ok(packet) => {
                let sequence_number = packet.sequence_number;
                (assembler.push_packet(&packet), Some(sequence_number))
            }
            Err(_) => {
                assembler.mark_stream_discontinuity();
                (
                    vec![HevcDepacketizerEvent::Discontinuity(
                        HevcDiscontinuity::MalformedPayload,
                    )],
                    None,
                )
            }
        }
    };
    if events.iter().any(|event| {
        matches!(
            event,
            HevcDepacketizerEvent::PacketRejected(HevcPacketRejection::UnexpectedPayloadType)
        )
    }) {
        return Err(PublicFailure::new(
            "video_datagram_rejected",
            "video_stream_payload_invalid",
            false,
            "The authenticated display stream used an unexpected RTP payload type.",
        ));
    }
    if events.iter().any(|event| {
        matches!(
            event,
            HevcDepacketizerEvent::PacketRejected(HevcPacketRejection::UnexpectedSource)
        )
    }) {
        return Err(PublicFailure::new(
            "video_datagram_rejected",
            "video_stream_ssrc_mismatch",
            false,
            "The authenticated display stream used an unexpected RTP sender identity.",
        ));
    }
    Ok(Some(PreparedVideoDatagram {
        events,
        sequence_number,
    }))
}

fn emit_prepared_video_datagram(
    prepared: PreparedVideoDatagram,
    assembler: &HevcAccessUnitAssembler,
    last_configuration_revision: &mut u64,
    geometry: &mut DhDisplayGeometry,
    authoritative_orientation: Option<&OrientationState>,
    media: &MediaEmitter,
    emitter: &EventEmitter,
) -> Result<VideoDatagramOutcome, PublicFailure> {
    let mut outcome = VideoDatagramOutcome {
        highest_sequence_number: prepared.sequence_number,
        ..Default::default()
    };
    for event in prepared.events {
        match event {
            HevcDepacketizerEvent::AccessUnit(access_unit) => {
                let rtp_timestamp = access_unit.rtp_timestamp;
                if access_unit.parameter_set_revision > *last_configuration_revision {
                    let orientation =
                        authoritative_orientation.ok_or_else(orientation_state_failed)?;
                    update_geometry_orientation(geometry, orientation)?;
                    let configuration = assembler.parameter_sets().ok_or_else(|| {
                        PublicFailure::new(
                            "video_configuration_missing",
                            "video_stream",
                            false,
                            "A complete access unit referenced unavailable HEVC configuration.",
                        )
                    })?;
                    *last_configuration_revision = configuration.revision;
                    geometry.pixel_width = configuration.pixel_width;
                    geometry.pixel_height = configuration.pixel_height;
                    let concrete_orientation = concrete_orientation_from_raw(geometry.orientation)?;
                    media.video_configuration(configuration, concrete_orientation)?;
                    emit_display_geometry_if_complete(emitter, *geometry)?;
                }
                media.video_access_unit(access_unit, *geometry)?;
                outcome.completed_frame_timestamps.push(rtp_timestamp);
                outcome.emitted_access_unit = true;
            }
            HevcDepacketizerEvent::Discontinuity(discontinuity) => {
                emit_video_discontinuity(
                    last_configuration_revision,
                    media,
                    map_discontinuity(discontinuity),
                )?;
                outcome.requires_keyframe = true;
            }
            HevcDepacketizerEvent::PacketRejected(_) => {
                unreachable!("unexpected stream packets return before either media consumer")
            }
        }
    }
    Ok(outcome)
}

#[cfg(test)]
fn process_video_datagram(
    bytes: Vec<u8>,
    source_port: u16,
    assembler: &mut HevcAccessUnitAssembler,
    last_configuration_revision: &mut u64,
    geometry: &mut DhDisplayGeometry,
    media: &MediaEmitter,
    emitter: &EventEmitter,
) -> Result<bool, PublicFailure> {
    let Some(prepared) = prepare_video_datagram(
        bytes,
        source_port,
        assembler,
        last_configuration_revision,
        media,
    )?
    else {
        return Ok(false);
    };
    let orientation = prepared
        .has_new_configuration(*last_configuration_revision)
        .then(|| test_orientation_state(*geometry))
        .transpose()?;
    Ok(emit_prepared_video_datagram(
        prepared,
        assembler,
        last_configuration_revision,
        geometry,
        orientation.as_ref(),
        media,
        emitter,
    )?
    .emitted_access_unit)
}

#[cfg(test)]
fn test_orientation_state(geometry: DhDisplayGeometry) -> Result<OrientationState, PublicFailure> {
    let orientation = test_device_orientation(geometry.orientation)?;
    let non_flat_orientation = test_device_orientation(geometry.non_flat_orientation)?;
    Ok(OrientationState {
        orientation,
        non_flat_orientation,
        locked: geometry.orientation_locked == 1,
    })
}

#[cfg(test)]
fn test_device_orientation(raw: u32) -> Result<Orientation, PublicFailure> {
    match orientation_from_raw(raw) {
        DhOrientation::Portrait => Ok(Orientation::Portrait),
        DhOrientation::PortraitUpsideDown => Ok(Orientation::PortraitUpsideDown),
        DhOrientation::LandscapeLeft => Ok(Orientation::LandscapeLeft),
        DhOrientation::LandscapeRight => Ok(Orientation::LandscapeRight),
        _ => Err(unsupported_orientation()),
    }
}

fn update_geometry_orientation(
    geometry: &mut DhDisplayGeometry,
    state: &OrientationState,
) -> Result<(), PublicFailure> {
    geometry.orientation =
        effective_orientation(&state.orientation, &state.non_flat_orientation)? as u32;
    geometry.non_flat_orientation = orientation_value(&state.non_flat_orientation) as u32;
    geometry.orientation_locked = u8::from(state.locked);
    Ok(())
}

/// Publishes only geometry that is usable for coordinate mapping.
fn emit_display_geometry_if_complete(
    emitter: &EventEmitter,
    geometry: DhDisplayGeometry,
) -> Result<(), PublicFailure> {
    if geometry.pixel_width == 0 || geometry.pixel_height == 0 {
        return Ok(());
    }
    emitter.display_geometry(geometry)
}

/// Invalidates the consumer's decoder epoch before publishing a discontinuity.
fn emit_video_discontinuity(
    last_configuration_revision: &mut u64,
    media: &MediaEmitter,
    discontinuity: DhVideoDiscontinuity,
) -> Result<(), PublicFailure> {
    *last_configuration_revision = 0;
    media.video_discontinuity(discontinuity)
}

fn extract_negotiator_answer(response: &plist::Value) -> Result<Vec<u8>, PublicFailure> {
    fn collect(value: &plist::Value, depth: usize, answers: &mut Vec<Vec<u8>>) {
        if depth > 4 {
            return;
        }
        match value {
            plist::Value::Dictionary(dictionary) => {
                if let Some(plist::Value::Data(answer)) = dictionary.get("negotiatorAnswer") {
                    answers.push(answer.clone());
                }
                for child in dictionary.values() {
                    collect(child, depth + 1, answers);
                }
            }
            plist::Value::Array(array) => {
                for child in array {
                    collect(child, depth + 1, answers);
                }
            }
            _ => {}
        }
    }

    let mut answers = Vec::new();
    collect(response, 0, &mut answers);
    if answers.len() != 1 || answers[0].is_empty() || answers[0].len() > MAX_NEGOTIATOR_ANSWER_BYTES
    {
        return Err(unsupported_video_answer_extraction());
    }
    Ok(answers.remove(0))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct NegotiatedVideo {
    payload_type: u8,
    ssrc: u32,
}

fn parse_negotiated_video(answer: &[u8]) -> Result<NegotiatedVideo, PublicFailure> {
    let stream = parse_screen_video_answer(answer).map_err(screen_video_answer_failure)?;
    Ok(NegotiatedVideo {
        payload_type: stream.payload_type,
        ssrc: stream.ssrc,
    })
}

const fn screen_video_answer_failure(error: ScreenVideoAnswerError) -> PublicFailure {
    match error {
        ScreenVideoAnswerError::InvalidEnvelope
        | ScreenVideoAnswerError::MediaBlobMissing
        | ScreenVideoAnswerError::MediaBlobInvalid
        | ScreenVideoAnswerError::MediaBlobTooLarge => unsupported_video_negotiation(
            "video_answer_parse",
            "The display service returned an invalid screen negotiation answer.",
        ),
        ScreenVideoAnswerError::VideoGroupMissing => unsupported_video_negotiation(
            "video_stream_group_missing",
            "The display service did not declare a screen video group.",
        ),
        ScreenVideoAnswerError::HevcPayloadMissing | ScreenVideoAnswerError::PayloadTypeMissing => {
            unsupported_video_negotiation(
                "video_stream_payload_missing",
                "The display service did not declare an HEVC payload type.",
            )
        }
        ScreenVideoAnswerError::PayloadTypeInvalid => unsupported_video_negotiation(
            "video_stream_payload_invalid",
            "The display service declared an invalid HEVC payload type.",
        ),
        ScreenVideoAnswerError::PayloadEncrypted => unsupported_video_negotiation(
            "video_stream_payload_encrypted",
            "The display service requires unsupported encrypted video.",
        ),
        ScreenVideoAnswerError::SsrcMissing => unsupported_video_negotiation(
            "video_stream_ssrc_missing",
            "The display service did not declare the video sender identity.",
        ),
        ScreenVideoAnswerError::SsrcZero => unsupported_video_negotiation(
            "video_stream_ssrc_zero",
            "The display service declared a zero video sender identity.",
        ),
        ScreenVideoAnswerError::SsrcInvalid => unsupported_video_negotiation(
            "video_stream_ssrc_invalid",
            "The display service declared an invalid video sender identity.",
        ),
        ScreenVideoAnswerError::AmbiguousStream => unsupported_video_negotiation(
            "video_stream_selection_ambiguous",
            "The display service declared multiple HEVC sender identities.",
        ),
    }
}

const fn map_discontinuity(discontinuity: HevcDiscontinuity) -> DhVideoDiscontinuity {
    match discontinuity {
        HevcDiscontinuity::SequenceGap => DhVideoDiscontinuity::SequenceGap,
        HevcDiscontinuity::TimestampChangedWithoutMarker => {
            DhVideoDiscontinuity::TimestampChangedWithoutMarker
        }
        HevcDiscontinuity::MalformedPayload => DhVideoDiscontinuity::MalformedPayload,
        HevcDiscontinuity::NalUnitTooLarge => DhVideoDiscontinuity::NalUnitTooLarge,
        HevcDiscontinuity::ParameterSetTooLarge => DhVideoDiscontinuity::ParameterSetTooLarge,
        HevcDiscontinuity::AccessUnitTooLarge => DhVideoDiscontinuity::AccessUnitTooLarge,
        HevcDiscontinuity::TooManyNalUnits => DhVideoDiscontinuity::TooManyNalUnits,
        HevcDiscontinuity::MissingParameterSets => DhVideoDiscontinuity::MissingParameterSets,
    }
}

const fn orientation_value(orientation: &Orientation) -> DhOrientation {
    match orientation {
        Orientation::Portrait => DhOrientation::Portrait,
        Orientation::PortraitUpsideDown => DhOrientation::PortraitUpsideDown,
        Orientation::LandscapeLeft => DhOrientation::LandscapeLeft,
        Orientation::LandscapeRight => DhOrientation::LandscapeRight,
        Orientation::FaceUp => DhOrientation::FaceUp,
        Orientation::FaceDown => DhOrientation::FaceDown,
        Orientation::Unknown(_) => DhOrientation::Unknown,
    }
}

fn effective_orientation(
    current: &Orientation,
    non_flat: &Orientation,
) -> Result<DhOrientation, PublicFailure> {
    let current = orientation_value(current);
    if is_concrete_orientation(current) {
        return Ok(current);
    }
    let non_flat = orientation_value(non_flat);
    is_concrete_orientation(non_flat)
        .then_some(non_flat)
        .ok_or_else(unsupported_orientation)
}

fn concrete_orientation_from_raw(raw: u32) -> Result<DhOrientation, PublicFailure> {
    let orientation = orientation_from_raw(raw);
    is_concrete_orientation(orientation)
        .then_some(orientation)
        .ok_or_else(unsupported_orientation)
}

const fn is_concrete_orientation(orientation: DhOrientation) -> bool {
    matches!(
        orientation,
        DhOrientation::Portrait
            | DhOrientation::PortraitUpsideDown
            | DhOrientation::LandscapeLeft
            | DhOrientation::LandscapeRight
    )
}

const fn unsupported_orientation() -> PublicFailure {
    PublicFailure::new(
        "unsupported_device_orientation",
        "rotation",
        false,
        "The authenticated orientation service returned no concrete screen orientation.",
    )
}

const fn orientation_from_raw(raw: u32) -> DhOrientation {
    match raw {
        value if value == DhOrientation::Portrait as u32 => DhOrientation::Portrait,
        value if value == DhOrientation::PortraitUpsideDown as u32 => {
            DhOrientation::PortraitUpsideDown
        }
        value if value == DhOrientation::LandscapeLeft as u32 => DhOrientation::LandscapeLeft,
        value if value == DhOrientation::LandscapeRight as u32 => DhOrientation::LandscapeRight,
        value if value == DhOrientation::FaceUp as u32 => DhOrientation::FaceUp,
        value if value == DhOrientation::FaceDown as u32 => DhOrientation::FaceDown,
        _ => DhOrientation::Unknown,
    }
}

fn classify_hid_error(error: HidError, stage: &'static str) -> PublicFailure {
    match error {
        HidError::Input(_) => PublicFailure::new(
            "invalid_input_transition",
            stage,
            false,
            "The input transition is invalid for the active device state.",
        ),
        HidError::Device(_) => PublicFailure::new(
            "input_delivery_failed",
            stage,
            true,
            "The authenticated input service could not deliver the command.",
        ),
    }
}

const fn invalid_keyboard_transition() -> PublicFailure {
    PublicFailure::new(
        "invalid_input_transition",
        "keyboard_input",
        false,
        "The keyboard transition is invalid for the active device state.",
    )
}

const fn media_start_failure() -> PublicFailure {
    PublicFailure::new(
        "display_stream_start_failed",
        "display_stream",
        true,
        "The authenticated display service could not start the media stream.",
    )
}

const fn display_service_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "display_service_connect_failed",
        "display_stream",
        true,
        "The advertised display service could not be opened.",
    )
}

const fn input_service_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "input_service_connect_failed",
        "input",
        true,
        "An advertised authenticated input service could not be opened.",
    )
}

const fn orientation_service_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "orientation_service_connect_failed",
        "rotation",
        true,
        "The advertised orientation service could not be opened.",
    )
}

const fn orientation_state_failed() -> PublicFailure {
    PublicFailure::new(
        "orientation_query_failed",
        "rotation",
        true,
        "The authenticated orientation service did not return its current state.",
    )
}

const fn video_control_delivery_failed() -> PublicFailure {
    PublicFailure::new(
        "video_control_delivery_failed",
        "video_control",
        true,
        "The outbound video control datagram could not be delivered.",
    )
}

const fn unsupported_video_answer_extraction() -> PublicFailure {
    PublicFailure::new(
        "unsupported_protocol_version",
        "video_answer_extraction",
        false,
        "The display service did not return one bounded video negotiation answer.",
    )
}

const fn unsupported_video_negotiation(
    stage: &'static str,
    message: &'static str,
) -> PublicFailure {
    PublicFailure::new("unsupported_protocol_version", stage, false, message)
}

const fn video_negotiation_rejected() -> PublicFailure {
    PublicFailure::new(
        "video_negotiation_rejected",
        "video_negotiation",
        false,
        "The authenticated display service rejected the receiver's video offer.",
    )
}

async fn verify_developer_readiness(
    provider: &mut impl RsdProvider,
    handshake: &mut RsdHandshake,
) -> Result<DeveloperReady, PublicFailure> {
    let service_name = ImageMounter::rsd_service_name();
    if !handshake.services.contains_key(service_name.as_ref()) {
        return Err(developer_image_unavailable());
    }
    let mut image_mounter = match tokio::time::timeout(
        DEVELOPER_READINESS_TIMEOUT,
        ImageMounter::connect_rsd(provider, handshake),
    )
    .await
    {
        Ok(Ok(client)) => client,
        Ok(Err(error)) => return Err(classify_developer_readiness_connection_error(error)),
        Err(_) => return Err(developer_image_connection_failed()),
    };

    match tokio::time::timeout(
        DEVELOPER_READINESS_TIMEOUT,
        image_mounter.query_developer_mode_status(),
    )
    .await
    {
        Ok(Ok(true)) => {}
        Ok(Ok(false)) | Ok(Err(IdeviceError::DeveloperModeNotEnabled)) => {
            return Err(PublicFailure::new(
                "developer_mode_disabled",
                "developer_readiness",
                false,
                "Developer Mode is disabled on the target.",
            ));
        }
        Ok(Err(error)) => {
            return Err(classify_developer_readiness_error(
                DeveloperReadinessProbe::DeveloperModeStatus,
                error,
            ));
        }
        Err(_) => return Err(developer_image_connection_failed()),
    }

    match tokio::time::timeout(
        DEVELOPER_READINESS_TIMEOUT,
        image_mounter.image_is_present("Personalized"),
    )
    .await
    {
        Ok(Ok(true)) => Ok(DeveloperReady),
        Ok(Ok(false)) | Ok(Err(IdeviceError::NotFound)) => Err(developer_image_unavailable()),
        Ok(Err(error)) => Err(classify_developer_readiness_error(
            DeveloperReadinessProbe::PersonalizedImageLookup,
            error,
        )),
        Err(_) => Err(developer_image_connection_failed()),
    }
}

async fn open_screenshot_service(
    _readiness: &DeveloperReady,
    provider: &mut impl RsdProvider,
    handshake: &mut RsdHandshake,
) -> Result<ScreenCaptureServiceClient<Box<dyn idevice::ReadWrite>>, PublicFailure> {
    require_prepared_service(handshake, SCREENSHOT_SERVICE)?;
    stage(
        SCREENSHOT_TIMEOUT,
        screenshot_service_connection_failed(),
        ScreenCaptureServiceClient::connect_rsd(provider, handshake),
    )
    .await
}

fn require_prepared_service(
    handshake: &RsdHandshake,
    service_name: &str,
) -> Result<(), PublicFailure> {
    if handshake.services.contains_key(service_name) {
        Ok(())
    } else {
        Err(developer_image_incompatible())
    }
}

fn classify_developer_readiness_error(
    probe: DeveloperReadinessProbe,
    error: IdeviceError,
) -> PublicFailure {
    match error {
        IdeviceError::UnexpectedResponse(reason)
            if matches!(probe, DeveloperReadinessProbe::PersonalizedImageLookup) =>
        {
            classify_developer_image_lookup_response(&reason)
        }
        IdeviceError::UnexpectedResponse(_) | IdeviceError::Plist(_) => match probe {
            DeveloperReadinessProbe::DeveloperModeStatus => developer_mode_status_unsupported(),
            DeveloperReadinessProbe::PersonalizedImageLookup => {
                developer_image_lookup_unsupported()
            }
        },
        _ => developer_image_connection_failed(),
    }
}

fn classify_developer_image_lookup_response(reason: &str) -> PublicFailure {
    match reason {
        "LookupImage returned a malformed ImagePresent value" => {
            developer_image_lookup_presence_malformed()
        }
        "LookupImage returned a malformed signature array" => {
            developer_image_lookup_signature_array_malformed()
        }
        "LookupImage returned an empty image signature" => developer_image_lookup_signature_empty(),
        "LookupImage returned an empty signature array" => {
            developer_image_lookup_signature_array_empty()
        }
        "LookupImage returned an unsupported image signature type" => {
            developer_image_lookup_signature_type_unsupported()
        }
        "LookupImage returned a malformed image signature" => {
            developer_image_lookup_signature_malformed()
        }
        "LookupImage omitted both absence and signature data" => {
            developer_image_lookup_signature_missing()
        }
        _ => developer_image_lookup_unsupported(),
    }
}

fn classify_developer_readiness_connection_error(error: IdeviceError) -> PublicFailure {
    match error {
        IdeviceError::UnexpectedResponse(_) | IdeviceError::Plist(_) => {
            unsupported_protocol_version()
        }
        _ => developer_image_connection_failed(),
    }
}

const fn developer_image_unavailable() -> PublicFailure {
    PublicFailure::new(
        "developer_image_unavailable",
        "developer_readiness",
        false,
        "The target does not have an Xcode-prepared personalized developer image.",
    )
}

const fn developer_image_incompatible() -> PublicFailure {
    PublicFailure::new(
        "developer_image_incompatible",
        "developer_readiness",
        false,
        "The prepared developer image does not expose the required CoreDevice service.",
    )
}

const fn developer_mode_status_unsupported() -> PublicFailure {
    PublicFailure::new(
        "developer_mode_status_unsupported",
        "developer_readiness",
        false,
        "The target returned unsupported Developer Mode status metadata.",
    )
}

const fn developer_image_lookup_unsupported() -> PublicFailure {
    PublicFailure::new(
        "developer_image_lookup_unsupported",
        "developer_readiness",
        false,
        "The target returned unsupported personalized developer image metadata.",
    )
}

const fn developer_image_lookup_presence_malformed() -> PublicFailure {
    PublicFailure::new(
        "developer_image_lookup_presence_malformed",
        "developer_readiness",
        false,
        "The target returned malformed personalized-image presence metadata.",
    )
}

const fn developer_image_lookup_signature_array_malformed() -> PublicFailure {
    PublicFailure::new(
        "developer_image_lookup_signature_array_malformed",
        "developer_readiness",
        false,
        "The target returned a malformed personalized-image signature array.",
    )
}

const fn developer_image_lookup_signature_malformed() -> PublicFailure {
    PublicFailure::new(
        "developer_image_lookup_signature_malformed",
        "developer_readiness",
        false,
        "The target returned malformed personalized-image signature metadata.",
    )
}

const fn developer_image_lookup_signature_empty() -> PublicFailure {
    PublicFailure::new(
        "developer_image_lookup_signature_empty",
        "developer_readiness",
        false,
        "The target returned an empty personalized-image signature.",
    )
}

const fn developer_image_lookup_signature_array_empty() -> PublicFailure {
    PublicFailure::new(
        "developer_image_lookup_signature_array_empty",
        "developer_readiness",
        false,
        "The target returned an empty personalized-image signature array.",
    )
}

const fn developer_image_lookup_signature_type_unsupported() -> PublicFailure {
    PublicFailure::new(
        "developer_image_lookup_signature_type_unsupported",
        "developer_readiness",
        false,
        "The target returned an unsupported personalized-image signature type.",
    )
}

const fn developer_image_lookup_signature_missing() -> PublicFailure {
    PublicFailure::new(
        "developer_image_lookup_signature_missing",
        "developer_readiness",
        false,
        "The target omitted personalized-image signature metadata.",
    )
}

const fn unsupported_protocol_version() -> PublicFailure {
    PublicFailure::new(
        "unsupported_protocol_version",
        "developer_readiness",
        false,
        "The target returned unsupported developer-readiness metadata.",
    )
}

const fn developer_image_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "developer_image_connection_failed",
        "developer_readiness",
        true,
        "Developer readiness could not be verified over the authenticated connection.",
    )
}

const fn screenshot_service_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "screenshot_service_connect_failed",
        "screenshot",
        true,
        "The advertised screenshot service could not be opened.",
    )
}

async fn stage<T, Error, Work>(
    timeout: Duration,
    failure: PublicFailure,
    work: Work,
) -> Result<T, PublicFailure>
where
    Work: Future<Output = Result<T, Error>>,
{
    match tokio::time::timeout(timeout, work).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(_)) | Err(_) => Err(failure),
    }
}

fn pair_verify_failure(error: IdeviceError) -> PublicFailure {
    let (stage, retryable) = match error {
        IdeviceError::RemotePairing(RemotePairingError::PeerAuthenticationFailed) => {
            ("pair_verify_m2_authentication", false)
        }
        IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2Malformed) => {
            ("pair_verify_m2_shape", false)
        }
        IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2DecryptionFailed) => {
            ("pair_verify_m2_decryption", false)
        }
        IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2IdentifierMismatch) => {
            ("pair_verify_m2_identifier", false)
        }
        IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2SignatureFailed) => {
            ("pair_verify_m2_signature", false)
        }
        IdeviceError::RemotePairing(RemotePairingError::PairVerifyFailed) => {
            ("pair_verify_peer_rejection", false)
        }
        IdeviceError::RemotePairing(RemotePairingError::PairVerifyCompletionFailed) => {
            ("pair_verify_m4_completion", false)
        }
        IdeviceError::Socket(_) | IdeviceError::Timeout => ("pair_verify_transport", true),
        _ => ("pair_verify_protocol", false),
    };
    PublicFailure::new(
        "pair_verify_failed",
        stage,
        retryable,
        "The authenticated Pair Verify exchange failed.",
    )
}

fn bind_pairing_listener(port: u16) -> Result<TcpListener, PublicFailure> {
    let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP)).map_err(|_| {
        PublicFailure::new(
            "pairing_listener_create_failed",
            "pairing_listener",
            true,
            "Unable to create the native pairing listener.",
        )
    })?;
    socket.set_only_v6(false).map_err(|_| {
        PublicFailure::new(
            "pairing_listener_dual_stack_failed",
            "pairing_listener",
            false,
            "Unable to configure the native pairing listener.",
        )
    })?;
    socket.set_nonblocking(true).map_err(|_| {
        PublicFailure::new(
            "pairing_listener_nonblocking_failed",
            "pairing_listener",
            false,
            "Unable to configure the native pairing listener.",
        )
    })?;
    let address = SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, port, 0, 0));
    socket.bind(&address.into()).map_err(|_| {
        PublicFailure::new(
            "pairing_listener_bind_failed",
            "pairing_listener",
            true,
            "Unable to bind the native pairing listener.",
        )
    })?;
    socket.listen(4).map_err(|_| {
        PublicFailure::new(
            "pairing_listener_listen_failed",
            "pairing_listener",
            true,
            "Unable to listen for device pairing connections.",
        )
    })?;
    let listener: std::net::TcpListener = socket.into();
    TcpListener::from_std(listener).map_err(|_| {
        PublicFailure::new(
            "pairing_listener_runtime_failed",
            "pairing_listener",
            false,
            "Unable to attach the pairing listener to the native runtime.",
        )
    })
}

fn parse_tunnel_ip(value: &str) -> Result<IpAddr, PublicFailure> {
    let address: IpAddr = value.parse().map_err(|_| {
        PublicFailure::new(
            "invalid_tunnel_address",
            "cd_tunnel",
            false,
            "The target returned an invalid tunnel address.",
        )
    })?;
    if address.is_unspecified() || address.is_multicast() {
        return Err(PublicFailure::new(
            "invalid_tunnel_address",
            "cd_tunnel",
            false,
            "The target returned an invalid tunnel address.",
        ));
    }
    Ok(address)
}

fn validate_rsd_uuid(value: &str) -> Result<String, PublicFailure> {
    let parsed = uuid::Uuid::parse_str(value).map_err(|_| {
        PublicFailure::new(
            "invalid_rsd_metadata",
            "rsd_handshake",
            false,
            "The target returned invalid RSD metadata.",
        )
    })?;
    if !parsed.hyphenated().to_string().eq_ignore_ascii_case(value) {
        return Err(PublicFailure::new(
            "invalid_rsd_metadata",
            "rsd_handshake",
            false,
            "The target returned invalid RSD metadata.",
        ));
    }
    Ok(value.to_owned())
}

fn rsd_snapshot(
    handshake: &RsdHandshake,
    target: &PeerRecord,
) -> Result<RsdSnapshot, PublicFailure> {
    let operating_system_version =
        optional_rsd_property(handshake, "OSVersion", MAX_RSD_VERSION_BYTES)?.unwrap_or_default();
    let build_version =
        optional_rsd_property(handshake, "BuildVersion", MAX_RSD_BUILD_BYTES)?.unwrap_or_default();
    let unique_device_id =
        required_rsd_property(handshake, "UniqueDeviceID", MAX_RSD_DEVICE_ID_BYTES)?;
    let product_type = required_rsd_property(handshake, "ProductType", MAX_RSD_PRODUCT_TYPE_BYTES)?;
    if unique_device_id != target.device_id || product_type != target.product_type {
        return Err(invalid_rsd_metadata());
    }
    let protocol_version =
        u64::try_from(handshake.protocol_version).map_err(|_| invalid_rsd_metadata())?;
    if protocol_version == 0 {
        return Err(invalid_rsd_metadata());
    }

    Ok(RsdSnapshot {
        uuid: validate_rsd_uuid(&handshake.uuid)?,
        operating_system_version: operating_system_version.to_owned(),
        build_version: build_version.to_owned(),
        unique_device_id: unique_device_id.to_owned(),
        product_type: product_type.to_owned(),
        protocol_version,
        service_count: u64::try_from(handshake.services.len())
            .map_err(|_| invalid_rsd_metadata())?,
        screenshot_service_available: handshake.services.contains_key(SCREENSHOT_SERVICE),
    })
}

fn optional_rsd_property<'a>(
    handshake: &'a RsdHandshake,
    key: &str,
    maximum_bytes: usize,
) -> Result<Option<&'a str>, PublicFailure> {
    let Some(value) = handshake.properties.get(key) else {
        return Ok(None);
    };
    let value = value.as_string().ok_or_else(invalid_rsd_metadata)?;
    validate_rsd_property(value, maximum_bytes)?;
    Ok(Some(value))
}

fn required_rsd_property<'a>(
    handshake: &'a RsdHandshake,
    key: &str,
    maximum_bytes: usize,
) -> Result<&'a str, PublicFailure> {
    let value = handshake
        .properties
        .get(key)
        .and_then(plist::Value::as_string)
        .ok_or_else(invalid_rsd_metadata)?;
    validate_rsd_property(value, maximum_bytes)?;
    Ok(value)
}

fn validate_rsd_property(value: &str, maximum_bytes: usize) -> Result<(), PublicFailure> {
    if value.is_empty()
        || value.len() > maximum_bytes
        || value.trim() != value
        || !value.bytes().all(|byte| byte.is_ascii_graphic())
    {
        return Err(invalid_rsd_metadata());
    }
    Ok(())
}

const fn invalid_rsd_metadata() -> PublicFailure {
    PublicFailure::new(
        "invalid_rsd_metadata",
        "rsd_handshake",
        false,
        "The target returned invalid RSD metadata.",
    )
}

fn validation_as_idevice(_: ValidationError) -> idevice::IdeviceError {
    idevice::IdeviceError::UnexpectedResponse(
        "authenticated peer metadata violated the Device Hub boundary".into(),
    )
}

fn event_failure_as_idevice(_: PublicFailure) -> idevice::IdeviceError {
    idevice::IdeviceError::UnexpectedResponse(
        "the Pairable Host event dispatcher stopped before PIN delivery".into(),
    )
}

#[cfg(test)]
mod tests {
    use std::{collections::HashMap, ffi::c_void, sync::Mutex};

    use super::*;
    use crate::{
        abi::{DhEvent, DhGeneration},
        session::EventEmitterTestFixture,
    };
    use idevice::xpc::XPCObject;

    const MISSING_LIVE_TARGET: &str =
        "Live protocol verification requires an explicit target name.";
    const TEST_VIDEO_PAYLOAD_TYPE: u8 = 100;
    const TEST_VIDEO_SSRC: u32 = 0x1234_5678;
    const SYNTHETIC_64_X_64_SPS: &[u8] = &[
        0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9f, 0xa8, 0x00, 0x00, 0x03, 0x00,
        0x00, 0xff, 0xa0, 0x20, 0x81, 0x05, 0x96, 0xea, 0x49, 0x32, 0xbc, 0x05, 0xa0, 0x20, 0x00,
        0x00, 0x03, 0x00, 0x20, 0x00, 0x00, 0x03, 0x00, 0x21,
    ];

    #[derive(Default)]
    struct ProtocolMediaCapture {
        events: Mutex<Vec<(DhEventKind, Option<DhDisplayGeometry>)>>,
    }

    unsafe extern "C" fn capture_protocol_media_event(event: *const DhEvent, context: *mut c_void) {
        // SAFETY: The protocol test keeps both callback pointers alive.
        let event = unsafe { &*event };
        // SAFETY: Context points to a live `ProtocolMediaCapture`.
        let capture = unsafe { &*(context.cast::<ProtocolMediaCapture>()) };
        let geometry = if event.video_access_unit.is_null() {
            None
        } else {
            // SAFETY: The access-unit view is borrowed for this callback.
            Some(unsafe { (*event.video_access_unit).geometry })
        };
        capture.events.lock().unwrap().push((event.kind, geometry));
    }

    fn test_media_emitter(capture: &ProtocolMediaCapture) -> MediaEmitter {
        MediaEmitter::test_fixture(
            DhGeneration {
                high: 0x1020_3040_5060_7080,
                low: 0x90A0_B0C0_D0E0_F001,
            },
            Some(capture_protocol_media_event),
            std::ptr::from_ref(capture).cast_mut().cast(),
        )
    }

    #[test]
    fn pair_verify_discovery_completes_without_entering_the_tunnel_path() {
        let pair_verify_events = EventEmitterTestFixture::new();
        assert!(
            complete_pair_verify_discovery(&RemoteMode::PairVerify, &pair_verify_events.emitter(),)
                .unwrap()
        );
        assert_eq!(pair_verify_events.pending_event_count(), 1);

        let screenshot_events = EventEmitterTestFixture::new();
        assert!(
            !complete_pair_verify_discovery(&RemoteMode::Screenshot, &screenshot_events.emitter(),)
                .unwrap()
        );
        assert_eq!(screenshot_events.pending_event_count(), 0);
    }

    #[test]
    fn pair_verify_does_not_promote_provisional_records_in_native_code() {
        assert!(!should_promote_provisional_record(
            &RemoteMode::PairVerify,
            DhPairingCompletion::Provisional,
        ));
        assert!(should_promote_provisional_record(
            &RemoteMode::Screenshot,
            DhPairingCompletion::Provisional,
        ));
        assert!(should_promote_provisional_record(
            &RemoteMode::ControlStream,
            DhPairingCompletion::Provisional,
        ));
        assert!(!should_promote_provisional_record(
            &RemoteMode::Screenshot,
            DhPairingCompletion::Committed,
        ));
    }

    #[test]
    fn pair_verify_failures_preserve_secret_safe_protocol_checkpoints() {
        use idevice::remote_pairing::errors::RemotePairingError;

        let cases = [
            (
                IdeviceError::RemotePairing(RemotePairingError::PeerAuthenticationFailed),
                "pair_verify_m2_authentication",
            ),
            (
                IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2DecryptionFailed),
                "pair_verify_m2_decryption",
            ),
            (
                IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2IdentifierMismatch),
                "pair_verify_m2_identifier",
            ),
            (
                IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2SignatureFailed),
                "pair_verify_m2_signature",
            ),
            (
                IdeviceError::RemotePairing(RemotePairingError::PairVerifyFailed),
                "pair_verify_peer_rejection",
            ),
            (
                IdeviceError::RemotePairing(RemotePairingError::PairVerifyCompletionFailed),
                "pair_verify_m4_completion",
            ),
            (
                IdeviceError::UnexpectedResponse("redacted protocol shape".into()),
                "pair_verify_protocol",
            ),
        ];

        for (error, expected_stage) in cases {
            let failure = pair_verify_failure(error);
            assert_eq!(failure.code, "pair_verify_failed");
            assert_eq!(failure.stage, expected_stage);
            assert!(!failure.retryable);
        }
    }

    fn test_geometry() -> DhDisplayGeometry {
        DhDisplayGeometry {
            pixel_width: 0,
            pixel_height: 0,
            orientation: DhOrientation::Portrait as u32,
            non_flat_orientation: DhOrientation::Portrait as u32,
            orientation_locked: 0,
            reserved: [0; 7],
        }
    }

    fn test_nal(nal_type: u8, body: &[u8]) -> Vec<u8> {
        let mut nal = vec![nal_type << 1, 1];
        nal.extend_from_slice(body);
        nal
    }

    fn test_aggregation_packet(nals: &[Vec<u8>]) -> Vec<u8> {
        let mut payload = vec![48 << 1, 1];
        for nal in nals {
            payload.extend_from_slice(&(nal.len() as u16).to_be_bytes());
            payload.extend_from_slice(nal);
        }
        payload
    }

    fn test_rtp_datagram(
        payload_type: u8,
        sequence_number: u16,
        timestamp: u32,
        marker: bool,
        payload: &[u8],
    ) -> Vec<u8> {
        let mut datagram = vec![0x80, (u8::from(marker) << 7) | payload_type];
        datagram.extend_from_slice(&sequence_number.to_be_bytes());
        datagram.extend_from_slice(&timestamp.to_be_bytes());
        datagram.extend_from_slice(&TEST_VIDEO_SSRC.to_be_bytes());
        datagram.extend_from_slice(payload);
        datagram
    }

    fn prime_test_video_stream(
        assembler: &mut HevcAccessUnitAssembler,
        last_configuration_revision: &mut u64,
        geometry: &mut DhDisplayGeometry,
        media: &MediaEmitter,
        emitter: &EventEmitter,
    ) {
        let boundary = test_nal(39, &[0xAA]);
        assert!(
            !process_video_datagram(
                test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 1, 1, true, &boundary),
                VIDEO_SENDER_PORT,
                assembler,
                last_configuration_revision,
                geometry,
                media,
                emitter,
            )
            .unwrap()
        );
        let parameters = test_aggregation_packet(&[
            test_nal(32, &[0x10]),
            SYNTHETIC_64_X_64_SPS.to_vec(),
            test_nal(34, &[0x30]),
        ]);
        assert!(
            !process_video_datagram(
                test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 2, 2, true, &parameters),
                VIDEO_SENDER_PORT,
                assembler,
                last_configuration_revision,
                geometry,
                media,
                emitter,
            )
            .unwrap()
        );
        let sync_sample = test_nal(19, &[0xD0]);
        assert!(
            process_video_datagram(
                test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 3, 3, true, &sync_sample),
                VIDEO_SENDER_PORT,
                assembler,
                last_configuration_revision,
                geometry,
                media,
                emitter,
            )
            .unwrap()
        );
        assert_eq!(*last_configuration_revision, 1);
        assert_eq!((geometry.pixel_width, geometry.pixel_height), (64, 64));
    }

    async fn open_live_rsd_for_target(
        target_name: &str,
        endpoint: &str,
    ) -> Result<RsdHandshake, String> {
        if target_name.trim().is_empty() {
            return Err(MISSING_LIVE_TARGET.into());
        }
        let stream = tokio::time::timeout(Duration::from_secs(3), TcpStream::connect(endpoint))
            .await
            .map_err(|_| "RSD connection timed out".to_owned())?
            .map_err(|error| format!("RSD connection failed: {error}"))?;
        tokio::time::timeout(Duration::from_secs(3), RsdHandshake::new(stream))
            .await
            .map_err(|_| "RSD handshake timed out".to_owned())?
            .map_err(|error| format!("RSD handshake failed: {error}"))
    }

    #[test]
    fn malformed_stream_discontinuity_drops_predicted_frames_until_a_sync_sample() {
        let capture = ProtocolMediaCapture::default();
        let media = test_media_emitter(&capture);
        let control = EventEmitterTestFixture::new();
        let emitter = control.emitter();
        let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
        let mut last_configuration_revision = 0;
        let mut geometry = test_geometry();
        prime_test_video_stream(
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        );
        capture.events.lock().unwrap().clear();

        process_video_datagram(
            vec![0],
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();
        assert_eq!(last_configuration_revision, 0);

        let sample = test_nal(1, &[0x60]);
        process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &sample),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();

        {
            let events = capture.events.lock().unwrap();
            assert_eq!(
                events.iter().map(|(kind, _)| *kind).collect::<Vec<_>>(),
                vec![DhEventKind::VideoDiscontinuity]
            );
        }

        let sync_sample = test_nal(19, &[0xF0]);
        process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 5, 5, true, &sync_sample),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();

        let events = capture.events.lock().unwrap();
        assert_eq!(
            events.iter().map(|(kind, _)| *kind).collect::<Vec<_>>(),
            vec![
                DhEventKind::VideoDiscontinuity,
                DhEventKind::VideoConfiguration,
                DhEventKind::VideoAccessUnit,
            ]
        );
        let access_unit_geometry = events.last().unwrap().1.unwrap();
        assert_eq!(
            (
                access_unit_geometry.pixel_width,
                access_unit_geometry.pixel_height,
                access_unit_geometry.orientation,
            ),
            (64, 64, DhOrientation::Portrait as u32)
        );
    }

    #[test]
    fn authoritative_stream_identity_accepts_the_first_matching_packet() {
        let capture = ProtocolMediaCapture::default();
        let media = test_media_emitter(&capture);
        let control = EventEmitterTestFixture::new();
        let emitter = control.emitter();
        let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
        let mut last_configuration_revision = 0;
        let mut geometry = test_geometry();
        let boundary = test_nal(39, &[0xAA]);

        process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 1, 1, true, &boundary),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();

        assert_eq!(
            capture
                .events
                .lock()
                .unwrap()
                .iter()
                .map(|(kind, _)| *kind)
                .collect::<Vec<_>>(),
            Vec::<DhEventKind>::new()
        );
    }

    #[test]
    fn incomplete_display_geometry_is_not_dispatched() {
        let control = EventEmitterTestFixture::new();
        let emitter = control.emitter();
        let mut geometry = test_geometry();

        emit_display_geometry_if_complete(&emitter, geometry).unwrap();
        assert_eq!(control.pending_event_count(), 0);

        geometry.pixel_width = 64;
        geometry.pixel_height = 64;
        emit_display_geometry_if_complete(&emitter, geometry).unwrap();
        assert_eq!(control.pending_event_count(), 1);
    }

    #[test]
    fn access_unit_uses_the_protocol_workers_current_geometry_snapshot() {
        let capture = ProtocolMediaCapture::default();
        let media = test_media_emitter(&capture);
        let control = EventEmitterTestFixture::new();
        let emitter = control.emitter();
        let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
        let mut last_configuration_revision = 0;
        let mut geometry = test_geometry();
        prime_test_video_stream(
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        );
        capture.events.lock().unwrap().clear();

        geometry.orientation = DhOrientation::LandscapeLeft as u32;
        geometry.non_flat_orientation = DhOrientation::LandscapeLeft as u32;
        let sample = test_nal(1, &[0x60]);
        process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &sample),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();

        let events = capture.events.lock().unwrap();
        assert_eq!(
            events.iter().map(|(kind, _)| *kind).collect::<Vec<_>>(),
            vec![DhEventKind::VideoAccessUnit]
        );
        let access_unit_geometry = events.last().unwrap().1.unwrap();
        assert_eq!(
            access_unit_geometry.orientation,
            DhOrientation::LandscapeLeft as u32
        );
        assert_eq!(
            access_unit_geometry.non_flat_orientation,
            DhOrientation::LandscapeLeft as u32
        );
        assert_eq!(
            (
                access_unit_geometry.pixel_width,
                access_unit_geometry.pixel_height,
            ),
            (64, 64)
        );
    }

    #[test]
    fn changed_video_configuration_refreshes_orientation_before_access_unit_emission() {
        let capture = ProtocolMediaCapture::default();
        let media = test_media_emitter(&capture);
        let control = EventEmitterTestFixture::new();
        let emitter = control.emitter();
        let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
        let mut last_configuration_revision = 0;
        let mut geometry = test_geometry();

        let boundary = test_nal(39, &[0xAA]);
        process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 1, 1, true, &boundary),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();
        let parameters = test_aggregation_packet(&[
            test_nal(32, &[0x10]),
            SYNTHETIC_64_X_64_SPS.to_vec(),
            test_nal(34, &[0x30]),
        ]);
        process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 2, 2, true, &parameters),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();

        let sample = test_nal(19, &[0xD0]);
        let prepared = prepare_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 3, 3, true, &sample),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &media,
        )
        .unwrap()
        .unwrap();
        let orientation = OrientationState {
            orientation: Orientation::LandscapeRight,
            non_flat_orientation: Orientation::LandscapeRight,
            locked: true,
        };
        emit_prepared_video_datagram(
            prepared,
            &assembler,
            &mut last_configuration_revision,
            &mut geometry,
            Some(&orientation),
            &media,
            &emitter,
        )
        .unwrap();

        let access_unit_geometry = capture.events.lock().unwrap().last().unwrap().1.unwrap();
        assert_eq!(
            access_unit_geometry.orientation,
            DhOrientation::LandscapeRight as u32
        );
        assert_eq!(
            access_unit_geometry.non_flat_orientation,
            DhOrientation::LandscapeRight as u32
        );
        assert_eq!(access_unit_geometry.orientation_locked, 1);
        assert_eq!(
            (
                access_unit_geometry.pixel_width,
                access_unit_geometry.pixel_height,
            ),
            (64, 64)
        );
    }

    #[test]
    fn rejected_stream_packet_fails_before_reaching_either_media_consumer() {
        let capture = ProtocolMediaCapture::default();
        let media = test_media_emitter(&capture);
        let control = EventEmitterTestFixture::new();
        let emitter = control.emitter();
        let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
        let mut last_configuration_revision = 0;
        let mut geometry = test_geometry();
        prime_test_video_stream(
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        );
        capture.events.lock().unwrap().clear();

        let unexpected_sample = test_nal(1, &[0x70]);
        let failure = process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE + 1, 4, 4, true, &unexpected_sample),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap_err();

        assert_eq!(failure.code, "video_datagram_rejected");
        assert_eq!(failure.stage, "video_stream_payload_invalid");
        assert!(capture.events.lock().unwrap().is_empty());
    }

    #[test]
    fn unexpected_stream_sender_is_classified_as_an_ssrc_mismatch() {
        let capture = ProtocolMediaCapture::default();
        let media = test_media_emitter(&capture);
        let control = EventEmitterTestFixture::new();
        let emitter = control.emitter();
        let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
        let mut last_configuration_revision = 0;
        let mut geometry = test_geometry();
        prime_test_video_stream(
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        );
        capture.events.lock().unwrap().clear();

        let mut datagram =
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &test_nal(1, &[0x70]));
        datagram[8..12].copy_from_slice(&(TEST_VIDEO_SSRC + 1).to_be_bytes());
        let failure = process_video_datagram(
            datagram,
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap_err();

        assert_eq!(failure.code, "video_datagram_rejected");
        assert_eq!(failure.stage, "video_stream_ssrc_mismatch");
        assert!(capture.events.lock().unwrap().is_empty());
    }

    #[test]
    fn translated_tunnel_port_does_not_override_authenticated_rtp_identity() {
        let capture = ProtocolMediaCapture::default();
        let media = test_media_emitter(&capture);
        let control = EventEmitterTestFixture::new();
        let emitter = control.emitter();
        let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
        let mut last_configuration_revision = 0;
        let mut geometry = test_geometry();
        prime_test_video_stream(
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        );
        capture.events.lock().unwrap().clear();

        process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &test_nal(1, &[0x60])),
            VIDEO_SENDER_PORT + 1,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();

        assert_eq!(
            capture
                .events
                .lock()
                .unwrap()
                .iter()
                .map(|(kind, _)| *kind)
                .collect::<Vec<_>>(),
            vec![DhEventKind::VideoAccessUnit]
        );
    }

    #[tokio::test]
    async fn live_harness_rejects_missing_target_before_opening_an_endpoint() {
        for target_name in ["", "   "] {
            let error = open_live_rsd_for_target(target_name, "not a socket endpoint")
                .await
                .unwrap_err();

            assert_eq!(error, MISSING_LIVE_TARGET);
        }
    }

    #[test]
    fn pairing_listener_is_dual_stack_and_reports_a_real_ephemeral_port() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let listener = bind_pairing_listener(0).unwrap();
            let address = listener.local_addr().unwrap();
            assert!(address.port() > 0);
            assert!(address.is_ipv6());
        });
    }

    #[test]
    fn tunnel_addresses_reject_unspecified_multicast_and_malformed_values() {
        for address in ["", "::", "0.0.0.0", "ff02::1", "224.0.0.1", "not-an-ip"] {
            assert!(parse_tunnel_ip(address).is_err(), "{address}");
        }
        assert_eq!(
            parse_tunnel_ip("fd00::1").unwrap(),
            "fd00::1".parse::<IpAddr>().unwrap()
        );
    }

    #[test]
    fn rsd_snapshot_requires_and_cross_checks_authoritative_device_identity() {
        let target = PeerRecord {
            device_id: "00008140-test".into(),
            account_identifier: "account".into(),
            peer_identifier: "peer".into(),
            peer_public_key: [1; 32],
            peer_alternate_irk: [2; 16],
            display_name: "Target".into(),
            product_type: "iPhone19,1".into(),
            completion: DhPairingCompletion::Committed,
        };
        let properties = HashMap::from([
            ("OSVersion".into(), plist::Value::String("27.0".into())),
            ("BuildVersion".into(), plist::Value::String("24A123".into())),
            (
                "UniqueDeviceID".into(),
                plist::Value::String(target.device_id.clone()),
            ),
            (
                "ProductType".into(),
                plist::Value::String(target.product_type.clone()),
            ),
        ]);
        let handshake = RsdHandshake {
            services: HashMap::new(),
            protocol_version: 2,
            properties: properties.clone(),
            uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
        };

        let snapshot = rsd_snapshot(&handshake, &target).unwrap();
        assert_eq!(snapshot.operating_system_version, "27.0");
        assert_eq!(snapshot.build_version, "24A123");
        assert_eq!(snapshot.unique_device_id, target.device_id);
        assert_eq!(snapshot.product_type, target.product_type);

        for key in ["UniqueDeviceID", "ProductType"] {
            let mut missing = properties.clone();
            missing.remove(key);
            let handshake = RsdHandshake {
                services: HashMap::new(),
                protocol_version: 2,
                properties: missing,
                uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
            };
            assert!(rsd_snapshot(&handshake, &target).is_err(), "{key}");
        }

        for key in ["OSVersion", "BuildVersion"] {
            let mut missing = properties.clone();
            missing.remove(key);
            let handshake = RsdHandshake {
                services: HashMap::new(),
                protocol_version: 2,
                properties: missing,
                uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
            };
            let snapshot = rsd_snapshot(&handshake, &target).unwrap();
            if key == "OSVersion" {
                assert!(snapshot.operating_system_version.is_empty());
            } else {
                assert!(snapshot.build_version.is_empty());
            }
        }

        for (key, value) in [
            ("UniqueDeviceID", "different-device"),
            ("ProductType", "iPad99,9"),
        ] {
            let mut mismatched = properties.clone();
            mismatched.insert(key.into(), plist::Value::String(value.into()));
            let handshake = RsdHandshake {
                services: HashMap::new(),
                protocol_version: 2,
                properties: mismatched,
                uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
            };
            assert!(rsd_snapshot(&handshake, &target).is_err(), "{key}");
        }
    }

    #[test]
    fn missing_required_service_after_readiness_is_incompatible() {
        let handshake = RsdHandshake {
            services: HashMap::new(),
            protocol_version: 2,
            properties: HashMap::new(),
            uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
        };

        let failure = require_prepared_service(&handshake, SCREENSHOT_SERVICE).unwrap_err();

        assert_eq!(failure.code, "developer_image_incompatible");
        assert_eq!(failure.stage, "developer_readiness");
        assert!(!failure.retryable);
    }

    #[test]
    fn advertised_required_service_passes_the_compatibility_gate() {
        let handshake = RsdHandshake {
            services: HashMap::from([(
                SCREENSHOT_SERVICE.into(),
                idevice::rsd::RsdService {
                    entitlement: String::new(),
                    port: 1,
                    uses_remote_xpc: false,
                    features: None,
                    service_version: None,
                },
            )]),
            protocol_version: 2,
            properties: HashMap::new(),
            uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
        };

        assert!(require_prepared_service(&handshake, SCREENSHOT_SERVICE).is_ok());
    }

    #[test]
    fn advertised_service_open_failure_is_retryable_connection_failure() {
        let readiness_failure =
            classify_developer_readiness_connection_error(IdeviceError::ServiceNotFound);
        let open_failure = screenshot_service_connection_failed();

        assert_eq!(readiness_failure.code, "developer_image_connection_failed");
        assert_eq!(readiness_failure.stage, "developer_readiness");
        assert!(readiness_failure.retryable);
        assert_eq!(open_failure.code, "screenshot_service_connect_failed");
        assert_eq!(open_failure.stage, "screenshot");
        assert!(open_failure.retryable);
    }

    #[test]
    fn malformed_developer_readiness_metadata_retains_the_failing_probe() {
        let malformed_plist = plist::from_bytes::<plist::Value>(b"not a plist").unwrap_err();
        for (probe, error, expected_code) in [
            (
                DeveloperReadinessProbe::DeveloperModeStatus,
                IdeviceError::UnexpectedResponse("malformed status response".into()),
                "developer_mode_status_unsupported",
            ),
            (
                DeveloperReadinessProbe::PersonalizedImageLookup,
                IdeviceError::UnexpectedResponse(
                    "LookupImage returned a malformed ImagePresent value".into(),
                ),
                "developer_image_lookup_presence_malformed",
            ),
            (
                DeveloperReadinessProbe::PersonalizedImageLookup,
                IdeviceError::UnexpectedResponse(
                    "LookupImage returned a malformed signature array".into(),
                ),
                "developer_image_lookup_signature_array_malformed",
            ),
            (
                DeveloperReadinessProbe::PersonalizedImageLookup,
                IdeviceError::UnexpectedResponse(
                    "LookupImage returned an empty image signature".into(),
                ),
                "developer_image_lookup_signature_empty",
            ),
            (
                DeveloperReadinessProbe::PersonalizedImageLookup,
                IdeviceError::UnexpectedResponse(
                    "LookupImage returned an empty signature array".into(),
                ),
                "developer_image_lookup_signature_array_empty",
            ),
            (
                DeveloperReadinessProbe::PersonalizedImageLookup,
                IdeviceError::UnexpectedResponse(
                    "LookupImage returned an unsupported image signature type".into(),
                ),
                "developer_image_lookup_signature_type_unsupported",
            ),
            (
                DeveloperReadinessProbe::PersonalizedImageLookup,
                IdeviceError::UnexpectedResponse(
                    "LookupImage omitted both absence and signature data".into(),
                ),
                "developer_image_lookup_signature_missing",
            ),
            (
                DeveloperReadinessProbe::PersonalizedImageLookup,
                IdeviceError::Plist(malformed_plist),
                "developer_image_lookup_unsupported",
            ),
        ] {
            let failure = classify_developer_readiness_error(probe, error);
            assert_eq!(failure.code, expected_code);
            assert_eq!(failure.stage, "developer_readiness");
            assert!(!failure.retryable);
        }
    }

    #[test]
    fn every_control_service_is_required_after_developer_readiness() {
        for required in [
            DISPLAY_SERVICE,
            UNIVERSAL_HID_SERVICE,
            INDIGO_HID_SERVICE,
            ORIENTATION_SERVICE,
        ] {
            let handshake = RsdHandshake {
                services: HashMap::new(),
                protocol_version: 2,
                properties: HashMap::new(),
                uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
            };
            let failure = require_prepared_service(&handshake, required).unwrap_err();
            assert_eq!(failure.code, "developer_image_incompatible", "{required}");
            assert!(!failure.retryable, "{required}");
        }
    }

    #[test]
    fn caller_video_offer_is_embedded_byte_for_byte_and_media_starts_share_identity() {
        let offer = vec![0, 1, 2, 0x80, 0xFF, 0, 7];
        let audio_offer = vec![9, 8, 7];
        let session_id = uuid::Uuid::parse_str("F0C52E3B-10D1-41E4-B9FB-6A53A4FC0784").unwrap();
        let audio = build_start_audio_parameters(
            "fd00::1",
            12_000,
            "fd00::2",
            AUDIO_SENDER_PORT,
            audio_offer,
            CLIENT_SUPPORTED_FEATURES,
            session_id,
        );
        let video = build_start_video_parameters(
            "fd00::1",
            12_001,
            "fd00::2",
            VIDEO_SENDER_PORT,
            offer.clone(),
            CLIENT_SUPPORTED_FEATURES,
            PRIMARY_DISPLAY_ID,
            session_id,
        );

        assert_eq!(video.get("negotiatorOffer"), Some(&XPCObject::Data(offer)));
        for parameters in [&audio, &video] {
            let options = match parameters.get("options") {
                Some(XPCObject::Dictionary(options)) => options,
                other => panic!("missing media options: {other:?}"),
            };
            let session = match options.get("avcMediaStreamOptionClientSessionID") {
                Some(XPCObject::Dictionary(session)) => session,
                other => panic!("missing client session: {other:?}"),
            };
            assert_eq!(session.get("uuid"), Some(&XPCObject::Uuid(session_id)),);
        }
    }

    #[test]
    fn touch_trace_labels_never_contain_coordinates() {
        let command = ControlCommand::Touch(TouchIntent::Tap {
            x: 12_345,
            y: 54_321,
        });

        assert_eq!(input_trace_label(&command).as_deref(), Some("touch_tap"));
    }

    #[test]
    fn negotiation_failures_are_typed_by_ownership_boundary() {
        let target = video_negotiation_rejected();
        assert_eq!(target.code, "video_negotiation_rejected");
        assert_eq!(target.stage, "video_negotiation");
        assert!(!target.retryable);

        let extraction = unsupported_video_answer_extraction();
        assert_eq!(extraction.code, "unsupported_protocol_version");
        assert_eq!(extraction.stage, "video_answer_extraction");
        assert!(!extraction.retryable);

        let answer = unsupported_video_negotiation("video_negotiation", "unsupported");
        assert_eq!(answer.code, "unsupported_protocol_version");
        assert_eq!(answer.stage, "video_negotiation");
        assert!(!answer.retryable);
    }

    #[test]
    fn screen_answer_parser_failures_preserve_the_protocol_stage() {
        use idevice::core_device::ScreenVideoAnswerError;

        let cases = [
            (
                ScreenVideoAnswerError::InvalidEnvelope,
                "video_answer_parse",
            ),
            (
                ScreenVideoAnswerError::VideoGroupMissing,
                "video_stream_group_missing",
            ),
            (
                ScreenVideoAnswerError::HevcPayloadMissing,
                "video_stream_payload_missing",
            ),
            (
                ScreenVideoAnswerError::PayloadTypeMissing,
                "video_stream_payload_missing",
            ),
            (
                ScreenVideoAnswerError::PayloadTypeInvalid,
                "video_stream_payload_invalid",
            ),
            (
                ScreenVideoAnswerError::PayloadEncrypted,
                "video_stream_payload_encrypted",
            ),
            (
                ScreenVideoAnswerError::SsrcMissing,
                "video_stream_ssrc_missing",
            ),
            (ScreenVideoAnswerError::SsrcZero, "video_stream_ssrc_zero"),
            (
                ScreenVideoAnswerError::SsrcInvalid,
                "video_stream_ssrc_invalid",
            ),
            (
                ScreenVideoAnswerError::AmbiguousStream,
                "video_stream_selection_ambiguous",
            ),
        ];

        for (error, expected_stage) in cases {
            assert_eq!(screen_video_answer_failure(error).stage, expected_stage,);
        }
    }

    #[test]
    fn negotiator_answer_extraction_requires_one_bounded_data_value() {
        let answer = vec![1, 2, 3];
        let valid = plist::Value::Dictionary(plist::Dictionary::from_iter([(
            "nested".to_owned(),
            plist::Value::Array(vec![plist::Value::Dictionary(
                plist::Dictionary::from_iter([(
                    "negotiatorAnswer".to_owned(),
                    plist::Value::Data(answer.clone()),
                )]),
            )]),
        )]));
        assert_eq!(extract_negotiator_answer(&valid).unwrap(), answer);

        for invalid in [
            plist::Value::Dictionary(plist::Dictionary::new()),
            plist::Value::Dictionary(plist::Dictionary::from_iter([(
                "negotiatorAnswer".to_owned(),
                plist::Value::Data(Vec::new()),
            )])),
            plist::Value::Dictionary(plist::Dictionary::from_iter([
                ("negotiatorAnswer".to_owned(), plist::Value::Data(vec![1])),
                (
                    "duplicate".to_owned(),
                    plist::Value::Dictionary(plist::Dictionary::from_iter([(
                        "negotiatorAnswer".to_owned(),
                        plist::Value::Data(vec![2]),
                    )])),
                ),
            ])),
        ] {
            let failure = extract_negotiator_answer(&invalid).unwrap_err();
            assert_eq!(failure.code, "unsupported_protocol_version");
            assert_eq!(failure.stage, "video_answer_extraction");
        }
    }

    #[test]
    fn negotiated_answer_selects_the_authoritative_sender_payload_and_ssrc() {
        let answer = idevice::core_device::build_screen_video_offer(
            "B87A251C-5B5C-46DA-B3B8-B26DB6D39131",
            &CallInfoBlob::default(),
            3,
        )
        .unwrap();

        let negotiated = parse_negotiated_video(&answer).unwrap();

        assert_eq!(negotiated.ssrc, 3);
        assert_eq!(negotiated.payload_type, 100);
    }

    #[test]
    fn userspace_video_offer_and_feedback_remain_one_owned_protocol() {
        let our_ssrc = 0x1020_3040;
        let device_ssrc = 0x5060_7080;
        let call_id = "B87A251C-5B5C-46DA-B3B8-B26DB6D39131";
        let offer =
            build_userspace_video_offer(call_id, &CallInfoBlob::default(), our_ssrc).unwrap();
        let negotiated_offer = parse_screen_video_answer(&offer).unwrap();
        assert_eq!(negotiated_offer.ssrc, our_ssrc);

        let mut feedback = VideoFeedbackState::new(our_ssrc, device_ssrc, call_id.into());
        let first = VideoDatagramOutcome {
            completed_frame_timestamps: vec![0xA0B0_C0D0],
            emitted_access_unit: true,
            highest_sequence_number: Some(u16::MAX - 1),
            requires_keyframe: false,
        };
        assert_eq!(
            feedback.consume(&first),
            vec![build_frame_ack(our_ssrc, 0xA0B0_C0D0)]
        );
        assert_eq!(
            feedback.periodic_report(Duration::from_millis(50)),
            Some(build_rctl(our_ssrc, 50, 1, 0))
        );

        let wrapped = VideoDatagramOutcome {
            highest_sequence_number: Some(0),
            requires_keyframe: true,
            ..Default::default()
        };
        assert_eq!(
            feedback.consume(&wrapped),
            vec![build_keyframe_request(
                our_ssrc,
                call_id,
                device_ssrc,
                &[],
                0,
            )]
        );
        assert_eq!(
            feedback.periodic_report(Duration::from_millis(100)),
            Some(build_rctl(our_ssrc, 100, 1, 2))
        );
    }

    #[derive(Default)]
    struct MockKeyboardStateSink {
        attempts: Vec<Vec<u8>>,
        fail_at: Option<usize>,
    }

    impl KeyboardStateSink for MockKeyboardStateSink {
        async fn replace(&mut self, pressed: BTreeSet<KeyboardUsage>) -> Result<(), HidError> {
            self.attempts
                .push(pressed.into_iter().map(KeyboardUsage::raw).collect());
            if self.fail_at == Some(self.attempts.len()) {
                Err(HidError::Device(IdeviceError::ServiceNotFound))
            } else {
                Ok(())
            }
        }
    }

    #[derive(Default)]
    struct MockHardwareButtonSink {
        attempts: Vec<(HardwareButton, ButtonState)>,
        fail_at: Option<usize>,
    }

    impl HardwareButtonSink for MockHardwareButtonSink {
        async fn send(
            &mut self,
            button: HardwareButton,
            state: ButtonState,
        ) -> Result<(), HidError> {
            self.attempts.push((button, state));
            if self.fail_at == Some(self.attempts.len()) {
                Err(HidError::Device(IdeviceError::ServiceNotFound))
            } else {
                Ok(())
            }
        }
    }

    #[test]
    fn hardware_button_taps_use_the_device_required_hold_duration() {
        assert_eq!(
            hardware_button_tap_hold(HardwareButton::Home),
            Duration::from_millis(50)
        );
        assert_eq!(
            hardware_button_tap_hold(HardwareButton::Lock),
            Duration::from_millis(300)
        );
        assert_eq!(
            hardware_button_tap_hold(HardwareButton::Siri),
            Duration::from_secs(1)
        );
        assert_eq!(
            hardware_button_tap_hold(HardwareButton::VolumeUp),
            Duration::from_millis(50)
        );
    }

    #[tokio::test]
    async fn semantic_taps_emit_ordered_edges_and_retain_failed_releases_for_cleanup() {
        let mut keyboard_cleanup = InputCleanupState {
            pressed_keys: BTreeMap::from([(0x05, 0b0000_0010)]),
            ..Default::default()
        };
        let mut keyboard = MockKeyboardStateSink::default();
        handle_keyboard_intent_with_sink(
            KeyboardIntent::Tap {
                usage: 0x04,
                modifiers: 0b0000_0001,
            },
            &mut keyboard_cleanup,
            &mut keyboard,
        )
        .await
        .unwrap();
        assert_eq!(
            keyboard.attempts,
            vec![vec![0x04, 0x05, 0xE0, 0xE1], vec![0x05, 0xE1]]
        );
        assert_eq!(
            keyboard_cleanup.pressed_keys,
            BTreeMap::from([(0x05, 0b0000_0010)])
        );

        let mut failed_keyboard_cleanup = InputCleanupState::default();
        let mut failed_keyboard = MockKeyboardStateSink {
            fail_at: Some(2),
            ..Default::default()
        };
        let failure = handle_keyboard_intent_with_sink(
            KeyboardIntent::Tap {
                usage: 0x04,
                modifiers: 0b1000_0001,
            },
            &mut failed_keyboard_cleanup,
            &mut failed_keyboard,
        )
        .await
        .unwrap_err();
        assert_eq!(failure.code, "input_delivery_failed");
        assert_eq!(
            failed_keyboard.attempts,
            vec![vec![0x04, 0xE0, 0xE7], Vec::new()]
        );
        assert_eq!(
            failed_keyboard_cleanup.pressed_keys,
            BTreeMap::from([(0x04, 0b1000_0001)])
        );

        let intent = crate::model::HardwareButtonIntent {
            button: DhHardwareButton::Home,
            phase: DhButtonPhase::Tap,
        };
        let mut button_cleanup = InputCleanupState::default();
        let mut button = MockHardwareButtonSink::default();
        handle_hardware_button_with_sink(intent, &mut button_cleanup, &mut button)
            .await
            .unwrap();
        assert_eq!(
            button.attempts,
            vec![
                (HardwareButton::Home, ButtonState::Down),
                (HardwareButton::Home, ButtonState::Up),
            ]
        );
        assert!(button_cleanup.pressed_buttons.is_empty());

        let mut failed_button_cleanup = InputCleanupState::default();
        let mut failed_button = MockHardwareButtonSink {
            fail_at: Some(2),
            ..Default::default()
        };
        let failure = handle_hardware_button_with_sink(
            intent,
            &mut failed_button_cleanup,
            &mut failed_button,
        )
        .await
        .unwrap_err();
        assert_eq!(failure.code, "input_delivery_failed");
        assert_eq!(
            failed_button.attempts,
            vec![
                (HardwareButton::Home, ButtonState::Down),
                (HardwareButton::Home, ButtonState::Up),
            ]
        );
        assert_eq!(
            failed_button_cleanup.pressed_buttons,
            vec![HardwareButton::Home]
        );
    }

    #[derive(Default)]
    struct MockReleaseSink {
        attempts: Vec<InputReleaseAction>,
        fail: Option<InputReleaseAction>,
    }

    impl InputReleaseSink for MockReleaseSink {
        async fn release(&mut self, action: InputReleaseAction) -> Result<(), HidError> {
            self.attempts.push(action);
            if self.fail == Some(action) {
                Err(HidError::Device(IdeviceError::ServiceNotFound))
            } else {
                Ok(())
            }
        }
    }

    #[test]
    fn release_all_is_reverse_ordered_idempotent_and_continues_after_failure() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let mut cleanup = InputCleanupState {
                touch_active: true,
                pressed_keys: BTreeMap::from([(0x04, 0), (0x05, 0b0000_0010)]),
                pressed_buttons: vec![HardwareButton::Home, HardwareButton::VolumeUp],
            };
            let mut sink = MockReleaseSink {
                fail: Some(InputReleaseAction::Keyboard),
                ..Default::default()
            };

            let failure = release_all_inputs_with_sink(&mut cleanup, &mut sink)
                .await
                .unwrap_err();
            assert_eq!(failure.stage, "input_cleanup");
            assert_eq!(
                sink.attempts,
                vec![
                    InputReleaseAction::Touch,
                    InputReleaseAction::Keyboard,
                    InputReleaseAction::HardwareButton(HardwareButton::VolumeUp),
                    InputReleaseAction::HardwareButton(HardwareButton::Home),
                ]
            );
            assert!(!cleanup.touch_active);
            assert_eq!(
                cleanup.pressed_keys,
                BTreeMap::from([(0x04, 0), (0x05, 0b0000_0010)])
            );
            assert!(cleanup.pressed_buttons.is_empty());

            let mut retry = MockReleaseSink::default();
            release_all_inputs_with_sink(&mut cleanup, &mut retry)
                .await
                .unwrap();
            assert_eq!(retry.attempts, vec![InputReleaseAction::Keyboard]);
            assert!(cleanup.release_plan().is_empty());

            let mut idempotent = MockReleaseSink::default();
            release_all_inputs_with_sink(&mut cleanup, &mut idempotent)
                .await
                .unwrap();
            assert!(idempotent.attempts.is_empty());
        });
    }

    #[test]
    fn orientation_mapping_fails_closed_for_unknown_values() {
        assert_eq!(
            orientation_value(&Orientation::LandscapeLeft),
            DhOrientation::LandscapeLeft
        );
        assert_eq!(
            effective_orientation(&Orientation::FaceUp, &Orientation::LandscapeRight).unwrap(),
            DhOrientation::LandscapeRight
        );
        assert_eq!(
            effective_orientation(&Orientation::Portrait, &Orientation::LandscapeRight).unwrap(),
            DhOrientation::Portrait
        );
        assert!(
            effective_orientation(
                &Orientation::Unknown("future".into()),
                &Orientation::FaceDown
            )
            .is_err()
        );
        assert_eq!(
            orientation_value(&Orientation::Unknown("future".into())),
            DhOrientation::Unknown
        );
        assert_eq!(orientation_from_raw(u32::MAX), DhOrientation::Unknown);
    }

    #[tokio::test]
    #[ignore = "requires an already-established trusted Xcode tunnel"]
    async fn live_ios_rsd_property_contract() {
        let target_name = std::env::var("DEVICE_HUB_TEST_TARGET_NAME")
            .expect("set DEVICE_HUB_TEST_TARGET_NAME to the explicit test device name");
        let endpoint = std::env::var("DEVICE_HUB_RSD_ENDPOINT")
            .expect("set DEVICE_HUB_RSD_ENDPOINT to the trusted tunnel RSD endpoint");
        let handshake = open_live_rsd_for_target(&target_name, &endpoint)
            .await
            .expect("guarded live RSD verification failed");
        let string_property = |key| {
            handshake
                .properties
                .get(key)
                .and_then(plist::Value::as_string)
        };

        println!(
            "OSVersion={:?} ProductVersion_present={} BuildVersion={:?} \
             UniqueDeviceID_present={} ProductType={:?}",
            string_property("OSVersion"),
            handshake.properties.contains_key("ProductVersion"),
            string_property("BuildVersion"),
            string_property("UniqueDeviceID").is_some(),
            string_property("ProductType"),
        );
        assert!(string_property("OSVersion").is_some());
        assert!(!handshake.properties.contains_key("ProductVersion"));
        assert!(string_property("UniqueDeviceID").is_some());
        assert!(string_property("ProductType").is_some());
    }
}

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

mod input;
mod support;
mod video;

use input::*;
use support::*;
use video::*;

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

#[cfg(test)]
#[path = "protocol/tests.rs"]
mod tests;

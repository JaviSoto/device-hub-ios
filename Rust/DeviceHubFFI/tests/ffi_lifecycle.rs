use std::{
    ffi::{CStr, c_void},
    ptr,
    sync::mpsc::{self, Receiver, Sender},
    time::Duration,
};

use device_hub_ffi::{
    DH_ABI_VERSION, DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS, DH_CAPABILITY_AUTHENTICATED_RECONNECT,
    DH_CAPABILITY_CONTROL_STREAM, DH_CAPABILITY_DEVELOPER_READINESS,
    DH_CAPABILITY_GENERATION_TAGGED_EVENTS, DH_CAPABILITY_HARDWARE_BUTTON_INPUT,
    DH_CAPABILITY_HEVC_ACCESS_UNITS, DH_CAPABILITY_KEYBOARD_INPUT,
    DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS, DH_CAPABILITY_PAIR_VERIFY_DISCOVERY,
    DH_CAPABILITY_PAIRABLE_HOST, DH_CAPABILITY_PNG_SCREENSHOT, DH_CAPABILITY_RAW_VIDEO_DATAGRAMS,
    DH_CAPABILITY_RELEASE_ALL_INPUT, DH_CAPABILITY_ROTATION, DH_CAPABILITY_RSD_METADATA,
    DH_CAPABILITY_SENSITIVE_INPUT_COPY, DH_CAPABILITY_SESSION_LIFECYCLE,
    DH_CAPABILITY_SPLIT_MEDIA_CALLBACK, DH_CAPABILITY_TOUCH_INPUT, DH_CAPABILITY_VIDEO_NEGOTIATION,
    DhBytes, DhConnectionPhase, DhControllerIdentity, DhError, DhEvent, DhEventKind, DhGeneration,
    DhPairingSessionConfig, DhPersistenceOutcome, DhSession, DhSessionState, DhStatus,
    dh_error_free, dh_error_json, dh_ffi_abi_version, dh_ffi_capabilities, dh_ffi_idevice_revision,
    dh_ffi_version, dh_pairing_session_create, dh_session_cancel, dh_session_complete_persistence,
    dh_session_free, dh_session_start,
};

#[derive(Debug, Eq, PartialEq)]
struct RecordedEvent {
    generation: DhGeneration,
    sequence: u64,
    kind: DhEventKind,
    state: DhSessionState,
    phase: DhConnectionPhase,
}

unsafe extern "C" fn record_event(event: *const DhEvent, context: *mut c_void) {
    // SAFETY: The fixture keeps both pointers alive until `dh_session_free`
    // returns, exactly as required by the public callback contract.
    let event = unsafe { &*event };
    // SAFETY: `context` was created from this exact boxed sender type.
    let sender = unsafe { &*context.cast::<Sender<RecordedEvent>>() };
    sender
        .send(RecordedEvent {
            generation: event.generation,
            sequence: event.sequence,
            kind: event.kind,
            state: event.state,
            phase: event.phase,
        })
        .expect("event receiver must remain alive");
}

struct Fixture {
    session: *mut DhSession,
    events: Receiver<RecordedEvent>,
    _callback_context: Box<Sender<RecordedEvent>>,
}

impl Fixture {
    fn create(generation: DhGeneration) -> Self {
        let (sender, events) = mpsc::channel();
        let mut callback_context = Box::new(sender);
        let identity = DhControllerIdentity {
            struct_size: size_of::<DhControllerIdentity>() as u32,
            abi_version: DH_ABI_VERSION,
            identifier: DhBytes::from_slice(b"1837DF10-6CE8-4272-BC85-D4B287E4D18F"),
            udid: DhBytes::from_slice(b"00008140-DEVICE-HUB-CONTROLLER"),
            long_term_secret_key: DhBytes::from_slice(&[7; 32]),
            alternate_irk: DhBytes::from_slice(&[9; 16]),
        };
        let config = DhPairingSessionConfig {
            struct_size: size_of::<DhPairingSessionConfig>() as u32,
            abi_version: DH_ABI_VERSION,
            generation,
            controller_identity: &identity,
            display_name: DhBytes::from_slice(b"Device Hub"),
            model: DhBytes::from_slice(b"Mac17,7"),
            requested_port: 0,
            reserved: [0; 6],
            callback: Some(record_event),
            callback_context: (&mut *callback_context as *mut Sender<RecordedEvent>).cast(),
        };
        let mut session = ptr::null_mut();
        let mut error = ptr::null_mut();

        // SAFETY: The complete config graph and both output locations remain
        // valid for this synchronous constructor call.
        let status = unsafe { dh_pairing_session_create(&config, &mut session, &mut error) };

        assert_eq!(status, DhStatus::Ok);
        assert!(!session.is_null());
        assert!(error.is_null());
        Self {
            session,
            events,
            _callback_context: callback_context,
        }
    }

    fn start(&self) {
        let mut error = ptr::null_mut();
        // SAFETY: The fixture exclusively owns a live session.
        let status = unsafe { dh_session_start(self.session, &mut error) };
        assert_eq!(status, DhStatus::Ok);
        assert!(error.is_null());
    }

    fn cancel(&self) {
        let mut error = ptr::null_mut();
        // SAFETY: The fixture exclusively owns a live session.
        let status = unsafe { dh_session_cancel(self.session, &mut error) };
        assert_eq!(status, DhStatus::Ok);
        assert!(error.is_null());
    }

    fn free(&mut self) {
        // SAFETY: This pointer is the fixture's sole owning session reference.
        let status = unsafe { dh_session_free(&mut self.session) };
        assert_eq!(status, DhStatus::Ok);
        assert!(self.session.is_null());
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if !self.session.is_null() {
            self.free();
        }
    }
}

#[test]
fn reports_the_exact_reviewed_abi_capability_set() {
    assert_eq!(DH_ABI_VERSION, 3);
    assert_eq!(dh_ffi_abi_version(), DH_ABI_VERSION);
    assert_eq!(
        dh_ffi_capabilities(),
        DH_CAPABILITY_SESSION_LIFECYCLE
            | DH_CAPABILITY_GENERATION_TAGGED_EVENTS
            | DH_CAPABILITY_SENSITIVE_INPUT_COPY
            | DH_CAPABILITY_PAIRABLE_HOST
            | DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS
            | DH_CAPABILITY_AUTHENTICATED_RECONNECT
            | DH_CAPABILITY_RSD_METADATA
            | DH_CAPABILITY_PNG_SCREENSHOT
            | DH_CAPABILITY_DEVELOPER_READINESS
            | DH_CAPABILITY_CONTROL_STREAM
            | DH_CAPABILITY_VIDEO_NEGOTIATION
            | DH_CAPABILITY_RAW_VIDEO_DATAGRAMS
            | DH_CAPABILITY_HEVC_ACCESS_UNITS
            | DH_CAPABILITY_TOUCH_INPUT
            | DH_CAPABILITY_KEYBOARD_INPUT
            | DH_CAPABILITY_HARDWARE_BUTTON_INPUT
            | DH_CAPABILITY_ROTATION
            | DH_CAPABILITY_SPLIT_MEDIA_CALLBACK
            | DH_CAPABILITY_RELEASE_ALL_INPUT
            | DH_CAPABILITY_MEDIA_GEOMETRY_SNAPSHOTS
            | DH_CAPABILITY_PAIR_VERIFY_DISCOVERY
    );

    // SAFETY: Both functions return process-lifetime NUL-terminated strings.
    let version = unsafe { CStr::from_ptr(dh_ffi_version()) }
        .to_str()
        .expect("version must be UTF-8");
    assert_eq!(version, env!("CARGO_PKG_VERSION"));

    // SAFETY: The revision function has the same process-lifetime contract.
    let revision = unsafe { CStr::from_ptr(dh_ffi_idevice_revision()) }
        .to_str()
        .expect("revision must be UTF-8");
    assert_eq!(revision, "a64b8867815b3da17b5c927531bdba877e8456ef");
}

#[test]
fn advertises_authenticated_pair_verify_discovery() {
    assert_ne!(
        dh_ffi_capabilities() & DH_CAPABILITY_PAIR_VERIFY_DISCOVERY,
        0,
        "controllers need an explicit capability gate before candidate probing"
    );
}

#[test]
fn start_and_cancel_deliver_one_serial_generation_tagged_terminal_event() {
    let generation = DhGeneration {
        high: 0x1020_3040_5060_7080,
        low: 0x90A0_B0C0_D0E0_F001,
    };
    let fixture = Fixture::create(generation);

    fixture.start();
    let started = fixture
        .events
        .recv_timeout(Duration::from_secs(2))
        .expect("session-started callback");
    assert_eq!(
        started,
        RecordedEvent {
            generation,
            sequence: 1,
            kind: DhEventKind::SessionStarted,
            state: DhSessionState::Running,
            phase: DhConnectionPhase::Idle,
        }
    );

    fixture.cancel();
    fixture.cancel();

    let mut last_sequence = started.sequence;
    loop {
        let event = fixture
            .events
            .recv_timeout(Duration::from_secs(2))
            .expect("terminal cancellation callback");
        assert_eq!(event.generation, generation);
        assert_eq!(event.sequence, last_sequence + 1);
        last_sequence = event.sequence;
        if event.kind == DhEventKind::SessionCancelled {
            assert_eq!(event.state, DhSessionState::Cancelled);
            break;
        }
    }
    assert!(
        fixture
            .events
            .recv_timeout(Duration::from_millis(100))
            .is_err(),
        "terminal cancellation must be unique and suppress later events"
    );
}

#[test]
fn cancellation_before_start_and_pointer_to_pointer_free_are_idempotent() {
    let mut fixture = Fixture::create(DhGeneration { high: 3, low: 5 });

    fixture.cancel();
    fixture.cancel();
    assert!(
        fixture
            .events
            .recv_timeout(Duration::from_millis(50))
            .is_err(),
        "a session cancelled before start must not begin callback delivery"
    );

    fixture.free();
    fixture.free();
    // SAFETY: A null storage pointer is invalid by contract; no memory is read.
    assert_eq!(
        unsafe { dh_session_free(ptr::null_mut()) },
        DhStatus::InvalidArgument
    );
}

#[test]
fn persistence_ack_requires_a_live_matching_request() {
    let fixture = Fixture::create(DhGeneration { high: 8, low: 13 });
    let mut error = ptr::null_mut();

    // SAFETY: The session is live, but no persistence request is pending.
    let status = unsafe {
        dh_session_complete_persistence(
            fixture.session,
            1,
            DhPersistenceOutcome::Succeeded as u32,
            &mut error,
        )
    };

    assert_eq!(status, DhStatus::InvalidState);
    assert!(!error.is_null());
    // SAFETY: `error` is live and uniquely owned until the free below.
    let json = unsafe { CStr::from_ptr(dh_error_json(error)) }
        .to_str()
        .expect("error JSON must be UTF-8");
    assert!(json.contains("\"code\":\"invalid_state\""));
    assert!(json.contains("\"stage\":\"pair_record_persistence\""));
    // SAFETY: `error` is the sole owned pointer returned by this ABI.
    unsafe { dh_error_free(&mut error) };
    assert!(error.is_null());
}

#[test]
fn invalid_configuration_returns_an_owned_sanitized_error() {
    let secret_key = b"secret-key-material-must-not-leak";
    let secret_irk = b"private-irk-data";
    let identity = DhControllerIdentity {
        struct_size: size_of::<DhControllerIdentity>() as u32,
        abi_version: DH_ABI_VERSION,
        identifier: DhBytes::from_slice(b"1837DF10-6CE8-4272-BC85-D4B287E4D18F"),
        udid: DhBytes::from_slice(b"00008140-DEVICE-HUB-CONTROLLER"),
        long_term_secret_key: DhBytes::from_slice(secret_key),
        alternate_irk: DhBytes::from_slice(secret_irk),
    };
    let config = DhPairingSessionConfig {
        struct_size: 0,
        abi_version: DH_ABI_VERSION,
        generation: DhGeneration { high: 1, low: 1 },
        controller_identity: &identity,
        display_name: DhBytes::from_slice(b"Device Hub"),
        model: DhBytes::from_slice(b"Mac17,7"),
        requested_port: 0,
        reserved: [0; 6],
        callback: Some(record_event),
        callback_context: ptr::null_mut(),
    };
    let mut session = ptr::null_mut();
    let mut error: *mut DhError = ptr::null_mut();

    // SAFETY: The input graph and output locations are valid for this call.
    let status = unsafe { dh_pairing_session_create(&config, &mut session, &mut error) };

    assert_eq!(status, DhStatus::InvalidArgument);
    assert!(session.is_null());
    assert!(!error.is_null());
    // SAFETY: `error` remains live until the pointer-to-pointer free.
    let json = unsafe { CStr::from_ptr(dh_error_json(error)) }
        .to_str()
        .expect("error JSON must be UTF-8");
    assert!(json.contains("\"code\":\"invalid_argument\""));
    assert!(json.contains("\"stage\":\"ffi_boundary\""));
    assert!(!json.contains("secret-key-material-must-not-leak"));
    assert!(!json.contains("private-irk-data"));

    // SAFETY: The first call consumes the sole owner and nulls it; the second
    // call proves that null storage is an idempotent no-op.
    unsafe {
        dh_error_free(&mut error);
        dh_error_free(&mut error);
    }
    assert!(error.is_null());
    // SAFETY: Null error inspection is explicitly supported.
    assert!(unsafe { dh_error_json(error) }.is_null());
}

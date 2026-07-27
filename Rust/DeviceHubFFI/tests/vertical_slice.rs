use std::{
    ffi::c_void,
    ptr,
    sync::mpsc::{self, Receiver, Sender},
    time::Duration,
};

use device_hub_ffi::{
    DH_ABI_VERSION, DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS, DH_CAPABILITY_AUTHENTICATED_RECONNECT,
    DH_CAPABILITY_PAIR_VERIFY_DISCOVERY, DH_CAPABILITY_PAIRABLE_HOST, DH_CAPABILITY_PNG_SCREENSHOT,
    DH_CAPABILITY_RSD_METADATA, DhBytes, DhControllerIdentity, DhEvent, DhEventKind, DhGeneration,
    DhPairingSessionConfig, DhSession, DhStatus, dh_ffi_capabilities, dh_pairing_session_create,
    dh_session_cancel, dh_session_free, dh_session_start,
};

#[derive(Debug)]
struct RecordedEvent {
    kind: DhEventKind,
    value: u64,
}

unsafe extern "C" fn record_event(event: *const DhEvent, context: *mut c_void) {
    // SAFETY: The fixture keeps the event sender alive until session teardown.
    let event = unsafe { &*event };
    // SAFETY: `context` was created from this exact boxed sender type.
    let sender = unsafe { &*context.cast::<Sender<RecordedEvent>>() };
    sender
        .send(RecordedEvent {
            kind: event.kind,
            value: event.value,
        })
        .expect("event receiver remains alive");
}

struct PairingFixture {
    callback_context: Box<Sender<RecordedEvent>>,
    events: Receiver<RecordedEvent>,
    session: *mut DhSession,
}

impl PairingFixture {
    fn create() -> Self {
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
            generation: DhGeneration {
                high: 0x1122,
                low: 0x3344,
            },
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

        let status = unsafe { dh_pairing_session_create(&config, &mut session, &mut error) };

        assert_eq!(status, DhStatus::Ok);
        assert!(!session.is_null());
        assert!(error.is_null());
        Self {
            callback_context,
            events,
            session,
        }
    }
}

impl Drop for PairingFixture {
    fn drop(&mut self) {
        let _ = &self.callback_context;
        let status = unsafe { dh_session_free(&mut self.session) };
        assert_eq!(status, DhStatus::Ok);
        assert!(self.session.is_null());
    }
}

#[test]
fn real_vertical_slice_capabilities_are_declared_together() {
    let capabilities = dh_ffi_capabilities();

    for capability in [
        DH_CAPABILITY_PAIRABLE_HOST,
        DH_CAPABILITY_ACKNOWLEDGED_PAIR_RECORDS,
        DH_CAPABILITY_AUTHENTICATED_RECONNECT,
        DH_CAPABILITY_PAIR_VERIFY_DISCOVERY,
        DH_CAPABILITY_RSD_METADATA,
        DH_CAPABILITY_PNG_SCREENSHOT,
    ] {
        assert_ne!(capabilities & capability, 0);
    }
}

#[test]
fn pairing_start_binds_before_announcing_the_listener_port() {
    let fixture = PairingFixture::create();
    let mut error = ptr::null_mut();

    let status = unsafe { dh_session_start(fixture.session, &mut error) };

    assert_eq!(status, DhStatus::Ok);
    assert!(error.is_null());
    assert_eq!(
        fixture
            .events
            .recv_timeout(Duration::from_secs(2))
            .expect("session-started event")
            .kind,
        DhEventKind::SessionStarted
    );
    let listener = loop {
        let event = fixture
            .events
            .recv_timeout(Duration::from_secs(2))
            .expect("pairing-listener-ready event");
        if event.kind == DhEventKind::PairingListenerReady {
            break event;
        }
        assert_eq!(
            event.kind,
            DhEventKind::PhaseChanged,
            "only phase progress may precede the bound-listener event"
        );
    };
    assert_eq!(listener.kind, DhEventKind::PairingListenerReady);
    assert!(u16::try_from(listener.value).is_ok_and(|port| port != 0));
}

#[test]
fn cancellation_and_pointer_to_pointer_free_are_idempotent() {
    let mut fixture = PairingFixture::create();
    let mut error = ptr::null_mut();
    assert_eq!(
        unsafe { dh_session_start(fixture.session, &mut error) },
        DhStatus::Ok
    );
    assert_eq!(
        unsafe { dh_session_cancel(fixture.session, &mut error) },
        DhStatus::Ok
    );

    assert_eq!(
        unsafe { dh_session_free(&mut fixture.session) },
        DhStatus::Ok
    );
    assert_eq!(
        unsafe { dh_session_free(&mut fixture.session) },
        DhStatus::Ok
    );
    assert!(fixture.session.is_null());
}

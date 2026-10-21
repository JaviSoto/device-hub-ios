use std::{
    sync::{
        Condvar,
        atomic::{AtomicUsize, Ordering as AtomicOrdering},
    },
    time::Duration,
};

use super::*;

fn gate_fixture() -> (
    PersistenceGate,
    mpsc::Sender<PersistenceAck>,
    Receiver<EventMessage>,
    Arc<AtomicU64>,
) {
    let (event_sender, events) = sync_channel(8);
    let emitter = EventEmitter {
        sender: event_sender,
        terminal: Arc::new(AtomicU8::new(TERMINAL_NONE)),
        ordering: Arc::new(StdMutex::new(())),
    };
    let (sender, receiver) = mpsc::channel(4);
    let pending = Arc::new(AtomicU64::new(0));
    (
        PersistenceGate {
            acknowledgements: Arc::new(AsyncMutex::new(receiver)),
            emitter,
            next_request_id: Arc::new(AtomicU64::new(1)),
            pending_request_id: Arc::clone(&pending),
        },
        sender,
        events,
        pending,
    )
}

fn peer() -> PeerRecord {
    PeerRecord {
        device_id: "device".into(),
        account_identifier: "peer".into(),
        peer_identifier: "peer".into(),
        peer_public_key: [1; 32],
        peer_alternate_irk: [2; 16],
        display_name: "Target".into(),
        product_type: "iPhone19,1".into(),
        completion: crate::abi::DhPairingCompletion::Provisional,
    }
}

#[test]
fn persistence_gate_never_completes_before_matching_acknowledgement() {
    let (gate, acknowledgements, events, pending) = gate_fixture();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async move {
        let task = tokio::spawn(async move {
            gate.persist(DhEventKind::PairRecordProvisional, peer())
                .await
        });
        let request_id = tokio::task::spawn_blocking(move || {
            match events.recv_timeout(Duration::from_secs(1)).unwrap() {
                EventMessage::PairRecord { request_id, .. } => request_id,
                _ => panic!("expected pair-record event"),
            }
        })
        .await
        .unwrap();
        assert!(!task.is_finished());
        acknowledgements
            .send(PersistenceAck {
                request_id,
                outcome: DhPersistenceOutcome::Succeeded,
            })
            .await
            .unwrap();
        assert!(task.await.unwrap().is_ok());
        assert_eq!(pending.load(Ordering::Acquire), 0);
    });
}

#[test]
fn failed_or_mismatched_acknowledgement_fails_closed() {
    for mismatch in [false, true] {
        let (gate, acknowledgements, events, _) = gate_fixture();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let task = tokio::spawn(async move {
                gate.persist(DhEventKind::PairRecordProvisional, peer())
                    .await
            });
            let request_id = tokio::task::spawn_blocking(move || {
                match events.recv_timeout(Duration::from_secs(1)).unwrap() {
                    EventMessage::PairRecord { request_id, .. } => request_id,
                    _ => panic!("expected pair-record event"),
                }
            })
            .await
            .unwrap();
            acknowledgements
                .send(PersistenceAck {
                    request_id: request_id + u64::from(mismatch),
                    outcome: DhPersistenceOutcome::Failed,
                })
                .await
                .unwrap();
            assert!(task.await.unwrap().is_err());
        });
    }
}

#[test]
fn persistence_request_ids_wrap_without_using_zero_or_the_ack_sentinel() {
    let (gate, _, _, _) = gate_fixture();
    gate.next_request_id
        .store(ACK_RESERVED - 1, Ordering::Relaxed);

    assert_eq!(gate.allocate_request_id(), ACK_RESERVED - 1);
    assert_eq!(gate.allocate_request_id(), 1);

    gate.next_request_id.store(ACK_RESERVED, Ordering::Relaxed);
    assert_eq!(gate.allocate_request_id(), 1);
    assert_eq!(gate.allocate_request_id(), 2);
}

#[test]
fn worker_completion_cannot_overwrite_a_winning_cancellation() {
    let (sender, events) = sync_channel(2);
    let emitter = EventEmitter {
        sender,
        terminal: Arc::new(AtomicU8::new(TERMINAL_NONE)),
        ordering: Arc::new(StdMutex::new(())),
    };
    let lifecycle = AtomicU8::new(STATE_CANCELLED);
    emitter.cancel();

    settle_worker(Some(Ok(())), &emitter, &lifecycle);

    assert_eq!(lifecycle.load(Ordering::Acquire), STATE_CANCELLED);
    assert!(matches!(events.recv().unwrap(), EventMessage::Cancelled));
    assert!(events.try_recv().is_err());
}

#[derive(Default)]
struct MediaCapture {
    events: StdMutex<Vec<(u64, DhEventKind, Vec<u8>)>>,
}

unsafe extern "C" fn capture_media_event(event: *const DhEvent, context: *mut c_void) {
    // SAFETY: Tests pass live pointers for the complete callback.
    let event = unsafe { &*event };
    // SAFETY: Tests pass a live `MediaCapture` as callback context.
    let capture = unsafe { &*(context.cast::<MediaCapture>()) };
    let bytes = if event.video_datagram.is_null() {
        Vec::new()
    } else {
        // SAFETY: Media event views are live for the callback.
        let datagram = unsafe { &*event.video_datagram };
        // SAFETY: The callback contract guarantees the byte span.
        unsafe { std::slice::from_raw_parts(datagram.bytes.data, datagram.bytes.count) }.to_vec()
    };
    capture
        .events
        .lock()
        .unwrap()
        .push((event.sequence, event.kind, bytes));
}

#[test]
fn media_callbacks_are_synchronous_exactly_ordered_and_media_local() {
    let capture = MediaCapture::default();
    let generation = DhGeneration { high: 1, low: 2 };
    let media = MediaEmitter::new(
        generation,
        Some(capture_media_event),
        std::ptr::from_ref(&capture).cast_mut().cast(),
    );

    media.video_datagram(vec![1, 2], 50_001).unwrap();
    media.video_datagram(vec![3], 50_001).unwrap();

    assert_eq!(
        *capture.events.lock().unwrap(),
        vec![
            (1, DhEventKind::VideoDatagram, vec![1, 2]),
            (2, DhEventKind::VideoDatagram, vec![3]),
        ]
    );
}

#[derive(Default)]
struct AccessUnitCapture {
    events: StdMutex<Vec<(u64, DhEventKind, DhDisplayGeometry)>>,
}

unsafe extern "C" fn capture_access_unit(event: *const DhEvent, context: *mut c_void) {
    // SAFETY: Tests pass live pointers for the complete callback.
    let event = unsafe { &*event };
    // SAFETY: Tests pass a live `AccessUnitCapture` as callback context.
    let capture = unsafe { &*(context.cast::<AccessUnitCapture>()) };
    // SAFETY: This callback is installed only for access-unit events.
    let access_unit = unsafe { &*event.video_access_unit };
    capture
        .events
        .lock()
        .unwrap()
        .push((event.sequence, event.kind, access_unit.geometry));
}

#[test]
fn access_units_carry_the_authoritative_geometry_on_the_media_sequence() {
    let capture = AccessUnitCapture::default();
    let media = MediaEmitter::new(
        DhGeneration { high: 9, low: 10 },
        Some(capture_access_unit),
        std::ptr::from_ref(&capture).cast_mut().cast(),
    );
    let landscape = DhDisplayGeometry {
        pixel_width: 2_796,
        pixel_height: 1_290,
        orientation: DhOrientation::LandscapeLeft as u32,
        non_flat_orientation: DhOrientation::LandscapeLeft as u32,
        orientation_locked: 0,
        reserved: [0; 7],
    };
    let portrait = DhDisplayGeometry {
        pixel_width: 1_290,
        pixel_height: 2_796,
        orientation: DhOrientation::Portrait as u32,
        non_flat_orientation: DhOrientation::Portrait as u32,
        orientation_locked: 1,
        reserved: [0; 7],
    };
    let access_unit = |rtp_timestamp| HevcAccessUnit {
        ssrc: 0x1234_5678,
        rtp_timestamp,
        first_sequence_number: 1,
        last_sequence_number: 1,
        parameter_set_revision: 1,
        is_sync: true,
        bytes: vec![0, 0, 0, 2, 0x26, 0x01],
    };

    media
        .video_access_unit(access_unit(100), landscape)
        .unwrap();
    media.video_access_unit(access_unit(200), portrait).unwrap();

    let events = capture.events.lock().unwrap();
    assert_eq!(events.len(), 2);
    assert_eq!(
        (events[0].0, events[0].1),
        (1, DhEventKind::VideoAccessUnit)
    );
    assert_eq!(events[0].2.pixel_width, 2_796);
    assert_eq!(events[0].2.pixel_height, 1_290);
    assert_eq!(events[0].2.orientation, DhOrientation::LandscapeLeft as u32);
    assert_eq!(
        (events[1].0, events[1].1),
        (2, DhEventKind::VideoAccessUnit)
    );
    assert_eq!(events[1].2.pixel_width, 1_290);
    assert_eq!(events[1].2.pixel_height, 2_796);
    assert_eq!(events[1].2.orientation, DhOrientation::Portrait as u32);
    assert_eq!(events[1].2.orientation_locked, 1);
}

struct BlockingCapture {
    entered: AtomicBool,
    release: AtomicBool,
    count: AtomicUsize,
    signal: Condvar,
    lock: StdMutex<()>,
}

impl Default for BlockingCapture {
    fn default() -> Self {
        Self {
            entered: AtomicBool::new(false),
            release: AtomicBool::new(false),
            count: AtomicUsize::new(0),
            signal: Condvar::new(),
            lock: StdMutex::new(()),
        }
    }
}

unsafe extern "C" fn blocking_media_event(_event: *const DhEvent, context: *mut c_void) {
    // SAFETY: Tests pass a live `BlockingCapture` as callback context.
    let capture = unsafe { &*(context.cast::<BlockingCapture>()) };
    capture.entered.store(true, Ordering::Release);
    capture.signal.notify_all();
    let mut guard = capture.lock.lock().unwrap();
    while !capture.release.load(Ordering::Acquire) {
        guard = capture.signal.wait(guard).unwrap();
    }
    capture.count.fetch_add(1, AtomicOrdering::AcqRel);
}

#[test]
fn disabling_media_waits_for_inflight_callback_and_prevents_later_callbacks() {
    let capture = BlockingCapture::default();
    let media = MediaEmitter::new(
        DhGeneration { high: 3, low: 4 },
        Some(blocking_media_event),
        std::ptr::from_ref(&capture).cast_mut().cast(),
    );
    let producer_media = media.clone();
    let producer = thread::spawn(move || {
        producer_media.video_datagram(vec![1], 50_001).unwrap();
    });

    let mut guard = capture.lock.lock().unwrap();
    while !capture.entered.load(Ordering::Acquire) {
        let (next, timeout) = capture
            .signal
            .wait_timeout(guard, Duration::from_secs(1))
            .unwrap();
        assert!(!timeout.timed_out());
        guard = next;
    }
    drop(guard);

    let (disabled, disabled_receiver) = sync_channel(1);
    let disabling_media = media.clone();
    let disabler = thread::spawn(move || {
        disabling_media.disable();
        disabled.send(()).unwrap();
    });
    assert!(
        disabled_receiver
            .recv_timeout(Duration::from_millis(30))
            .is_err()
    );

    capture.release.store(true, Ordering::Release);
    capture.signal.notify_all();
    disabled_receiver
        .recv_timeout(Duration::from_secs(1))
        .unwrap();
    producer.join().unwrap();
    disabler.join().unwrap();

    media.video_datagram(vec![2], 50_001).unwrap();
    assert_eq!(capture.count.load(AtomicOrdering::Acquire), 1);
}

unsafe extern "C" fn capture_control_kind(event: *const DhEvent, context: *mut c_void) {
    // SAFETY: Tests pass live callback pointers and context.
    let event = unsafe { &*event };
    // SAFETY: Context points to a live sender until dispatcher join.
    let sender = unsafe { &*(context.cast::<SyncSender<DhEventKind>>()) };
    sender.send(event.kind).unwrap();
}

#[test]
fn media_flood_cannot_starve_terminal_control_delivery() {
    let (event_sender, event_receiver) = sync_channel(EVENT_QUEUE_CAPACITY);
    let emitter = EventEmitter {
        sender: event_sender,
        terminal: Arc::new(AtomicU8::new(TERMINAL_NONE)),
        ordering: Arc::new(StdMutex::new(())),
    };
    let enabled = Arc::new(AtomicBool::new(true));
    let (captured_sender, captured_receiver) = sync_channel::<DhEventKind>(8);
    let dispatcher_enabled = Arc::clone(&enabled);
    let generation = DhGeneration { high: 5, low: 6 };
    let context = std::ptr::from_ref(&captured_sender)
        .cast_mut()
        .cast::<c_void>() as usize;
    let dispatcher = thread::spawn(move || {
        dispatch_events(
            event_receiver,
            dispatcher_enabled,
            generation,
            capture_control_kind,
            context,
        );
    });

    let media_count = AtomicUsize::new(0);
    unsafe extern "C" fn slow_media(_event: *const DhEvent, context: *mut c_void) {
        // SAFETY: Test context is a live atomic counter.
        let count = unsafe { &*(context.cast::<AtomicUsize>()) };
        count.fetch_add(1, AtomicOrdering::AcqRel);
        thread::sleep(Duration::from_millis(1));
    }
    let media = MediaEmitter::new(
        generation,
        Some(slow_media),
        std::ptr::from_ref(&media_count).cast_mut().cast(),
    );
    let flooding_media = media.clone();
    let flood = thread::spawn(move || {
        for value in 0..1_000_u16 {
            flooding_media
                .video_datagram(value.to_be_bytes().to_vec(), 50_001)
                .unwrap();
        }
    });

    while media_count.load(AtomicOrdering::Acquire) == 0 {
        thread::yield_now();
    }
    emitter.fail(PublicFailure::new(
        "test_failure",
        "test",
        false,
        "terminal",
    ));
    assert_eq!(
        captured_receiver
            .recv_timeout(Duration::from_millis(100))
            .unwrap(),
        DhEventKind::SessionFailed
    );
    assert!(media_count.load(AtomicOrdering::Acquire) < 1_000);

    media.disable();
    flood.join().unwrap();
    enabled.store(false, Ordering::Release);
    emitter.sender.send(EventMessage::Shutdown).unwrap();
    dispatcher.join().unwrap();
}

#[test]
fn terminal_cancellation_is_last_on_both_callback_planes() {
    let (event_sender, event_receiver) = sync_channel(EVENT_QUEUE_CAPACITY);
    let emitter = EventEmitter {
        sender: event_sender,
        terminal: Arc::new(AtomicU8::new(TERMINAL_NONE)),
        ordering: Arc::new(StdMutex::new(())),
    };
    let enabled = Arc::new(AtomicBool::new(true));
    let (captured_sender, captured_receiver) = sync_channel::<DhEventKind>(8);
    let generation = DhGeneration { high: 7, low: 8 };
    let context = std::ptr::from_ref(&captured_sender)
        .cast_mut()
        .cast::<c_void>() as usize;
    let dispatcher_enabled = Arc::clone(&enabled);
    let dispatcher = thread::spawn(move || {
        dispatch_events(
            event_receiver,
            dispatcher_enabled,
            generation,
            capture_control_kind,
            context,
        );
    });
    let capture = MediaCapture::default();
    let media = MediaEmitter::new(
        generation,
        Some(capture_media_event),
        std::ptr::from_ref(&capture).cast_mut().cast(),
    );

    media.disable();
    emitter.cancel();
    emitter.drain().unwrap();
    emitter
        .phase(DhConnectionPhase::Streaming, DhSessionState::Connected)
        .unwrap();
    media.video_datagram(vec![1], 50_001).unwrap();

    assert_eq!(
        captured_receiver
            .recv_timeout(Duration::from_secs(1))
            .unwrap(),
        DhEventKind::SessionCancelled
    );
    assert!(captured_receiver.try_recv().is_err());
    assert!(capture.events.lock().unwrap().is_empty());

    enabled.store(false, Ordering::Release);
    emitter.sender.send(EventMessage::Shutdown).unwrap();
    dispatcher.join().unwrap();
}

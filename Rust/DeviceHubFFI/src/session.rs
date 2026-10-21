//! Cancellable worker lifecycle and serialized callback delivery.

mod callbacks;
use callbacks::{invoke_callback, invoke_media_callback};

use std::{
    cell::Cell,
    ffi::c_void,
    mem::size_of,
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering},
        mpsc::{Receiver, SyncSender, sync_channel},
    },
    thread::{self, JoinHandle},
};

use idevice::core_device::{HevcAccessUnit, HevcParameterSets};
use idevice::{IdeviceError, remote_pairing::errors::RemotePairingError};
use serde::Serialize;
use tokio::sync::{Mutex as AsyncMutex, mpsc, watch};
use zeroize::Zeroizing;

use crate::{
    abi::{
        DH_ABI_VERSION, DhBytes, DhConnectionPhase, DhDisplayGeometry, DhEvent, DhEventCallback,
        DhEventKind, DhGeneration, DhMediaEventCallback, DhOrientation, DhPersistenceOutcome,
        DhRsdMetadata, DhSessionState, DhStatus, DhVerifiedPeer, DhVideoAccessUnit,
        DhVideoConfiguration, DhVideoDatagram, DhVideoDiscontinuity, DhVideoNegotiationOutcome,
    },
    model::{
        HardwareButtonIntent, KeyboardIntent, Operation, PeerRecord, RotationIntent, TouchIntent,
        VideoControlDatagram,
    },
    png::PngDimensions,
};

const EVENT_QUEUE_CAPACITY: usize = 32;
const ACK_QUEUE_CAPACITY: usize = 4;
const CONTROL_QUEUE_CAPACITY: usize = 128;
const STATE_READY: u8 = 0;
const STATE_RUNNING: u8 = 1;
const STATE_CANCELLED: u8 = 2;
const STATE_TERMINAL: u8 = 3;
const STATE_STOPPED: u8 = 4;
const TERMINAL_NONE: u8 = 0;
const TERMINAL_COMPLETED: u8 = 1;
const TERMINAL_FAILED: u8 = 2;
const TERMINAL_CANCELLED: u8 = 3;
const ACK_RESERVED: u64 = u64::MAX;

thread_local! {
    static INSIDE_CALLBACK: Cell<bool> = const { Cell::new(false) };
    static INSIDE_MEDIA_CALLBACK: Cell<bool> = const { Cell::new(false) };
}

/// True only on the private dispatcher while it is invoking foreign code.
pub(crate) fn inside_callback() -> bool {
    INSIDE_CALLBACK.with(Cell::get)
}

struct CallbackScope;

impl CallbackScope {
    fn enter() -> Self {
        INSIDE_CALLBACK.with(|flag| flag.set(true));
        Self
    }
}

struct MediaCallbackScope;

impl MediaCallbackScope {
    fn enter() -> Self {
        INSIDE_CALLBACK.with(|flag| flag.set(true));
        INSIDE_MEDIA_CALLBACK.with(|flag| flag.set(true));
        Self
    }
}

impl Drop for MediaCallbackScope {
    fn drop(&mut self) {
        INSIDE_MEDIA_CALLBACK.with(|flag| flag.set(false));
        INSIDE_CALLBACK.with(|flag| flag.set(false));
    }
}

impl Drop for CallbackScope {
    fn drop(&mut self) {
        INSIDE_CALLBACK.with(|flag| flag.set(false));
    }
}

/// Sanitized asynchronous operation failure.
#[derive(Clone, Copy, Debug)]
pub(crate) struct PublicFailure {
    pub(crate) code: &'static str,
    pub(crate) stage: &'static str,
    pub(crate) retryable: bool,
    pub(crate) message: &'static str,
}

impl PublicFailure {
    pub(crate) const fn new(
        code: &'static str,
        stage: &'static str,
        retryable: bool,
        message: &'static str,
    ) -> Self {
        Self {
            code,
            stage,
            retryable,
            message,
        }
    }
}

#[derive(Serialize)]
struct FailureWire<'a> {
    code: &'a str,
    stage: &'a str,
    retryable: bool,
    message: &'a str,
}

#[derive(Debug)]
pub(crate) struct RsdSnapshot {
    pub(crate) uuid: String,
    pub(crate) operating_system_version: String,
    pub(crate) build_version: String,
    pub(crate) unique_device_id: String,
    pub(crate) product_type: String,
    pub(crate) protocol_version: u64,
    pub(crate) service_count: u64,
    pub(crate) screenshot_service_available: bool,
}

enum EventMessage {
    Started,
    Phase {
        phase: DhConnectionPhase,
        state: DhSessionState,
    },
    ListenerReady(u16),
    PairingCode(Zeroizing<String>),
    PairRecord {
        kind: DhEventKind,
        request_id: u64,
        peer: PeerRecord,
    },
    Authenticated,
    RsdReady(RsdSnapshot),
    Screenshot {
        bytes: Vec<u8>,
        dimensions: PngDimensions,
    },
    InputReady,
    DisplayGeometry(DhDisplayGeometry),
    Completed,
    Failed(Vec<u8>),
    Cancelled,
    Barrier(SyncSender<()>),
    Shutdown,
}

enum MediaEventMessage {
    Datagram {
        bytes: Vec<u8>,
        source_port: u16,
    },
    Configuration {
        configuration: HevcParameterSets,
        orientation: DhOrientation,
    },
    AccessUnit {
        access_unit: HevcAccessUnit,
        geometry: DhDisplayGeometry,
    },
    Discontinuity(DhVideoDiscontinuity),
}

/// Ordered commands copied from synchronous ABI calls into the protocol task.
pub(crate) enum ControlCommand {
    VideoNegotiation,
    VideoControlDatagram(VideoControlDatagram),
    Touch(TouchIntent),
    Keyboard(KeyboardIntent),
    HardwareButton(HardwareButtonIntent),
    Rotate(RotationIntent),
    ReleaseAllInput,
}

/// Protocol-owned receive side and readiness gates for generation-safe control.
pub(crate) struct ControlGate {
    receiver: mpsc::Receiver<ControlCommand>,
    input_ready: Arc<AtomicBool>,
    video_control_ready: Arc<AtomicBool>,
    video_negotiation_pending: Arc<AtomicBool>,
}

impl ControlGate {
    pub(crate) fn enable_input(&self) {
        self.input_ready.store(true, Ordering::Release);
    }

    pub(crate) async fn receive(&mut self) -> Option<ControlCommand> {
        self.receiver.recv().await
    }
}

impl Drop for ControlGate {
    fn drop(&mut self) {
        self.input_ready.store(false, Ordering::Release);
        self.video_control_ready.store(false, Ordering::Release);
        self.video_negotiation_pending
            .store(false, Ordering::Release);
    }
}

#[derive(Clone)]
pub(crate) struct EventEmitter {
    sender: SyncSender<EventMessage>,
    terminal: Arc<AtomicU8>,
    ordering: Arc<StdMutex<()>>,
}

#[cfg(test)]
/// Retains a control-event receiver while protocol tests exercise the emitter.
pub(crate) struct EventEmitterTestFixture {
    emitter: EventEmitter,
    events: Receiver<EventMessage>,
}

#[cfg(test)]
impl EventEmitterTestFixture {
    /// Creates a non-dispatching control emitter with its receiver kept alive.
    pub(crate) fn new() -> Self {
        let (sender, events) = sync_channel(EVENT_QUEUE_CAPACITY);
        Self {
            emitter: EventEmitter {
                sender,
                terminal: Arc::new(AtomicU8::new(TERMINAL_NONE)),
                ordering: Arc::new(StdMutex::new(())),
            },
            events,
        }
    }

    /// Returns the emitter half used by the protocol under test.
    pub(crate) fn emitter(&self) -> EventEmitter {
        self.emitter.clone()
    }

    /// Drains and counts events pending on the retained test receiver.
    pub(crate) fn pending_event_count(&self) -> usize {
        self.events.try_iter().count()
    }
}

impl EventEmitter {
    fn send(&self, event: EventMessage) -> Result<(), PublicFailure> {
        let _ordering = self.ordering.lock().map_err(|_| {
            PublicFailure::new(
                "event_dispatch_unavailable",
                "session_dispatch",
                false,
                "The native event dispatcher ordering gate failed.",
            )
        })?;
        if self.terminal.load(Ordering::Acquire) != TERMINAL_NONE {
            return Ok(());
        }
        self.sender.send(event).map_err(|_| {
            PublicFailure::new(
                "event_dispatch_unavailable",
                "session_dispatch",
                false,
                "The native event dispatcher stopped unexpectedly.",
            )
        })
    }

    pub(crate) fn started(&self) -> Result<(), PublicFailure> {
        self.send(EventMessage::Started)
    }

    pub(crate) fn phase(
        &self,
        phase: DhConnectionPhase,
        state: DhSessionState,
    ) -> Result<(), PublicFailure> {
        self.send(EventMessage::Phase { phase, state })
    }

    pub(crate) fn listener_ready(&self, port: u16) -> Result<(), PublicFailure> {
        self.send(EventMessage::ListenerReady(port))
    }

    pub(crate) fn pairing_code(&self, code: String) -> Result<(), PublicFailure> {
        self.send(EventMessage::PairingCode(Zeroizing::new(code)))
    }

    fn pair_record(
        &self,
        kind: DhEventKind,
        request_id: u64,
        peer: PeerRecord,
    ) -> Result<(), PublicFailure> {
        self.send(EventMessage::PairRecord {
            kind,
            request_id,
            peer,
        })
    }

    pub(crate) fn authenticated(&self) -> Result<(), PublicFailure> {
        self.send(EventMessage::Authenticated)
    }

    pub(crate) fn rsd_ready(&self, snapshot: RsdSnapshot) -> Result<(), PublicFailure> {
        self.send(EventMessage::RsdReady(snapshot))
    }

    pub(crate) fn screenshot(
        &self,
        bytes: Vec<u8>,
        dimensions: PngDimensions,
    ) -> Result<(), PublicFailure> {
        self.send(EventMessage::Screenshot { bytes, dimensions })
    }

    pub(crate) fn input_ready(&self) -> Result<(), PublicFailure> {
        self.send(EventMessage::InputReady)
    }

    pub(crate) fn display_geometry(
        &self,
        geometry: DhDisplayGeometry,
    ) -> Result<(), PublicFailure> {
        self.send(EventMessage::DisplayGeometry(geometry))
    }

    fn terminal(&self, terminal: u8, event: EventMessage) {
        let Ok(_ordering) = self.ordering.lock() else {
            return;
        };
        if self
            .terminal
            .compare_exchange(TERMINAL_NONE, terminal, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            let _ = self.sender.send(event);
        }
    }

    fn complete(&self) {
        self.terminal(TERMINAL_COMPLETED, EventMessage::Completed);
    }

    fn fail(&self, failure: PublicFailure) {
        let wire = FailureWire {
            code: failure.code,
            stage: failure.stage,
            retryable: failure.retryable,
            message: failure.message,
        };
        let payload = serde_json::to_vec(&wire).unwrap_or_else(|_| {
            br#"{"code":"error_serialization","stage":"session_dispatch","retryable":false,"message":"Unable to serialize the native failure."}"#.to_vec()
        });
        self.terminal(TERMINAL_FAILED, EventMessage::Failed(payload));
    }

    fn cancel(&self) {
        self.terminal(TERMINAL_CANCELLED, EventMessage::Cancelled);
    }

    fn drain(&self) -> Result<(), PublicFailure> {
        let (sender, receiver) = sync_channel(1);
        self.sender
            .send(EventMessage::Barrier(sender))
            .map_err(|_| {
                PublicFailure::new(
                    "event_dispatch_unavailable",
                    "session_dispatch",
                    false,
                    "The native event dispatcher stopped before cancellation drained.",
                )
            })?;
        receiver.recv().map_err(|_| {
            PublicFailure::new(
                "event_dispatch_unavailable",
                "session_dispatch",
                false,
                "The native event dispatcher stopped before cancellation drained.",
            )
        })
    }
}

/// Synchronous, protocol-worker-owned media callback plane.
///
/// No Rust queue sits between UDP receive and this callback. A slow callback
/// therefore applies bounded backpressure to the sole media producer without
/// delaying the independent lossless control-event dispatcher.
#[derive(Clone)]
pub(crate) struct MediaEmitter {
    callback: DhMediaEventCallback,
    callback_context: usize,
    enabled: Arc<AtomicBool>,
    gate: Arc<StdMutex<()>>,
    generation: DhGeneration,
    sequence: Arc<AtomicU64>,
}

impl MediaEmitter {
    fn new(
        generation: DhGeneration,
        callback: DhMediaEventCallback,
        callback_context: *mut c_void,
    ) -> Self {
        Self {
            callback,
            callback_context: callback_context as usize,
            enabled: Arc::new(AtomicBool::new(true)),
            gate: Arc::new(StdMutex::new(())),
            generation,
            sequence: Arc::new(AtomicU64::new(0)),
        }
    }

    #[cfg(test)]
    /// Creates a synchronous media emitter for direct protocol tests.
    pub(crate) fn test_fixture(
        generation: DhGeneration,
        callback: DhMediaEventCallback,
        callback_context: *mut c_void,
    ) -> Self {
        Self::new(generation, callback, callback_context)
    }

    fn emit(&self, event: MediaEventMessage) -> Result<(), PublicFailure> {
        let callback = self.callback.ok_or_else(|| {
            PublicFailure::new(
                "media_callback_unavailable",
                "media_dispatch",
                false,
                "A control stream requires a synchronous media callback.",
            )
        })?;
        let _gate = self.gate.lock().map_err(|_| {
            PublicFailure::new(
                "media_callback_unavailable",
                "media_dispatch",
                false,
                "The synchronous media callback gate failed.",
            )
        })?;
        if !self.enabled.load(Ordering::Acquire) {
            return Ok(());
        }
        let previous = self.sequence.fetch_add(1, Ordering::AcqRel);
        let sequence = previous.checked_add(1).ok_or_else(|| {
            PublicFailure::new(
                "media_sequence_exhausted",
                "media_dispatch",
                false,
                "The synchronous media callback sequence was exhausted.",
            )
        })?;
        invoke_media_callback(
            &event,
            self.generation,
            sequence,
            callback,
            self.callback_context,
        );
        Ok(())
    }

    #[cfg_attr(
        not(test),
        expect(
            dead_code,
            reason = "ABI v3 retains the retired raw-datagram media callback"
        )
    )]
    pub(crate) fn video_datagram(
        &self,
        bytes: Vec<u8>,
        source_port: u16,
    ) -> Result<(), PublicFailure> {
        self.emit(MediaEventMessage::Datagram { bytes, source_port })
    }

    pub(crate) fn video_configuration(
        &self,
        configuration: HevcParameterSets,
        orientation: DhOrientation,
    ) -> Result<(), PublicFailure> {
        self.emit(MediaEventMessage::Configuration {
            configuration,
            orientation,
        })
    }

    pub(crate) fn video_access_unit(
        &self,
        access_unit: HevcAccessUnit,
        geometry: DhDisplayGeometry,
    ) -> Result<(), PublicFailure> {
        self.emit(MediaEventMessage::AccessUnit {
            access_unit,
            geometry,
        })
    }

    pub(crate) fn video_discontinuity(
        &self,
        discontinuity: DhVideoDiscontinuity,
    ) -> Result<(), PublicFailure> {
        self.emit(MediaEventMessage::Discontinuity(discontinuity))
    }

    fn disable(&self) {
        self.enabled.store(false, Ordering::Release);
        if !INSIDE_MEDIA_CALLBACK.with(Cell::get) {
            drop(self.gate.lock());
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct PersistenceAck {
    request_id: u64,
    outcome: DhPersistenceOutcome,
}

/// Async bridge that blocks protocol progress until Swift acknowledges a
/// durable pair-record transition.
#[derive(Clone)]
pub(crate) struct PersistenceGate {
    acknowledgements: Arc<AsyncMutex<mpsc::Receiver<PersistenceAck>>>,
    emitter: EventEmitter,
    next_request_id: Arc<AtomicU64>,
    pending_request_id: Arc<AtomicU64>,
}

impl PersistenceGate {
    fn allocate_request_id(&self) -> u64 {
        loop {
            let current = self.next_request_id.load(Ordering::Relaxed);
            let request_id = if current == 0 || current == ACK_RESERVED {
                1
            } else {
                current
            };
            let next = if request_id == ACK_RESERVED - 1 {
                1
            } else {
                request_id + 1
            };
            if self
                .next_request_id
                .compare_exchange_weak(current, next, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
            {
                return request_id;
            }
        }
    }

    pub(crate) async fn persist(
        &self,
        kind: DhEventKind,
        peer: PeerRecord,
    ) -> Result<(), IdeviceError> {
        let request_id = self.allocate_request_id();
        if self
            .pending_request_id
            .compare_exchange(0, request_id, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(RemotePairingError::PairRecordPersistenceFailed.into());
        }
        if self.emitter.pair_record(kind, request_id, peer).is_err() {
            self.pending_request_id.store(0, Ordering::Release);
            return Err(RemotePairingError::PairRecordPersistenceFailed.into());
        }

        let acknowledgement = self.acknowledgements.lock().await.recv().await;
        self.pending_request_id.store(0, Ordering::Release);
        match acknowledgement {
            Some(PersistenceAck {
                request_id: received,
                outcome: DhPersistenceOutcome::Succeeded,
            }) if received == request_id => Ok(()),
            _ => Err(RemotePairingError::PairRecordPersistenceFailed.into()),
        }
    }
}

enum StartCommand {
    Start,
    Shutdown,
}

/// Thread-owning implementation behind the opaque [`crate::abi::DhSession`].
pub(crate) struct Session {
    acknowledgements: mpsc::Sender<PersistenceAck>,
    callbacks_enabled: Arc<AtomicBool>,
    cancel: watch::Sender<bool>,
    controls: mpsc::Sender<ControlCommand>,
    dispatcher: Option<JoinHandle<()>>,
    emitter: EventEmitter,
    generation: DhGeneration,
    input_ready: Arc<AtomicBool>,
    lifecycle: Arc<AtomicU8>,
    media: MediaEmitter,
    pending_request_id: Arc<AtomicU64>,
    start: SyncSender<StartCommand>,
    video_control_ready: Arc<AtomicBool>,
    video_negotiation_pending: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Session {
    pub(crate) fn new(
        generation: DhGeneration,
        callback: DhEventCallback,
        callback_context: *mut c_void,
        media_callback: DhMediaEventCallback,
        media_callback_context: *mut c_void,
        operation: Operation,
    ) -> Result<Self, PublicFailure> {
        let callback = callback.ok_or_else(|| {
            PublicFailure::new(
                "invalid_argument",
                "ffi_boundary",
                false,
                "Session configuration requires an event callback.",
            )
        })?;
        let (event_sender, event_receiver) = sync_channel(EVENT_QUEUE_CAPACITY);
        let terminal = Arc::new(AtomicU8::new(TERMINAL_NONE));
        let emitter = EventEmitter {
            sender: event_sender,
            terminal,
            ordering: Arc::new(StdMutex::new(())),
        };
        let media = MediaEmitter::new(generation, media_callback, media_callback_context);
        let worker_media = media.clone();
        let callbacks_enabled = Arc::new(AtomicBool::new(true));
        let dispatcher_enabled = Arc::clone(&callbacks_enabled);
        let callback_context = callback_context as usize;
        let dispatcher = thread::Builder::new()
            .name(format!("device-hub-events-{:016x}", generation.low))
            .spawn(move || {
                dispatch_events(
                    event_receiver,
                    dispatcher_enabled,
                    generation,
                    callback,
                    callback_context,
                );
            })
            .map_err(|_| {
                PublicFailure::new(
                    "dispatcher_start_failed",
                    "session_dispatch",
                    true,
                    "Unable to start the native event dispatcher.",
                )
            })?;

        let (start, start_receiver) = sync_channel(1);
        let (cancel, cancel_receiver) = watch::channel(false);
        let (acknowledgements, acknowledgement_receiver) = mpsc::channel(ACK_QUEUE_CAPACITY);
        let (controls, control_receiver) = mpsc::channel(CONTROL_QUEUE_CAPACITY);
        let input_ready = Arc::new(AtomicBool::new(false));
        let video_control_ready = Arc::new(AtomicBool::new(false));
        let video_negotiation_pending = Arc::new(AtomicBool::new(false));
        let control_gate = ControlGate {
            receiver: control_receiver,
            input_ready: Arc::clone(&input_ready),
            video_control_ready: Arc::clone(&video_control_ready),
            video_negotiation_pending: Arc::clone(&video_negotiation_pending),
        };
        let pending_request_id = Arc::new(AtomicU64::new(0));
        let gate = PersistenceGate {
            acknowledgements: Arc::new(AsyncMutex::new(acknowledgement_receiver)),
            emitter: emitter.clone(),
            next_request_id: Arc::new(AtomicU64::new(1)),
            pending_request_id: Arc::clone(&pending_request_id),
        };
        let worker_emitter = emitter.clone();
        let lifecycle = Arc::new(AtomicU8::new(STATE_READY));
        let worker_lifecycle = Arc::clone(&lifecycle);
        let worker = match thread::Builder::new()
            .name(format!("device-hub-protocol-{:016x}", generation.low))
            .spawn(move || {
                let panic_emitter = worker_emitter.clone();
                let panic_lifecycle = Arc::clone(&worker_lifecycle);
                if crate::catch_sanitized_unwind(|| {
                    run_worker(
                        start_receiver,
                        cancel_receiver,
                        WorkerContext {
                            operation,
                            emitter: worker_emitter,
                            media: worker_media,
                            persistence: gate,
                            controls: control_gate,
                            lifecycle: worker_lifecycle,
                        },
                    );
                })
                .is_err()
                {
                    settle_worker(
                        Some(Err(PublicFailure::new(
                            "panic",
                            "session_dispatch",
                            false,
                            "The native protocol worker failed unexpectedly.",
                        ))),
                        &panic_emitter,
                        &panic_lifecycle,
                    );
                }
            }) {
            Ok(worker) => worker,
            Err(_) => {
                let _ = emitter.sender.send(EventMessage::Shutdown);
                let _ = dispatcher.join();
                return Err(PublicFailure::new(
                    "protocol_worker_start_failed",
                    "session_dispatch",
                    true,
                    "Unable to start the native protocol worker.",
                ));
            }
        };

        Ok(Self {
            acknowledgements,
            callbacks_enabled,
            cancel,
            controls,
            dispatcher: Some(dispatcher),
            emitter,
            generation,
            input_ready,
            lifecycle,
            media,
            pending_request_id,
            start,
            video_control_ready,
            video_negotiation_pending,
            worker: Some(worker),
        })
    }

    pub(crate) fn start(&self) -> Result<(), PublicFailure> {
        match self.lifecycle.compare_exchange(
            STATE_READY,
            STATE_RUNNING,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => {
                if self.start.send(StartCommand::Start).is_err() {
                    self.lifecycle.store(STATE_TERMINAL, Ordering::Release);
                    return Err(PublicFailure::new(
                        "protocol_worker_unavailable",
                        "session_lifecycle",
                        true,
                        "The native protocol worker stopped before starting.",
                    ));
                }
                Ok(())
            }
            Err(STATE_RUNNING) => Ok(()),
            Err(_) => Err(PublicFailure::new(
                "invalid_state",
                "session_lifecycle",
                false,
                "A terminal session cannot be started.",
            )),
        }
    }

    pub(crate) fn cancel(&self) -> Result<(), PublicFailure> {
        loop {
            match self.lifecycle.load(Ordering::Acquire) {
                STATE_READY => {
                    if self
                        .lifecycle
                        .compare_exchange(
                            STATE_READY,
                            STATE_CANCELLED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        self.media.disable();
                        let _ = self.start.send(StartCommand::Shutdown);
                        let _ = self.cancel.send(true);
                        self.input_ready.store(false, Ordering::Release);
                        self.video_control_ready.store(false, Ordering::Release);
                        self.video_negotiation_pending
                            .store(false, Ordering::Release);
                        return Ok(());
                    }
                }
                STATE_RUNNING => {
                    if self
                        .lifecycle
                        .compare_exchange(
                            STATE_RUNNING,
                            STATE_CANCELLED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_ok()
                    {
                        self.media.disable();
                        self.pending_request_id.store(0, Ordering::Release);
                        self.input_ready.store(false, Ordering::Release);
                        self.video_control_ready.store(false, Ordering::Release);
                        self.video_negotiation_pending
                            .store(false, Ordering::Release);
                        let _ = self.cancel.send(true);
                        self.emitter.cancel();
                        self.emitter.drain()?;
                        return Ok(());
                    }
                }
                STATE_CANCELLED => return Ok(()),
                _ => {
                    return Err(PublicFailure::new(
                        "invalid_state",
                        "session_lifecycle",
                        false,
                        "A terminal session cannot be cancelled.",
                    ));
                }
            }
        }
    }

    pub(crate) fn complete_persistence(
        &self,
        request_id: u64,
        raw_outcome: u32,
    ) -> Result<(), PublicFailure> {
        if self.lifecycle.load(Ordering::Acquire) != STATE_RUNNING {
            return Err(PublicFailure::new(
                "invalid_state",
                "pair_record_persistence",
                false,
                "Persistence acknowledgement requires a running session.",
            ));
        }
        let outcome = match raw_outcome {
            value if value == DhPersistenceOutcome::Succeeded as u32 => {
                DhPersistenceOutcome::Succeeded
            }
            value if value == DhPersistenceOutcome::Failed as u32 => DhPersistenceOutcome::Failed,
            _ => {
                return Err(PublicFailure::new(
                    "invalid_argument",
                    "pair_record_persistence",
                    false,
                    "Persistence acknowledgement has an invalid outcome.",
                ));
            }
        };
        if request_id == 0
            || self
                .pending_request_id
                .compare_exchange(
                    request_id,
                    ACK_RESERVED,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_err()
        {
            return Err(PublicFailure::new(
                "stale_persistence_request",
                "pair_record_persistence",
                false,
                "Persistence acknowledgement does not match the pending request.",
            ));
        }
        match self.acknowledgements.try_send(PersistenceAck {
            request_id,
            outcome,
        }) {
            Ok(()) => Ok(()),
            Err(_) => {
                let _ = self.pending_request_id.compare_exchange(
                    ACK_RESERVED,
                    request_id,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
                Err(PublicFailure::new(
                    "persistence_dispatch_failed",
                    "pair_record_persistence",
                    true,
                    "Unable to deliver the persistence acknowledgement.",
                ))
            }
        }
    }

    pub(crate) fn complete_video_negotiation(
        &self,
        generation: DhGeneration,
        raw_outcome: u32,
    ) -> Result<(), PublicFailure> {
        self.require_generation(generation, "video_negotiation")?;
        if self.lifecycle.load(Ordering::Acquire) != STATE_RUNNING {
            return Err(invalid_control_state(
                "video_negotiation",
                "Video negotiation acknowledgement requires a running session.",
            ));
        }
        match raw_outcome {
            value if value == DhVideoNegotiationOutcome::Succeeded as u32 => {}
            value if value == DhVideoNegotiationOutcome::Failed as u32 => {}
            _ => {
                return Err(PublicFailure::new(
                    "invalid_argument",
                    "video_negotiation",
                    false,
                    "Video negotiation acknowledgement has an invalid outcome.",
                ));
            }
        };
        if self
            .video_negotiation_pending
            .compare_exchange(true, false, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(PublicFailure::new(
                "stale_video_negotiation",
                "video_negotiation",
                false,
                "No video negotiation acknowledgement is pending.",
            ));
        }
        if let Err(failure) =
            self.enqueue_control(ControlCommand::VideoNegotiation, "video_negotiation")
        {
            self.video_negotiation_pending
                .store(true, Ordering::Release);
            return Err(failure);
        }
        Ok(())
    }

    pub(crate) fn send_video_control_datagram(
        &self,
        generation: DhGeneration,
        datagram: VideoControlDatagram,
    ) -> Result<(), PublicFailure> {
        self.require_generation(generation, "video_control")?;
        self.require_ready_flag(
            &self.video_control_ready,
            "video_control",
            "Video control requires an active negotiated display stream.",
        )?;
        self.enqueue_control(
            ControlCommand::VideoControlDatagram(datagram),
            "video_control",
        )
    }

    pub(crate) fn send_touch(
        &self,
        generation: DhGeneration,
        intent: TouchIntent,
    ) -> Result<(), PublicFailure> {
        self.require_input_ready(generation)?;
        self.enqueue_control(ControlCommand::Touch(intent), "touch_input")
    }

    pub(crate) fn send_keyboard(
        &self,
        generation: DhGeneration,
        intent: KeyboardIntent,
    ) -> Result<(), PublicFailure> {
        self.require_input_ready(generation)?;
        self.enqueue_control(ControlCommand::Keyboard(intent), "keyboard_input")
    }

    pub(crate) fn send_hardware_button(
        &self,
        generation: DhGeneration,
        intent: HardwareButtonIntent,
    ) -> Result<(), PublicFailure> {
        self.require_input_ready(generation)?;
        self.enqueue_control(
            ControlCommand::HardwareButton(intent),
            "hardware_button_input",
        )
    }

    pub(crate) fn rotate(
        &self,
        generation: DhGeneration,
        intent: RotationIntent,
    ) -> Result<(), PublicFailure> {
        self.require_input_ready(generation)?;
        self.enqueue_control(ControlCommand::Rotate(intent), "rotation")
    }

    pub(crate) fn release_all_input(&self, generation: DhGeneration) -> Result<(), PublicFailure> {
        self.require_input_ready(generation)?;
        self.enqueue_control(ControlCommand::ReleaseAllInput, "input_cleanup")
    }

    fn require_input_ready(&self, generation: DhGeneration) -> Result<(), PublicFailure> {
        self.require_generation(generation, "input")?;
        self.require_ready_flag(
            &self.input_ready,
            "input",
            "Input requires authenticated HID services in the active generation.",
        )
    }

    fn require_generation(
        &self,
        generation: DhGeneration,
        stage: &'static str,
    ) -> Result<(), PublicFailure> {
        if generation == self.generation {
            Ok(())
        } else {
            Err(PublicFailure::new(
                "stale_generation",
                stage,
                false,
                "The command generation does not match the active session.",
            ))
        }
    }

    fn require_ready_flag(
        &self,
        flag: &AtomicBool,
        stage: &'static str,
        message: &'static str,
    ) -> Result<(), PublicFailure> {
        if self.lifecycle.load(Ordering::Acquire) != STATE_RUNNING || !flag.load(Ordering::Acquire)
        {
            Err(invalid_control_state(stage, message))
        } else {
            Ok(())
        }
    }

    fn enqueue_control(
        &self,
        command: ControlCommand,
        stage: &'static str,
    ) -> Result<(), PublicFailure> {
        self.controls.try_send(command).map_err(|_| {
            PublicFailure::new(
                "control_queue_unavailable",
                stage,
                true,
                "The bounded native control queue cannot accept this command.",
            )
        })
    }

    pub(crate) fn shutdown(&mut self) -> DhStatus {
        self.callbacks_enabled.store(false, Ordering::Release);
        self.media.disable();
        let previous = self.lifecycle.swap(STATE_STOPPED, Ordering::AcqRel);
        self.pending_request_id.store(0, Ordering::Release);
        self.input_ready.store(false, Ordering::Release);
        self.video_control_ready.store(false, Ordering::Release);
        self.video_negotiation_pending
            .store(false, Ordering::Release);
        let _ = self.cancel.send(true);
        if previous == STATE_READY {
            let _ = self.start.send(StartCommand::Shutdown);
        }

        let worker_ok = self
            .worker
            .take()
            .is_none_or(|worker| worker.join().is_ok());
        let _ = self.emitter.sender.send(EventMessage::Shutdown);
        let dispatcher_ok = self
            .dispatcher
            .take()
            .is_none_or(|dispatcher| dispatcher.join().is_ok());
        if worker_ok && dispatcher_ok {
            DhStatus::Ok
        } else {
            DhStatus::Internal
        }
    }
}

const fn invalid_control_state(stage: &'static str, message: &'static str) -> PublicFailure {
    PublicFailure::new("invalid_state", stage, false, message)
}

struct WorkerContext {
    operation: Operation,
    emitter: EventEmitter,
    media: MediaEmitter,
    persistence: PersistenceGate,
    controls: ControlGate,
    lifecycle: Arc<AtomicU8>,
}

fn run_worker(
    start: Receiver<StartCommand>,
    mut cancellation: watch::Receiver<bool>,
    context: WorkerContext,
) {
    let WorkerContext {
        operation,
        emitter,
        media,
        persistence,
        controls,
        lifecycle,
    } = context;
    if !matches!(start.recv(), Ok(StartCommand::Start)) {
        return;
    }
    if emitter.started().is_err() {
        settle_worker(
            Some(Err(PublicFailure::new(
                "event_dispatch_unavailable",
                "session_dispatch",
                false,
                "The native event dispatcher stopped unexpectedly.",
            ))),
            &emitter,
            &lifecycle,
        );
        return;
    }
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => {
            settle_worker(
                Some(Err(PublicFailure::new(
                    "runtime_start_failed",
                    "session_dispatch",
                    true,
                    "Unable to start the native protocol runtime.",
                ))),
                &emitter,
                &lifecycle,
            );
            return;
        }
    };

    let is_control_stream = matches!(
        &operation,
        Operation::Remote(operation)
            if matches!(&operation.mode, crate::model::RemoteMode::ControlStream)
    );
    let result = if is_control_stream {
        Some(runtime.block_on(crate::protocol::run(
            operation,
            emitter.clone(),
            media.clone(),
            persistence,
            controls,
            Some(cancellation),
        )))
    } else {
        runtime.block_on(async {
            tokio::select! {
                biased;
                changed = cancellation.changed() => {
                    let _ = changed;
                    None
                }
                result = crate::protocol::run(
                    operation,
                    emitter.clone(),
                    media.clone(),
                    persistence,
                    controls,
                    None,
                ) => Some(result),
            }
        })
    };

    settle_worker(result, &emitter, &lifecycle);
}

fn settle_worker(
    result: Option<Result<(), PublicFailure>>,
    emitter: &EventEmitter,
    lifecycle: &AtomicU8,
) {
    let Some(result) = result else {
        return;
    };
    if lifecycle
        .compare_exchange(
            STATE_RUNNING,
            STATE_TERMINAL,
            Ordering::AcqRel,
            Ordering::Acquire,
        )
        .is_err()
    {
        return;
    }
    match result {
        Ok(()) => emitter.complete(),
        Err(failure) => emitter.fail(failure),
    }
}

fn dispatch_events(
    receiver: Receiver<EventMessage>,
    callbacks_enabled: Arc<AtomicBool>,
    generation: DhGeneration,
    callback: unsafe extern "C" fn(*const DhEvent, *mut c_void),
    callback_context: usize,
) {
    let mut sequence = 0_u64;
    while let Ok(message) = receiver.recv() {
        let message = match message {
            EventMessage::Shutdown => return,
            EventMessage::Barrier(sender) => {
                let _ = sender.send(());
                continue;
            }
            message => message,
        };
        if !callbacks_enabled.load(Ordering::Acquire) {
            continue;
        }
        sequence = sequence.saturating_add(1);
        invoke_callback(&message, generation, sequence, callback, callback_context);
    }
}

#[cfg(test)]
#[path = "session/tests.rs"]
mod tests;

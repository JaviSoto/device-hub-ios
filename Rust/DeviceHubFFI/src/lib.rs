//! Device Hub's app-owned iOS 27 protocol boundary.
//!
//! The ABI exposes explicit remote-pairing operations:
//!
//! - a Pairable Host listener whose authenticated M5 record must be durably
//!   acknowledged before Rust sends M6; and
//! - a Pair Verify-only discovery probe that authenticates one Bonjour
//!   candidate against the stored peer identity and completes without opening a
//!   tunnel; and
//! - an authenticated reconnect that performs Pair Verify, builds the
//!   TLS-PSK/CDTunnel userspace stack, performs RSD, and returns one
//!   structurally validated PNG screenshot or a persistent control stream.
//!
//! Discovery and advertisement remain in Swift/Foundation. This crate never
//! performs raw multicast, persists credentials, logs protocol payloads, or
//! silently falls back from authentication into pairing.
//!
//! # Callback and teardown contract
//!
//! Events are serialized on one private dispatcher. Event bytes and nested
//! views are borrowed only until the callback returns, so Swift must copy what
//! it keeps. A callback may acknowledge persistence or video negotiation, but
//! must not cancel/free its session or unwind through C. Free takes a
//! pointer-to-pointer,
//! clears it before teardown, cancels the protocol worker, and joins both
//! private threads before returning. Free must not race another call.

#![deny(unsafe_op_in_unsafe_fn)]
#![warn(missing_docs)]

mod abi;
mod model;
mod png;
mod protocol;
mod session;

use std::{
    cell::Cell,
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    sync::Once,
};

pub use abi::*;
use model::{
    HardwareButtonIntent, KeyboardIntent, Operation, PairingOperation, ReleaseAllInputIntent,
    RemoteOperation, RotationIntent, TouchIntent, ValidationError, VideoControlDatagram,
};
use serde::Serialize;
use session::PublicFailure;

const IDEVICE_REVISION: &[u8] = b"a64b8867815b3da17b5c927531bdba877e8456ef\0";

thread_local! {
    static REDACT_PANIC_DETAILS: Cell<bool> = const { Cell::new(false) };
}

static INSTALL_PANIC_HOOK: Once = Once::new();

struct PanicRedactionScope {
    previous: bool,
}

impl PanicRedactionScope {
    fn enter() -> Self {
        install_sanitizing_panic_hook();
        let previous = REDACT_PANIC_DETAILS.replace(true);
        Self { previous }
    }
}

impl Drop for PanicRedactionScope {
    fn drop(&mut self) {
        REDACT_PANIC_DETAILS.set(self.previous);
    }
}

fn install_sanitizing_panic_hook() {
    INSTALL_PANIC_HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let redact = REDACT_PANIC_DETAILS.with(Cell::get);
            if !redact {
                previous(info);
            }
        }));
    });
}

/// Catches a panic while preventing its payload from reaching the process
/// panic hook. Panics outside Device Hub's owned threads retain the embedder's
/// existing hook behavior.
pub(crate) fn catch_sanitized_unwind<R>(operation: impl FnOnce() -> R) -> std::thread::Result<R> {
    let _scope = PanicRedactionScope::enter();
    catch_unwind(AssertUnwindSafe(operation))
}

#[derive(Serialize)]
struct ErrorWire<'a> {
    code: &'a str,
    stage: &'a str,
    retryable: bool,
    message: &'a str,
}

struct BoundaryError {
    status: DhStatus,
    code: &'static str,
    stage: &'static str,
    retryable: bool,
    message: &'static str,
}

impl BoundaryError {
    const fn invalid_argument(message: &'static str) -> Self {
        Self {
            status: DhStatus::InvalidArgument,
            code: "invalid_argument",
            stage: "ffi_boundary",
            retryable: false,
            message,
        }
    }

    const fn panic() -> Self {
        Self {
            status: DhStatus::Panic,
            code: "panic",
            stage: "ffi_boundary",
            retryable: false,
            message: "The Rust boundary caught an unexpected failure.",
        }
    }

    const fn invalid_state(message: &'static str) -> Self {
        Self {
            status: DhStatus::InvalidState,
            code: "invalid_state",
            stage: "ffi_boundary",
            retryable: false,
            message,
        }
    }

    fn into_owned(self) -> DhError {
        let wire = ErrorWire {
            code: self.code,
            stage: self.stage,
            retryable: self.retryable,
            message: self.message,
        };
        let serialized = serde_json::to_string(&wire).unwrap_or_else(|_| {
            "{\"code\":\"error_serialization\",\"stage\":\"ffi_boundary\",\"retryable\":false,\"message\":\"Unable to serialize the native error.\"}".to_owned()
        });
        let json = CString::new(serialized).unwrap_or_else(|_| {
            CString::new("{\"code\":\"error_serialization\",\"stage\":\"ffi_boundary\",\"retryable\":false,\"message\":\"Unable to serialize the native error.\"}")
                .expect("static fallback contains no NUL")
        });
        DhError { json }
    }
}

impl From<ValidationError> for BoundaryError {
    fn from(error: ValidationError) -> Self {
        Self::invalid_argument(error.message)
    }
}

impl From<PublicFailure> for BoundaryError {
    fn from(error: PublicFailure) -> Self {
        let status = if error.code == "invalid_argument" {
            DhStatus::InvalidArgument
        } else if matches!(
            error.code,
            "invalid_state"
                | "stale_persistence_request"
                | "stale_generation"
                | "stale_video_negotiation"
        ) {
            DhStatus::InvalidState
        } else {
            DhStatus::Internal
        };
        Self {
            status,
            code: error.code,
            stage: error.stage,
            retryable: error.retryable,
            message: error.message,
        }
    }
}

fn clear_error(out_error: *mut *mut DhError) {
    if !out_error.is_null() {
        // SAFETY: Public ABI contracts require non-null output pointers to be
        // writable for one pointer value.
        unsafe { out_error.write(ptr::null_mut()) };
    }
}

fn return_error(error: BoundaryError, out_error: *mut *mut DhError) -> DhStatus {
    let status = error.status;
    if !out_error.is_null() {
        // SAFETY: Public ABI contracts require non-null output pointers to be
        // writable for one pointer value.
        unsafe { out_error.write(Box::into_raw(Box::new(error.into_owned()))) };
    }
    status
}

fn run_fallible(
    out_error: *mut *mut DhError,
    operation: impl FnOnce() -> Result<(), BoundaryError>,
) -> DhStatus {
    clear_error(out_error);
    match catch_sanitized_unwind(operation) {
        Ok(Ok(())) => DhStatus::Ok,
        Ok(Err(error)) => return_error(error, out_error),
        Err(_) => return_error(BoundaryError::panic(), out_error),
    }
}

struct SessionCallbacks {
    control: DhEventCallback,
    control_context: *mut std::ffi::c_void,
    media: DhMediaEventCallback,
    media_context: *mut std::ffi::c_void,
}

fn create_session(
    generation: DhGeneration,
    callbacks: SessionCallbacks,
    operation: Operation,
    out_session: *mut *mut DhSession,
    out_error: *mut *mut DhError,
) -> DhStatus {
    if out_session.is_null() {
        return return_error(
            BoundaryError::invalid_argument("Session output pointer must not be null."),
            out_error,
        );
    }
    // SAFETY: The output pointer was validated immediately above.
    unsafe { out_session.write(ptr::null_mut()) };
    match session::Session::new(
        generation,
        callbacks.control,
        callbacks.control_context,
        callbacks.media,
        callbacks.media_context,
        operation,
    ) {
        Ok(inner) => {
            // SAFETY: The validated output receives the sole owning pointer.
            unsafe { out_session.write(Box::into_raw(Box::new(DhSession { inner }))) };
            DhStatus::Ok
        }
        Err(error) => return_error(error.into(), out_error),
    }
}

/// Returns the binary ABI version.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn dh_ffi_abi_version() -> u32 {
    DH_ABI_VERSION
}

/// Returns a bit mask containing only implemented and tested functionality.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn dh_ffi_capabilities() -> u64 {
    IMPLEMENTED_CAPABILITIES
}

/// Returns the wrapper version as a process-lifetime NUL-terminated string.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn dh_ffi_version() -> *const c_char {
    c_string_pointer(concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes())
}

/// Returns the reviewed upstream revision as a process-lifetime string.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn dh_ffi_idevice_revision() -> *const c_char {
    c_string_pointer(IDEVICE_REVISION)
}

/// Creates one explicit Pairable Host session.
///
/// The listener is not bound until [`dh_session_start`]. A successful start
/// emits [`DhEventKind::PairingListenerReady`] with the bound port; only then
/// should Swift publish its Foundation Bonjour advertisement.
///
/// # Safety
///
/// `config` and every nested pointer/span must be initialized, aligned, and
/// readable for this call. Output pointers must be writable and non-aliasing.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_pairing_session_create(
    config: *const DhPairingSessionConfig,
    out_session: *mut *mut DhSession,
    out_error: *mut *mut DhError,
) -> DhStatus {
    clear_error(out_error);
    if out_session.is_null() {
        return return_error(
            BoundaryError::invalid_argument("Session output pointer must not be null."),
            out_error,
        );
    }
    // SAFETY: The output pointer was validated immediately above.
    unsafe { out_session.write(ptr::null_mut()) };
    let result = catch_sanitized_unwind(|| {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let config = unsafe { config.as_ref() }.ok_or_else(|| {
            BoundaryError::invalid_argument("Pairing configuration pointer must not be null.")
        })?;
        // SAFETY: Nested pointer/span validity is part of the same contract and
        // the conversion copies every value before returning.
        let operation = unsafe { PairingOperation::copy_from(config) }?;
        Ok::<_, BoundaryError>((
            config.generation,
            SessionCallbacks {
                control: config.callback,
                control_context: config.callback_context,
                media: None,
                media_context: ptr::null_mut(),
            },
            Operation::Pairing(operation),
        ))
    });
    match result {
        Ok(Ok((generation, callbacks, operation))) => {
            create_session(generation, callbacks, operation, out_session, out_error)
        }
        Ok(Err(error)) => return_error(error, out_error),
        Err(_) => return_error(BoundaryError::panic(), out_error),
    }
}

/// Creates one Pair Verify, screenshot, or live-control session.
///
/// Shape validation occurs synchronously. Pair Verify against the copied
/// target identity provides authoritative endpoint authentication after start;
/// validated TXT auth tags are bounded discovery hints only.
///
/// # Safety
///
/// `config` and every nested pointer/span must be initialized, aligned, and
/// readable for this call. Output pointers must be writable and non-aliasing.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_remote_session_create(
    config: *const DhRemoteSessionConfig,
    out_session: *mut *mut DhSession,
    out_error: *mut *mut DhError,
) -> DhStatus {
    clear_error(out_error);
    if out_session.is_null() {
        return return_error(
            BoundaryError::invalid_argument("Session output pointer must not be null."),
            out_error,
        );
    }
    // SAFETY: The output pointer was validated immediately above.
    unsafe { out_session.write(ptr::null_mut()) };
    let result = catch_sanitized_unwind(|| {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let config = unsafe { config.as_ref() }.ok_or_else(|| {
            BoundaryError::invalid_argument("Remote configuration pointer must not be null.")
        })?;
        // SAFETY: Nested pointer/span validity is part of the same contract and
        // the conversion copies every value before returning.
        let operation = unsafe { RemoteOperation::copy_from(config) }?;
        let is_control_stream = matches!(&operation.mode, model::RemoteMode::ControlStream);
        if is_control_stream != config.media_callback.is_some() {
            return Err(BoundaryError::invalid_argument(
                "Control streams require exactly one media callback; screenshots require none.",
            ));
        }
        Ok::<_, BoundaryError>((
            config.generation,
            SessionCallbacks {
                control: config.callback,
                control_context: config.callback_context,
                media: config.media_callback,
                media_context: config.media_callback_context,
            },
            Operation::Remote(Box::new(operation)),
        ))
    });
    match result {
        Ok(Ok((generation, callbacks, operation))) => {
            create_session(generation, callbacks, operation, out_session, out_error)
        }
        Ok(Err(error)) => return_error(error, out_error),
        Err(_) => return_error(BoundaryError::panic(), out_error),
    }
}

/// Starts a created one-shot session. Repeated starts while running are no-ops.
///
/// # Safety
///
/// `session` must be a live pointer returned by a session constructor, and this
/// call must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_start(
    session: *mut DhSession,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        session.inner.start().map_err(Into::into)
    })
}

/// Acknowledges one pending provisional or committed persistence request.
///
/// Duplicate, stale, zero, or wrong-session request IDs fail without advancing
/// the protocol.
///
/// # Safety
///
/// `session` must be live, and this call must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_complete_persistence(
    session: *mut DhSession,
    request_id: u64,
    outcome: u32,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        session
            .inner
            .complete_persistence(request_id, outcome)
            .map_err(Into::into)
    })
}

/// Acknowledges that the caller-owned video receiver accepted or rejected the
/// generation's negotiator answer.
///
/// # Safety
///
/// `session` must be live, and this call must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_complete_video_negotiation(
    session: *mut DhSession,
    generation: DhGeneration,
    outcome: u32,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        session
            .inner
            .complete_video_negotiation(generation, outcome)
            .map_err(Into::into)
    })
}

/// Queues one generation-tagged normalized touchscreen transition.
///
/// # Safety
///
/// `session` and `input` must be live for this call, which must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_send_touch(
    session: *mut DhSession,
    input: *const DhTouchInput,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let input = unsafe { input.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Touch input must not be null."))?;
        let (generation, intent) = TouchIntent::copy_from(input)?;
        session
            .inner
            .send_touch(generation, intent)
            .map_err(Into::into)
    })
}

/// Queues one generation-tagged virtual keyboard transition.
///
/// # Safety
///
/// `session` and `input` must be live for this call, which must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_send_keyboard(
    session: *mut DhSession,
    input: *const DhKeyboardInput,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let input = unsafe { input.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Keyboard input must not be null."))?;
        let (generation, intent) = KeyboardIntent::copy_from(input)?;
        session
            .inner
            .send_keyboard(generation, intent)
            .map_err(Into::into)
    })
}

/// Queues one generation-tagged confirmed iOS hardware-button transition.
///
/// # Safety
///
/// `session` and `input` must be live for this call, which must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_send_hardware_button(
    session: *mut DhSession,
    input: *const DhHardwareButtonInput,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let input = unsafe { input.as_ref() }.ok_or_else(|| {
            BoundaryError::invalid_argument("Hardware-button input must not be null.")
        })?;
        let (generation, intent) = HardwareButtonIntent::copy_from(input)?;
        session
            .inner
            .send_hardware_button(generation, intent)
            .map_err(Into::into)
    })
}

/// Queues one generation-tagged verified relative 90-degree rotation.
///
/// # Safety
///
/// `session` and `input` must be live for this call, which must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_rotate(
    session: *mut DhSession,
    input: *const DhRotationInput,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let input = unsafe { input.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Rotation input must not be null."))?;
        let (generation, intent) = RotationIntent::copy_from(input)?;
        session.inner.rotate(generation, intent).map_err(Into::into)
    })
}

/// Queues one idempotent release of every native held input.
///
/// Unlike ordinary input commands, this remains the correct transition after
/// UI freshness authorization is revoked, while the authenticated native input
/// services for this generation are still open.
///
/// # Safety
///
/// `session` and `input` must be live for this call, which must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_release_all_input(
    session: *mut DhSession,
    input: *const DhReleaseAllInput,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let input = unsafe { input.as_ref() }.ok_or_else(|| {
            BoundaryError::invalid_argument("Release-all-input request must not be null.")
        })?;
        let (generation, _) = ReleaseAllInputIntent::copy_from(input)?;
        session
            .inner
            .release_all_input(generation)
            .map_err(Into::into)
    })
}

/// Queues one complete outbound AVConference video control datagram.
///
/// # Safety
///
/// `session`, `datagram`, and its byte span must be live for this call, which
/// must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_send_video_control_datagram(
    session: *mut DhSession,
    datagram: *const DhVideoControlDatagram,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let datagram = unsafe { datagram.as_ref() }.ok_or_else(|| {
            BoundaryError::invalid_argument("Video control datagram must not be null.")
        })?;
        let (generation, datagram) = VideoControlDatagram::copy_from(datagram)?;
        session
            .inner
            .send_video_control_datagram(generation, datagram)
            .map_err(Into::into)
    })
}

/// Requests cancellation. Repeated cancellation requests are no-ops.
///
/// # Safety
///
/// `session` must be live, and this call must not race free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_cancel(
    session: *mut DhSession,
    out_error: *mut *mut DhError,
) -> DhStatus {
    run_fallible(out_error, || {
        if session::inside_callback() {
            return Err(BoundaryError::invalid_state(
                "Session cancellation must not run from either callback.",
            ));
        }
        // SAFETY: Pointer validity is part of this function's ABI contract.
        let session = unsafe { session.as_ref() }
            .ok_or_else(|| BoundaryError::invalid_argument("Session pointer must not be null."))?;
        session.inner.cancel().map_err(Into::into)
    })
}

/// Cancels, joins, releases, and nulls an owned session.
///
/// Repeating the call with the now-null storage is safe. Calling this function
/// from the session's own callback returns [`DhStatus::InvalidState`] without
/// consuming the pointer.
///
/// # Safety
///
/// `inout_session` must be null or writable for one session pointer. Its
/// non-null pointee must be the sole live owner returned by this ABI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_session_free(inout_session: *mut *mut DhSession) -> DhStatus {
    if inout_session.is_null() {
        return DhStatus::InvalidArgument;
    }
    if session::inside_callback() {
        return DhStatus::InvalidState;
    }
    // SAFETY: Writable pointer validity is part of this function's contract.
    let session = unsafe { inout_session.read() };
    if session.is_null() {
        return DhStatus::Ok;
    }
    // Clear caller storage before any operation that could fail.
    // SAFETY: Writable pointer validity is part of this function's contract.
    unsafe { inout_session.write(ptr::null_mut()) };
    // SAFETY: The pointer is the sole owning allocation from this ABI and was
    // removed from caller storage immediately above.
    let mut session = unsafe { Box::from_raw(session) };
    session.inner.shutdown()
}

/// Returns borrowed UTF-8 JSON for an owned error.
///
/// The pointer remains valid until [`dh_error_free`] releases the error.
///
/// # Safety
///
/// `error` must be null or a live pointer returned through this ABI.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_error_json(error: *const DhError) -> *const c_char {
    // SAFETY: Pointer validity is part of this function's ABI contract.
    unsafe { error.as_ref() }.map_or(ptr::null(), |error| error.json.as_ptr())
}

/// Releases and nulls an owned error. A null value is a no-op.
///
/// # Safety
///
/// `inout_error` must be null or writable for one error pointer. A non-null
/// pointee must be the sole owner returned by this ABI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dh_error_free(inout_error: *mut *mut DhError) {
    if inout_error.is_null() {
        return;
    }
    // SAFETY: Writable pointer validity is part of this function's contract.
    let error = unsafe { inout_error.read() };
    if error.is_null() {
        return;
    }
    // SAFETY: Writable pointer validity is part of this function's contract.
    unsafe { inout_error.write(ptr::null_mut()) };
    // SAFETY: This is the sole owning pointer and has been removed from caller
    // storage, so dropping exactly once is correct.
    drop(unsafe { Box::from_raw(error) });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panic_is_converted_to_an_owned_sanitized_error() {
        let mut error = ptr::null_mut();

        let status = run_fallible(&mut error, || -> Result<(), BoundaryError> {
            panic!("PIN=123456 pair_record=private-key-material")
        });

        assert_eq!(status, DhStatus::Panic);
        assert!(!error.is_null());
        // SAFETY: `error` was returned by this module and remains live.
        let json = unsafe { std::ffi::CStr::from_ptr(dh_error_json(error)) }
            .to_str()
            .unwrap();
        assert!(!json.contains("123456"));
        assert!(!json.contains("private-key-material"));
        // SAFETY: `error` is the sole owned pointer.
        unsafe { dh_error_free(&mut error) };
        assert!(error.is_null());
    }
}

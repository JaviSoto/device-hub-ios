//! Owned, validated protocol inputs copied from the C ABI.

use std::{
    mem::size_of,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV6},
    slice,
};

use ed25519_dalek::{SigningKey, VerifyingKey};
use idevice::remote_pairing::{PeerDevice, RpPairingFile, VerifiedPeerIdentity, compute_auth_tag};
use zeroize::Zeroizing;

use crate::abi::{
    DH_ABI_VERSION, DhButtonPhase, DhBytes, DhControllerIdentity, DhGeneration, DhHardwareButton,
    DhHardwareButtonInput, DhIpFamily, DhKeyboardInput, DhKeyboardPhase, DhPairingCompletion,
    DhPairingSessionConfig, DhReleaseAllInput, DhRemoteSessionConfig, DhResolvedEndpoint,
    DhRotationDirection, DhRotationInput, DhTargetPairingRecord, DhTouchInput, DhTouchPhase,
    DhValidatedRemoteService, DhVideoControlDatagram,
};

const MAX_IDENTIFIER_BYTES: usize = 256;
const MAX_DEVICE_ID_BYTES: usize = 256;
const MAX_DISPLAY_NAME_BYTES: usize = 256;
const MAX_MODEL_BYTES: usize = 128;
const MAX_AUTH_TAGS: usize = 32;
const MAX_NEGOTIATOR_OFFER_BYTES: usize = 1024 * 1024;
const MAX_VIDEO_CONTROL_DATAGRAM_BYTES: usize = u16::MAX as usize;

/// Sanitized failure raised while copying untrusted ABI input.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ValidationError {
    pub(crate) message: &'static str,
}

impl ValidationError {
    const fn new(message: &'static str) -> Self {
        Self { message }
    }
}

/// Stable controller credentials retained only by the protocol worker.
#[derive(Clone)]
pub(crate) struct ControllerIdentity {
    pub(crate) identifier: String,
    pub(crate) udid: String,
    secret_key: Zeroizing<[u8; 32]>,
    pub(crate) alternate_irk: Zeroizing<[u8; 16]>,
}

impl std::fmt::Debug for ControllerIdentity {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ControllerIdentity")
            .field("credentials", &"<redacted>")
            .finish()
    }
}

impl ControllerIdentity {
    fn copy_from(raw: &DhControllerIdentity) -> Result<Self, ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhControllerIdentity>(),
            raw.abi_version,
            "Controller identity uses an unsupported ABI contract.",
        )?;
        let identifier = copy_uuid(raw.identifier, "Controller identifier is invalid.")?;
        let udid = copy_text(raw.udid, MAX_DEVICE_ID_BYTES, "Controller UDID is invalid.")?;
        let secret_key = copy_exact_array::<32>(
            raw.long_term_secret_key,
            "Controller secret key must contain exactly 32 nonzero bytes.",
            true,
        )?;
        let alternate_irk = copy_exact_array::<16>(
            raw.alternate_irk,
            "Controller alternate IRK must contain exactly 16 nonzero bytes.",
            true,
        )?;
        Ok(Self {
            identifier,
            udid,
            secret_key: Zeroizing::new(secret_key),
            alternate_irk: Zeroizing::new(alternate_irk),
        })
    }

    pub(crate) fn pairing_file(&self, peer_alt_irk: Option<&[u8]>) -> RpPairingFile {
        let private = SigningKey::from_bytes(&self.secret_key);
        let public = VerifyingKey::from(&private);
        RpPairingFile {
            e_private_key: private,
            e_public_key: public,
            identifier: self.identifier.clone(),
            alt_irk: peer_alt_irk.map(ToOwned::to_owned),
        }
    }
}

/// Authenticated durable target state copied from Swift.
#[derive(Clone, Debug)]
pub(crate) struct PeerRecord {
    pub(crate) device_id: String,
    pub(crate) account_identifier: String,
    pub(crate) peer_identifier: String,
    pub(crate) peer_public_key: [u8; 32],
    pub(crate) peer_alternate_irk: [u8; 16],
    pub(crate) display_name: String,
    pub(crate) product_type: String,
    pub(crate) completion: DhPairingCompletion,
}

impl PeerRecord {
    fn copy_from(raw: &DhTargetPairingRecord) -> Result<Self, ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhTargetPairingRecord>(),
            raw.abi_version,
            "Target pairing record uses an unsupported ABI contract.",
        )?;
        if raw.reserved != 0 {
            return Err(ValidationError::new(
                "Target pairing record has nonzero reserved fields.",
            ));
        }
        let completion = match raw.completion {
            value if value == DhPairingCompletion::Provisional as u32 => {
                DhPairingCompletion::Provisional
            }
            value if value == DhPairingCompletion::Committed as u32 => {
                DhPairingCompletion::Committed
            }
            _ => {
                return Err(ValidationError::new(
                    "Target pairing record has an invalid completion state.",
                ));
            }
        };
        let peer_public_key = copy_exact_array::<32>(
            raw.peer_public_key,
            "Target public key must contain exactly 32 valid bytes.",
            false,
        )?;
        let verifying_key = VerifyingKey::from_bytes(&peer_public_key)
            .map_err(|_| ValidationError::new("Target public key is invalid."))?;
        if verifying_key.is_weak() {
            return Err(ValidationError::new("Target public key is invalid."));
        }
        Ok(Self {
            device_id: copy_text(
                raw.device_id,
                MAX_DEVICE_ID_BYTES,
                "Target device identifier is invalid.",
            )?,
            account_identifier: copy_text(
                raw.account_identifier,
                MAX_IDENTIFIER_BYTES,
                "Target account identifier is invalid.",
            )?,
            peer_identifier: copy_text(
                raw.peer_identifier,
                MAX_IDENTIFIER_BYTES,
                "Target pairing identifier is invalid.",
            )?,
            peer_public_key,
            peer_alternate_irk: copy_exact_array::<16>(
                raw.peer_alternate_irk,
                "Target alternate IRK must contain exactly 16 nonzero bytes.",
                true,
            )?,
            display_name: copy_text(
                raw.display_name,
                MAX_DISPLAY_NAME_BYTES,
                "Target display name is invalid.",
            )?,
            product_type: copy_text(
                raw.product_type,
                MAX_MODEL_BYTES,
                "Target product type is invalid.",
            )?,
            completion,
        })
    }

    pub(crate) fn from_verified(peer: &VerifiedPeerIdentity) -> Result<Self, ValidationError> {
        if peer.peer.alt_irk.len() != 16 {
            return Err(ValidationError::new(
                "Authenticated peer supplied an invalid alternate IRK.",
            ));
        }
        let peer_alternate_irk: [u8; 16] = peer
            .peer
            .alt_irk
            .as_slice()
            .try_into()
            .map_err(|_| ValidationError::new("Authenticated peer record is malformed."))?;
        let record = Self {
            device_id: peer.peer.remotepairing_udid.clone(),
            account_identifier: peer.peer.account_id.clone(),
            peer_identifier: peer.pairing_identifier.clone(),
            peer_public_key: peer.long_term_public_key,
            peer_alternate_irk,
            display_name: peer.peer.name.clone(),
            product_type: peer.peer.model.clone(),
            completion: DhPairingCompletion::Provisional,
        };
        record.validate_authenticated_text()?;
        Ok(record)
    }

    fn validate_authenticated_text(&self) -> Result<(), ValidationError> {
        require_owned_text(
            &self.device_id,
            MAX_DEVICE_ID_BYTES,
            "Authenticated target device identifier is invalid.",
        )?;
        require_owned_text(
            &self.account_identifier,
            MAX_IDENTIFIER_BYTES,
            "Authenticated target account identifier is invalid.",
        )?;
        require_owned_text(
            &self.peer_identifier,
            MAX_IDENTIFIER_BYTES,
            "Authenticated target pairing identifier is invalid.",
        )?;
        require_owned_text(
            &self.display_name,
            MAX_DISPLAY_NAME_BYTES,
            "Authenticated target display name is invalid.",
        )?;
        require_owned_text(
            &self.product_type,
            MAX_MODEL_BYTES,
            "Authenticated target product type is invalid.",
        )
    }

    pub(crate) fn verified_identity(&self) -> VerifiedPeerIdentity {
        VerifiedPeerIdentity {
            peer: PeerDevice {
                account_id: self.account_identifier.clone(),
                alt_irk: self.peer_alternate_irk.to_vec(),
                model: self.product_type.clone(),
                name: self.display_name.clone(),
                remotepairing_udid: self.device_id.clone(),
            },
            pairing_identifier: self.peer_identifier.clone(),
            long_term_public_key: self.peer_public_key,
        }
    }
}

/// Swift-validated discovery values retained until Pair Verify authenticates the endpoint.
#[derive(Clone, Debug)]
pub(crate) struct RemoteService {
    pub(crate) endpoint: SocketAddr,
    pub(crate) identifier: String,
    auth_tags: Vec<[u8; 6]>,
}

impl RemoteService {
    fn copy_from(raw: &DhValidatedRemoteService) -> Result<Self, ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhValidatedRemoteService>(),
            raw.abi_version,
            "Remote service uses an unsupported ABI contract.",
        )?;
        if raw.wire_protocol_version != 26
            || raw.minimum_wire_protocol_version != 8
            || raw.flags != 0
            || raw.reserved != 0
        {
            return Err(ValidationError::new(
                "Remote service protocol fields are unsupported.",
            ));
        }
        let endpoint = copy_endpoint(&raw.endpoint)?;
        let identifier = copy_uuid(raw.identifier, "Remote service identifier is invalid.")?;
        let auth_tag_bytes = copy_bytes(
            raw.auth_tags,
            false,
            MAX_AUTH_TAGS * 6,
            "Remote service authentication tags are invalid.",
        )?;
        if auth_tag_bytes.len() % 6 != 0 {
            return Err(ValidationError::new(
                "Remote service authentication tags are invalid.",
            ));
        }
        let auth_tags = auth_tag_bytes
            .chunks_exact(6)
            .map(|chunk| {
                chunk
                    .try_into()
                    .expect("chunks_exact always returns six-byte chunks")
            })
            .collect();
        Ok(Self {
            endpoint,
            identifier,
            auth_tags,
        })
    }

    /// Returns whether the secret-derived discovery tag selects this record.
    ///
    /// Pair Verify remains the cryptographic authentication boundary; this
    /// bounded tag check prevents network I/O to unrelated Bonjour peers.
    pub(crate) fn authenticates(&self, target: &PeerRecord) -> bool {
        let expected = compute_auth_tag(&target.peer_alternate_irk, &self.identifier);
        self.auth_tags
            .iter()
            .any(|candidate| candidate == &expected)
    }

    pub(crate) fn endpoint_with_port(&self, port: u16) -> SocketAddr {
        match self.endpoint {
            SocketAddr::V4(address) => SocketAddr::new(IpAddr::V4(*address.ip()), port),
            SocketAddr::V6(address) => SocketAddr::V6(SocketAddrV6::new(
                *address.ip(),
                port,
                address.flowinfo(),
                address.scope_id(),
            )),
        }
    }
}

/// One Pairable Host operation.
#[derive(Clone, Debug)]
pub(crate) struct PairingOperation {
    pub(crate) controller: ControllerIdentity,
    pub(crate) display_name: String,
    pub(crate) model: String,
    pub(crate) requested_port: u16,
}

/// One stored-peer authentication or authenticated reconnect operation.
#[derive(Clone, Debug)]
pub(crate) struct RemoteOperation {
    pub(crate) controller: ControllerIdentity,
    pub(crate) target: PeerRecord,
    pub(crate) service: RemoteService,
    pub(crate) mode: RemoteMode,
}

/// Copied operation-specific state for an authenticated remote session.
#[derive(Clone, Debug)]
pub(crate) enum RemoteMode {
    Screenshot,
    ControlStream,
    PairVerify,
}

/// Owned, validated single-contact touchscreen intent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TouchIntent {
    Down { x: u16, y: u16 },
    Move { x: u16, y: u16 },
    Up { x: u16, y: u16 },
    Cancel,
    Tap { x: u16, y: u16 },
}

/// Owned, validated virtual-keyboard intent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum KeyboardIntent {
    Down { usage: u16, modifiers: u8 },
    Up { usage: u16, modifiers: u8 },
    CancelAll,
    Tap { usage: u16, modifiers: u8 },
}

/// Owned, validated hardware-button intent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct HardwareButtonIntent {
    pub(crate) button: DhHardwareButton,
    pub(crate) phase: DhButtonPhase,
}

/// Owned, validated relative rotation intent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RotationIntent {
    Left,
    Right,
}

/// Owned, validated outbound video control datagram.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct VideoControlDatagram {
    pub(crate) bytes: Vec<u8>,
}

/// Validated request to release every successfully delivered held input.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct ReleaseAllInputIntent;

/// Fully copied operation selected by one session constructor.
#[derive(Clone, Debug)]
pub(crate) enum Operation {
    Pairing(PairingOperation),
    Remote(Box<RemoteOperation>),
}

impl PairingOperation {
    /// Copies a pairing configuration. Pointer validity is guaranteed by the
    /// calling ABI before this function is entered.
    pub(crate) unsafe fn copy_from(raw: &DhPairingSessionConfig) -> Result<Self, ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhPairingSessionConfig>(),
            raw.abi_version,
            "Pairing session uses an unsupported ABI contract.",
        )?;
        if raw.reserved != [0; 6] {
            return Err(ValidationError::new(
                "Pairing session has nonzero reserved fields.",
            ));
        }
        // SAFETY: The caller guarantees pointer validity for this call.
        let controller = unsafe { raw.controller_identity.as_ref() }.ok_or_else(|| {
            ValidationError::new("Pairing session requires a controller identity.")
        })?;
        Ok(Self {
            controller: ControllerIdentity::copy_from(controller)?,
            display_name: copy_text(
                raw.display_name,
                MAX_DISPLAY_NAME_BYTES,
                "Pairable Host display name is invalid.",
            )?,
            model: copy_text(
                raw.model,
                MAX_MODEL_BYTES,
                "Pairable Host model is invalid.",
            )?,
            requested_port: raw.requested_port,
        })
    }
}

impl RemoteOperation {
    /// Copies a reconnect configuration. Pointer validity is guaranteed by the
    /// calling ABI before this function is entered.
    pub(crate) unsafe fn copy_from(raw: &DhRemoteSessionConfig) -> Result<Self, ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhRemoteSessionConfig>(),
            raw.abi_version,
            "Remote session uses an unsupported ABI contract.",
        )?;
        // SAFETY: The caller guarantees pointer validity for this call.
        let controller = unsafe { raw.controller_identity.as_ref() }.ok_or_else(|| {
            ValidationError::new("Remote session requires a controller identity.")
        })?;
        // SAFETY: The caller guarantees pointer validity for this call.
        let target = unsafe { raw.target.as_ref() }
            .ok_or_else(|| ValidationError::new("Remote session requires a target record."))?;
        // SAFETY: The caller guarantees pointer validity for this call.
        let service = unsafe { raw.service.as_ref() }
            .ok_or_else(|| ValidationError::new("Remote session requires a validated service."))?;
        let controller = ControllerIdentity::copy_from(controller)?;
        let target = PeerRecord::copy_from(target)?;
        let service = RemoteService::copy_from(service)?;
        if !service.authenticates(&target) {
            return Err(ValidationError::new(
                "Remote service does not select the target pairing record.",
            ));
        }
        if raw.reserved != 0 {
            return Err(ValidationError::new(
                "Remote session has nonzero reserved fields.",
            ));
        }
        let offer = copy_bytes(
            raw.video_negotiator_offer,
            true,
            MAX_NEGOTIATOR_OFFER_BYTES,
            "Video negotiator offer is invalid.",
        )?;
        let mode = match raw.operation {
            value if value == crate::abi::DhRemoteOperation::Screenshot as u32 => {
                if !offer.is_empty() {
                    return Err(ValidationError::new(
                        "Screenshot sessions must not include a video negotiator offer.",
                    ));
                }
                RemoteMode::Screenshot
            }
            value if value == crate::abi::DhRemoteOperation::ControlStream as u32 => {
                if !offer.is_empty() {
                    return Err(ValidationError::new(
                        "Control streams construct video negotiation inside the native protocol.",
                    ));
                }
                RemoteMode::ControlStream
            }
            value if value == crate::abi::DhRemoteOperation::PairVerify as u32 => {
                if !offer.is_empty() {
                    return Err(ValidationError::new(
                        "Pair Verify sessions must not include a video negotiator offer.",
                    ));
                }
                RemoteMode::PairVerify
            }
            _ => {
                return Err(ValidationError::new(
                    "Remote session operation is unsupported.",
                ));
            }
        };
        Ok(Self {
            controller,
            target,
            service,
            mode,
        })
    }
}

impl TouchIntent {
    /// Copies and validates one generation-tagged touchscreen input.
    pub(crate) fn copy_from(raw: &DhTouchInput) -> Result<(DhGeneration, Self), ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhTouchInput>(),
            raw.abi_version,
            "Touch input uses an unsupported ABI contract.",
        )?;
        if raw.reserved != 0 {
            return Err(ValidationError::new(
                "Touch input has nonzero reserved fields.",
            ));
        }
        let intent = match raw.phase {
            value if value == DhTouchPhase::Down as u32 => Self::Down { x: raw.x, y: raw.y },
            value if value == DhTouchPhase::Move as u32 => Self::Move { x: raw.x, y: raw.y },
            value if value == DhTouchPhase::Up as u32 => Self::Up { x: raw.x, y: raw.y },
            value if value == DhTouchPhase::Cancel as u32 => {
                if raw.x != 0 || raw.y != 0 {
                    return Err(ValidationError::new(
                        "Cancelled touch input must use zero coordinates.",
                    ));
                }
                Self::Cancel
            }
            value if value == DhTouchPhase::Tap as u32 => Self::Tap { x: raw.x, y: raw.y },
            _ => return Err(ValidationError::new("Touch input phase is invalid.")),
        };
        Ok((raw.generation, intent))
    }
}

impl KeyboardIntent {
    /// Copies and validates one generation-tagged keyboard input.
    pub(crate) fn copy_from(
        raw: &DhKeyboardInput,
    ) -> Result<(DhGeneration, Self), ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhKeyboardInput>(),
            raw.abi_version,
            "Keyboard input uses an unsupported ABI contract.",
        )?;
        if raw.reserved != 0 {
            return Err(ValidationError::new(
                "Keyboard input has nonzero reserved fields.",
            ));
        }
        let intent = match raw.phase {
            value if value == DhKeyboardPhase::Down as u32 && raw.usage != 0 => Self::Down {
                usage: raw.usage,
                modifiers: raw.modifiers,
            },
            value if value == DhKeyboardPhase::Up as u32 && raw.usage != 0 => Self::Up {
                usage: raw.usage,
                modifiers: raw.modifiers,
            },
            value
                if value == DhKeyboardPhase::CancelAll as u32
                    && raw.usage == 0
                    && raw.modifiers == 0 =>
            {
                Self::CancelAll
            }
            value if value == DhKeyboardPhase::Tap as u32 && raw.usage != 0 => Self::Tap {
                usage: raw.usage,
                modifiers: raw.modifiers,
            },
            _ => return Err(ValidationError::new("Keyboard input is invalid.")),
        };
        Ok((raw.generation, intent))
    }
}

impl HardwareButtonIntent {
    /// Copies and validates one generation-tagged hardware-button input.
    pub(crate) fn copy_from(
        raw: &DhHardwareButtonInput,
    ) -> Result<(DhGeneration, Self), ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhHardwareButtonInput>(),
            raw.abi_version,
            "Hardware-button input uses an unsupported ABI contract.",
        )?;
        if raw.reserved != 0 {
            return Err(ValidationError::new(
                "Hardware-button input has nonzero reserved fields.",
            ));
        }
        let button = match raw.button {
            value if value == DhHardwareButton::Home as u32 => DhHardwareButton::Home,
            value if value == DhHardwareButton::Lock as u32 => DhHardwareButton::Lock,
            value if value == DhHardwareButton::VolumeUp as u32 => DhHardwareButton::VolumeUp,
            value if value == DhHardwareButton::VolumeDown as u32 => DhHardwareButton::VolumeDown,
            value if value == DhHardwareButton::Mute as u32 => DhHardwareButton::Mute,
            value if value == DhHardwareButton::Siri as u32 => DhHardwareButton::Siri,
            _ => return Err(ValidationError::new("Hardware button is invalid.")),
        };
        let phase = match raw.phase {
            value if value == DhButtonPhase::Down as u32 => DhButtonPhase::Down,
            value if value == DhButtonPhase::Up as u32 => DhButtonPhase::Up,
            value if value == DhButtonPhase::Cancel as u32 => DhButtonPhase::Cancel,
            value if value == DhButtonPhase::Tap as u32 => DhButtonPhase::Tap,
            _ => return Err(ValidationError::new("Hardware-button phase is invalid.")),
        };
        Ok((raw.generation, Self { button, phase }))
    }
}

impl VideoControlDatagram {
    /// Copies and validates one complete outbound video control datagram.
    pub(crate) fn copy_from(
        raw: &DhVideoControlDatagram,
    ) -> Result<(DhGeneration, Self), ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhVideoControlDatagram>(),
            raw.abi_version,
            "Video control datagram uses an unsupported ABI contract.",
        )?;
        let bytes = copy_bytes(
            raw.bytes,
            false,
            MAX_VIDEO_CONTROL_DATAGRAM_BYTES,
            "Video control datagram is invalid.",
        )?;
        Ok((
            raw.generation,
            Self {
                bytes: bytes.to_vec(),
            },
        ))
    }
}

impl RotationIntent {
    /// Copies and validates one generation-tagged relative rotation.
    pub(crate) fn copy_from(
        raw: &DhRotationInput,
    ) -> Result<(DhGeneration, Self), ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhRotationInput>(),
            raw.abi_version,
            "Rotation input uses an unsupported ABI contract.",
        )?;
        if raw.reserved != 0 {
            return Err(ValidationError::new(
                "Rotation input has nonzero reserved fields.",
            ));
        }
        let direction = match raw.direction {
            value if value == DhRotationDirection::Left as u32 => Self::Left,
            value if value == DhRotationDirection::Right as u32 => Self::Right,
            _ => return Err(ValidationError::new("Rotation direction is invalid.")),
        };
        Ok((raw.generation, direction))
    }
}

impl ReleaseAllInputIntent {
    /// Copies and validates one generation-tagged input-reset request.
    pub(crate) fn copy_from(
        raw: &DhReleaseAllInput,
    ) -> Result<(DhGeneration, Self), ValidationError> {
        require_struct(
            raw.struct_size,
            size_of::<DhReleaseAllInput>(),
            raw.abi_version,
            "Release-all-input uses an unsupported ABI contract.",
        )?;
        Ok((raw.generation, Self))
    }
}

fn require_struct(
    struct_size: u32,
    expected_size: usize,
    abi_version: u32,
    message: &'static str,
) -> Result<(), ValidationError> {
    if struct_size < expected_size as u32 || abi_version != DH_ABI_VERSION {
        return Err(ValidationError::new(message));
    }
    Ok(())
}

fn copy_uuid(bytes: DhBytes, message: &'static str) -> Result<String, ValidationError> {
    let text = copy_text(bytes, MAX_IDENTIFIER_BYTES, message)?;
    let parsed = uuid::Uuid::parse_str(&text).map_err(|_| ValidationError::new(message))?;
    if !parsed
        .hyphenated()
        .to_string()
        .eq_ignore_ascii_case(text.as_str())
    {
        return Err(ValidationError::new(message));
    }
    Ok(text)
}

fn copy_text(
    bytes: DhBytes,
    maximum: usize,
    message: &'static str,
) -> Result<String, ValidationError> {
    let bytes = copy_bytes(bytes, false, maximum, message)?;
    let text = std::str::from_utf8(bytes.as_slice()).map_err(|_| ValidationError::new(message))?;
    require_owned_text(text, maximum, message)?;
    Ok(text.to_owned())
}

fn require_owned_text(
    text: &str,
    maximum: usize,
    message: &'static str,
) -> Result<(), ValidationError> {
    if text.is_empty()
        || text.len() > maximum
        || text.trim() != text
        || text.chars().any(char::is_control)
    {
        return Err(ValidationError::new(message));
    }
    Ok(())
}

fn copy_exact_array<const COUNT: usize>(
    bytes: DhBytes,
    message: &'static str,
    reject_all_zero: bool,
) -> Result<[u8; COUNT], ValidationError> {
    let copied = copy_bytes(bytes, false, COUNT, message)?;
    let array: [u8; COUNT] = copied
        .as_slice()
        .try_into()
        .map_err(|_| ValidationError::new(message))?;
    if reject_all_zero && array.iter().all(|byte| *byte == 0) {
        return Err(ValidationError::new(message));
    }
    Ok(array)
}

fn copy_bytes(
    bytes: DhBytes,
    may_be_empty: bool,
    maximum: usize,
    message: &'static str,
) -> Result<Zeroizing<Vec<u8>>, ValidationError> {
    if bytes.count == 0 {
        return if may_be_empty {
            Ok(Zeroizing::new(Vec::new()))
        } else {
            Err(ValidationError::new(message))
        };
    }
    if bytes.data.is_null() || bytes.count > maximum {
        return Err(ValidationError::new(message));
    }
    // SAFETY: Every public ABI entry point documents that a non-null span
    // contains `count` readable bytes for the duration of the call.
    let borrowed = unsafe { slice::from_raw_parts(bytes.data, bytes.count) };
    Ok(Zeroizing::new(borrowed.to_vec()))
}

fn copy_endpoint(raw: &DhResolvedEndpoint) -> Result<SocketAddr, ValidationError> {
    if raw.struct_size < size_of::<DhResolvedEndpoint>() as u32
        || raw.port == 0
        || raw.reserved != 0
    {
        return Err(ValidationError::new("Resolved remote endpoint is invalid."));
    }
    match raw.family {
        value if value == DhIpFamily::Ipv4 as u32 => {
            if raw.scope_id != 0 || raw.address[4..].iter().any(|byte| *byte != 0) {
                return Err(ValidationError::new("Resolved IPv4 endpoint is invalid."));
            }
            let address = Ipv4Addr::new(
                raw.address[0],
                raw.address[1],
                raw.address[2],
                raw.address[3],
            );
            if address.is_unspecified() || address.is_multicast() {
                return Err(ValidationError::new("Resolved IPv4 endpoint is invalid."));
            }
            Ok(SocketAddr::new(IpAddr::V4(address), raw.port))
        }
        value if value == DhIpFamily::Ipv6 as u32 => {
            let address = Ipv6Addr::from(raw.address);
            if address.is_unspecified()
                || address.is_multicast()
                || (address.is_unicast_link_local() && raw.scope_id == 0)
            {
                return Err(ValidationError::new("Resolved IPv6 endpoint is invalid."));
            }
            Ok(SocketAddr::V6(SocketAddrV6::new(
                address,
                raw.port,
                0,
                raw.scope_id,
            )))
        }
        _ => Err(ValidationError::new(
            "Resolved remote endpoint has an unsupported address family.",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_record_rejects_a_weak_ed25519_public_key() {
        let record = DhTargetPairingRecord {
            struct_size: size_of::<DhTargetPairingRecord>() as u32,
            abi_version: DH_ABI_VERSION,
            device_id: DhBytes::from_slice(b"device"),
            account_identifier: DhBytes::from_slice(b"account"),
            peer_identifier: DhBytes::from_slice(b"peer"),
            peer_public_key: DhBytes::from_slice(&[0; 32]),
            peer_alternate_irk: DhBytes::from_slice(&[2; 16]),
            display_name: DhBytes::from_slice(b"Target"),
            product_type: DhBytes::from_slice(b"iPhone19,1"),
            completion: DhPairingCompletion::Committed as u32,
            reserved: 0,
        };

        assert!(PeerRecord::copy_from(&record).is_err());
    }

    #[test]
    fn endpoint_preserves_ipv6_scope_and_changes_only_the_port() {
        let service = RemoteService {
            endpoint: "[fe80::1234%7]:1234".parse().unwrap(),
            identifier: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
            auth_tags: vec![[1; 6]],
        };

        assert_eq!(
            service.endpoint_with_port(4321),
            "[fe80::1234%7]:4321".parse().unwrap()
        );
    }

    #[test]
    fn remote_operation_rejects_a_nonmatching_auth_tag_before_network_io() {
        let operation = copy_remote_operation(
            crate::abi::DhRemoteOperation::Screenshot as u32,
            &[3; 6],
            &[],
        );

        assert!(
            operation.is_err(),
            "an auth-tag miss must never reach the remote endpoint"
        );
    }

    #[test]
    fn pair_verify_remote_operation_accepts_an_empty_video_offer() {
        let auth_tag = matching_auth_tag();
        let operation = copy_remote_operation(
            crate::abi::DhRemoteOperation::PairVerify as u32,
            &auth_tag,
            &[],
        );

        assert!(
            matches!(operation.unwrap().mode, RemoteMode::PairVerify),
            "the Pair Verify discovery operation must not require media state"
        );
    }

    #[test]
    fn control_stream_owns_video_negotiation_and_rejects_caller_offers() {
        let auth_tag = matching_auth_tag();
        let operation = copy_remote_operation(
            crate::abi::DhRemoteOperation::ControlStream as u32,
            &auth_tag,
            &[],
        );
        assert!(
            matches!(operation.unwrap().mode, RemoteMode::ControlStream),
            "the native control stream must construct its own video offer"
        );

        let mut caller_offer = Vec::new();
        plist::to_writer_binary(
            &mut caller_offer,
            &plist::Value::Dictionary(plist::Dictionary::new()),
        )
        .unwrap();
        assert!(
            copy_remote_operation(
                crate::abi::DhRemoteOperation::ControlStream as u32,
                &auth_tag,
                &caller_offer,
            )
            .is_err(),
            "caller-owned AVConference negotiation must not re-enter the stream"
        );
    }

    #[test]
    fn pair_verify_remote_operation_keeps_txt_and_media_shape_validation() {
        assert!(
            copy_remote_operation(
                crate::abi::DhRemoteOperation::PairVerify as u32,
                &[3; 5],
                &[],
            )
            .is_err(),
            "each decoded authTag must remain exactly six bytes"
        );
        let auth_tag = matching_auth_tag();
        assert!(
            copy_remote_operation(
                crate::abi::DhRemoteOperation::PairVerify as u32,
                &auth_tag,
                b"unexpected-media-offer",
            )
            .is_err(),
            "Pair Verify discovery must not retain media state"
        );
    }

    fn matching_auth_tag() -> [u8; 6] {
        compute_auth_tag(&[2; 16], "2C59A560-57EB-48FA-8287-482A30ADE1A1")
    }

    fn copy_remote_operation(
        operation: u32,
        auth_tags: &[u8],
        video_negotiator_offer: &[u8],
    ) -> Result<RemoteOperation, ValidationError> {
        let controller_secret = [7; 32];
        let controller_irk = [9; 16];
        let peer_secret = SigningKey::from_bytes(&[5; 32]);
        let peer_public_key = VerifyingKey::from(&peer_secret).to_bytes();
        let peer_irk = [2; 16];
        let controller = DhControllerIdentity {
            struct_size: size_of::<DhControllerIdentity>() as u32,
            abi_version: DH_ABI_VERSION,
            identifier: DhBytes::from_slice(b"1837DF10-6CE8-4272-BC85-D4B287E4D18F"),
            udid: DhBytes::from_slice(b"00008140-DEVICE-HUB-CONTROLLER"),
            long_term_secret_key: DhBytes::from_slice(&controller_secret),
            alternate_irk: DhBytes::from_slice(&controller_irk),
        };
        let target = DhTargetPairingRecord {
            struct_size: size_of::<DhTargetPairingRecord>() as u32,
            abi_version: DH_ABI_VERSION,
            device_id: DhBytes::from_slice(b"00008120-DEVICE-HUB-TARGET"),
            account_identifier: DhBytes::from_slice(b"target-account"),
            peer_identifier: DhBytes::from_slice(b"target-pairing-identifier"),
            peer_public_key: DhBytes::from_slice(&peer_public_key),
            peer_alternate_irk: DhBytes::from_slice(&peer_irk),
            display_name: DhBytes::from_slice(b"Target"),
            product_type: DhBytes::from_slice(b"iPhone19,1"),
            completion: DhPairingCompletion::Committed as u32,
            reserved: 0,
        };
        let endpoint = DhResolvedEndpoint {
            struct_size: size_of::<DhResolvedEndpoint>() as u32,
            family: DhIpFamily::Ipv4 as u32,
            address: [127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            scope_id: 0,
            port: 49_152,
            reserved: 0,
        };
        let service = DhValidatedRemoteService {
            struct_size: size_of::<DhValidatedRemoteService>() as u32,
            abi_version: DH_ABI_VERSION,
            endpoint,
            identifier: DhBytes::from_slice(b"2C59A560-57EB-48FA-8287-482A30ADE1A1"),
            auth_tags: DhBytes::from_slice(auth_tags),
            wire_protocol_version: 26,
            minimum_wire_protocol_version: 8,
            flags: 0,
            reserved: 0,
        };
        let raw = DhRemoteSessionConfig {
            struct_size: size_of::<DhRemoteSessionConfig>() as u32,
            abi_version: DH_ABI_VERSION,
            generation: DhGeneration { high: 1, low: 2 },
            controller_identity: &controller,
            target: &target,
            service: &service,
            operation,
            reserved: 0,
            video_negotiator_offer: if video_negotiator_offer.is_empty() {
                DhBytes::empty()
            } else {
                DhBytes::from_slice(video_negotiator_offer)
            },
            callback: None,
            callback_context: std::ptr::null_mut(),
            media_callback: None,
            media_callback_context: std::ptr::null_mut(),
        };

        // SAFETY: Every pointer in this stack-owned graph remains valid for
        // the duration of the synchronous copy.
        unsafe { RemoteOperation::copy_from(&raw) }
    }

    #[test]
    fn touch_input_validates_atomic_tap_and_cancel_shape() {
        let generation = DhGeneration { high: 1, low: 2 };
        for (phase, expected) in [
            (DhTouchPhase::Down, TouchIntent::Down { x: 10, y: 20 }),
            (DhTouchPhase::Move, TouchIntent::Move { x: 10, y: 20 }),
            (DhTouchPhase::Up, TouchIntent::Up { x: 10, y: 20 }),
            (DhTouchPhase::Tap, TouchIntent::Tap { x: 10, y: 20 }),
        ] {
            let raw = DhTouchInput {
                struct_size: size_of::<DhTouchInput>() as u32,
                abi_version: DH_ABI_VERSION,
                generation,
                phase: phase as u32,
                x: 10,
                y: 20,
                reserved: 0,
            };
            assert_eq!(
                TouchIntent::copy_from(&raw).unwrap(),
                (generation, expected)
            );
        }

        let cancel = DhTouchInput {
            struct_size: size_of::<DhTouchInput>() as u32,
            abi_version: DH_ABI_VERSION,
            generation,
            phase: DhTouchPhase::Cancel as u32,
            x: 0,
            y: 0,
            reserved: 0,
        };
        assert_eq!(
            TouchIntent::copy_from(&cancel).unwrap(),
            (generation, TouchIntent::Cancel)
        );
        assert!(TouchIntent::copy_from(&DhTouchInput { x: 1, ..cancel }).is_err());
        assert!(
            TouchIntent::copy_from(&DhTouchInput {
                phase: u32::MAX,
                ..cancel
            })
            .is_err()
        );
    }

    #[test]
    fn keyboard_button_rotation_and_release_all_are_strictly_typed() {
        let generation = DhGeneration { high: 3, low: 4 };
        let keyboard = |phase, usage| DhKeyboardInput {
            struct_size: size_of::<DhKeyboardInput>() as u32,
            abi_version: DH_ABI_VERSION,
            generation,
            phase,
            usage,
            modifiers: 0,
            reserved: 0,
        };
        assert_eq!(
            KeyboardIntent::copy_from(&keyboard(DhKeyboardPhase::Down as u32, 4)).unwrap(),
            (
                generation,
                KeyboardIntent::Down {
                    usage: 4,
                    modifiers: 0
                }
            )
        );
        assert_eq!(
            KeyboardIntent::copy_from(&DhKeyboardInput {
                modifiers: 0b0000_0011,
                ..keyboard(DhKeyboardPhase::Tap as u32, 4)
            })
            .unwrap(),
            (
                generation,
                KeyboardIntent::Tap {
                    usage: 4,
                    modifiers: 0b0000_0011
                }
            )
        );
        assert!(KeyboardIntent::copy_from(&keyboard(DhKeyboardPhase::Down as u32, 0)).is_err());
        assert!(KeyboardIntent::copy_from(&keyboard(DhKeyboardPhase::Tap as u32, 0)).is_err());
        assert!(
            KeyboardIntent::copy_from(&keyboard(DhKeyboardPhase::CancelAll as u32, 4)).is_err()
        );
        assert!(
            KeyboardIntent::copy_from(&DhKeyboardInput {
                modifiers: 1,
                ..keyboard(DhKeyboardPhase::CancelAll as u32, 0)
            })
            .is_err()
        );

        let button = DhHardwareButtonInput {
            struct_size: size_of::<DhHardwareButtonInput>() as u32,
            abi_version: DH_ABI_VERSION,
            generation,
            button: DhHardwareButton::Siri as u32,
            phase: DhButtonPhase::Down as u32,
            reserved: 0,
        };
        assert!(HardwareButtonIntent::copy_from(&button).is_ok());
        assert_eq!(
            HardwareButtonIntent::copy_from(&DhHardwareButtonInput {
                phase: DhButtonPhase::Tap as u32,
                ..button
            })
            .unwrap(),
            (
                generation,
                HardwareButtonIntent {
                    button: DhHardwareButton::Siri,
                    phase: DhButtonPhase::Tap,
                }
            )
        );
        assert!(
            HardwareButtonIntent::copy_from(&DhHardwareButtonInput {
                button: 7,
                ..button
            })
            .is_err()
        );

        let rotation = DhRotationInput {
            struct_size: size_of::<DhRotationInput>() as u32,
            abi_version: DH_ABI_VERSION,
            generation,
            direction: DhRotationDirection::Right as u32,
            reserved: 0,
        };
        assert_eq!(
            RotationIntent::copy_from(&rotation).unwrap(),
            (generation, RotationIntent::Right)
        );

        let release = DhReleaseAllInput {
            struct_size: size_of::<DhReleaseAllInput>() as u32,
            abi_version: DH_ABI_VERSION,
            generation,
        };
        assert_eq!(
            ReleaseAllInputIntent::copy_from(&release).unwrap(),
            (generation, ReleaseAllInputIntent)
        );
    }

    #[test]
    fn outbound_video_datagrams_are_nonempty_and_udp_bounded() {
        let generation = DhGeneration { high: 5, low: 6 };
        let bytes = [1, 2, 3];
        let valid = DhVideoControlDatagram {
            struct_size: size_of::<DhVideoControlDatagram>() as u32,
            abi_version: DH_ABI_VERSION,
            generation,
            bytes: DhBytes::from_slice(&bytes),
        };
        assert_eq!(
            VideoControlDatagram::copy_from(&valid).unwrap(),
            (
                generation,
                VideoControlDatagram {
                    bytes: bytes.to_vec()
                }
            )
        );
        assert!(
            VideoControlDatagram::copy_from(&DhVideoControlDatagram {
                bytes: DhBytes::empty(),
                ..valid
            })
            .is_err()
        );
        assert!(
            VideoControlDatagram::copy_from(&DhVideoControlDatagram {
                bytes: DhBytes {
                    data: std::ptr::NonNull::<u8>::dangling().as_ptr(),
                    count: usize::from(u16::MAX) + 1,
                },
                ..valid
            })
            .is_err()
        );
    }

    #[test]
    fn copied_protocol_text_rejects_surrounding_whitespace() {
        for invalid in [" name", "name ", "\tname", "name\n"] {
            assert!(require_owned_text(invalid, 32, "invalid").is_err());
        }
        assert!(require_owned_text("name", 32, "invalid").is_ok());
    }
}

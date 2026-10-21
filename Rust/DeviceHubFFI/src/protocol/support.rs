use super::*;
pub(super) async fn verify_developer_readiness(
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

pub(super) async fn open_screenshot_service(
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

pub(super) fn require_prepared_service(
    handshake: &RsdHandshake,
    service_name: &str,
) -> Result<(), PublicFailure> {
    if handshake.services.contains_key(service_name) {
        Ok(())
    } else {
        Err(developer_image_incompatible())
    }
}

pub(super) fn classify_developer_readiness_error(
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

pub(super) fn classify_developer_image_lookup_response(reason: &str) -> PublicFailure {
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

pub(super) fn classify_developer_readiness_connection_error(error: IdeviceError) -> PublicFailure {
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

pub(super) const fn screenshot_service_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "screenshot_service_connect_failed",
        "screenshot",
        true,
        "The advertised screenshot service could not be opened.",
    )
}

pub(super) async fn stage<T, Error, Work>(
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

pub(super) fn pair_verify_failure(error: IdeviceError) -> PublicFailure {
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

pub(super) fn bind_pairing_listener(port: u16) -> Result<TcpListener, PublicFailure> {
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

pub(super) fn parse_tunnel_ip(value: &str) -> Result<IpAddr, PublicFailure> {
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

pub(super) fn validate_rsd_uuid(value: &str) -> Result<String, PublicFailure> {
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

pub(super) fn rsd_snapshot(
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

pub(super) fn optional_rsd_property<'a>(
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

pub(super) fn required_rsd_property<'a>(
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

pub(super) fn validate_rsd_property(
    value: &str,
    maximum_bytes: usize,
) -> Result<(), PublicFailure> {
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

pub(super) fn validation_as_idevice(_: ValidationError) -> idevice::IdeviceError {
    idevice::IdeviceError::UnexpectedResponse(
        "authenticated peer metadata violated the Device Hub boundary".into(),
    )
}

pub(super) fn event_failure_as_idevice(_: PublicFailure) -> idevice::IdeviceError {
    idevice::IdeviceError::UnexpectedResponse(
        "the Pairable Host event dispatcher stopped before PIN delivery".into(),
    )
}

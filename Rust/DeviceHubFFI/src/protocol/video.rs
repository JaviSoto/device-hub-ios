use super::*;
pub(super) struct PreparedVideoDatagram {
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
pub(super) struct LiveVideoState {
    pub(super) assembler: HevcAccessUnitAssembler,
    pub(super) last_configuration_revision: u64,
    pub(super) geometry: DhDisplayGeometry,
}

#[derive(Default)]
pub(super) struct VideoDatagramOutcome {
    pub(super) completed_frame_timestamps: Vec<u32>,
    pub(super) emitted_access_unit: bool,
    pub(super) highest_sequence_number: Option<u16>,
    pub(super) requires_keyframe: bool,
}

/// Complete receiver-side feedback state for one negotiated video stream.
///
/// The sender and receiver SSRCs have different ownership: `our_ssrc` is
/// declared in our offer and identifies feedback, while `media_ssrc` comes from
/// the authenticated answer and identifies the device encoder.
pub(super) struct VideoFeedbackState {
    base_sequence_number: Option<u16>,
    cname: String,
    fir_sequence_number: u8,
    frame_count: u16,
    highest_extended_sequence_number: u32,
    media_ssrc: u32,
    our_ssrc: u32,
}

impl VideoFeedbackState {
    pub(super) fn new(our_ssrc: u32, media_ssrc: u32, cname: String) -> Self {
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

    pub(super) fn consume(&mut self, outcome: &VideoDatagramOutcome) -> Vec<Vec<u8>> {
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

    pub(super) fn periodic_report(&self, elapsed: Duration) -> Option<Vec<u8>> {
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

pub(super) async fn process_live_video_datagram(
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

pub(super) fn prepare_video_datagram(
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

pub(super) fn emit_prepared_video_datagram(
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
pub(super) fn process_video_datagram(
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
pub(super) fn test_orientation_state(
    geometry: DhDisplayGeometry,
) -> Result<OrientationState, PublicFailure> {
    let orientation = test_device_orientation(geometry.orientation)?;
    let non_flat_orientation = test_device_orientation(geometry.non_flat_orientation)?;
    Ok(OrientationState {
        orientation,
        non_flat_orientation,
        locked: geometry.orientation_locked == 1,
    })
}

#[cfg(test)]
pub(super) fn test_device_orientation(raw: u32) -> Result<Orientation, PublicFailure> {
    match orientation_from_raw(raw) {
        DhOrientation::Portrait => Ok(Orientation::Portrait),
        DhOrientation::PortraitUpsideDown => Ok(Orientation::PortraitUpsideDown),
        DhOrientation::LandscapeLeft => Ok(Orientation::LandscapeLeft),
        DhOrientation::LandscapeRight => Ok(Orientation::LandscapeRight),
        _ => Err(unsupported_orientation()),
    }
}

pub(super) fn update_geometry_orientation(
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
pub(super) fn emit_display_geometry_if_complete(
    emitter: &EventEmitter,
    geometry: DhDisplayGeometry,
) -> Result<(), PublicFailure> {
    if geometry.pixel_width == 0 || geometry.pixel_height == 0 {
        return Ok(());
    }
    emitter.display_geometry(geometry)
}

/// Invalidates the consumer's decoder epoch before publishing a discontinuity.
pub(super) fn emit_video_discontinuity(
    last_configuration_revision: &mut u64,
    media: &MediaEmitter,
    discontinuity: DhVideoDiscontinuity,
) -> Result<(), PublicFailure> {
    *last_configuration_revision = 0;
    media.video_discontinuity(discontinuity)
}

pub(super) fn extract_negotiator_answer(response: &plist::Value) -> Result<Vec<u8>, PublicFailure> {
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
pub(super) struct NegotiatedVideo {
    pub(super) payload_type: u8,
    pub(super) ssrc: u32,
}

pub(super) fn parse_negotiated_video(answer: &[u8]) -> Result<NegotiatedVideo, PublicFailure> {
    let stream = parse_screen_video_answer(answer).map_err(screen_video_answer_failure)?;
    Ok(NegotiatedVideo {
        payload_type: stream.payload_type,
        ssrc: stream.ssrc,
    })
}

pub(super) const fn screen_video_answer_failure(error: ScreenVideoAnswerError) -> PublicFailure {
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

pub(super) const fn orientation_value(orientation: &Orientation) -> DhOrientation {
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

pub(super) fn effective_orientation(
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

pub(super) fn concrete_orientation_from_raw(raw: u32) -> Result<DhOrientation, PublicFailure> {
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

pub(super) const fn orientation_from_raw(raw: u32) -> DhOrientation {
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

pub(super) fn classify_hid_error(error: HidError, stage: &'static str) -> PublicFailure {
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

pub(super) const fn invalid_keyboard_transition() -> PublicFailure {
    PublicFailure::new(
        "invalid_input_transition",
        "keyboard_input",
        false,
        "The keyboard transition is invalid for the active device state.",
    )
}

pub(super) const fn media_start_failure() -> PublicFailure {
    PublicFailure::new(
        "display_stream_start_failed",
        "display_stream",
        true,
        "The authenticated display service could not start the media stream.",
    )
}

pub(super) const fn display_service_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "display_service_connect_failed",
        "display_stream",
        true,
        "The advertised display service could not be opened.",
    )
}

pub(super) const fn input_service_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "input_service_connect_failed",
        "input",
        true,
        "An advertised authenticated input service could not be opened.",
    )
}

pub(super) const fn orientation_service_connection_failed() -> PublicFailure {
    PublicFailure::new(
        "orientation_service_connect_failed",
        "rotation",
        true,
        "The advertised orientation service could not be opened.",
    )
}

pub(super) const fn orientation_state_failed() -> PublicFailure {
    PublicFailure::new(
        "orientation_query_failed",
        "rotation",
        true,
        "The authenticated orientation service did not return its current state.",
    )
}

pub(super) const fn video_control_delivery_failed() -> PublicFailure {
    PublicFailure::new(
        "video_control_delivery_failed",
        "video_control",
        true,
        "The outbound video control datagram could not be delivered.",
    )
}

pub(super) const fn unsupported_video_answer_extraction() -> PublicFailure {
    PublicFailure::new(
        "unsupported_protocol_version",
        "video_answer_extraction",
        false,
        "The display service did not return one bounded video negotiation answer.",
    )
}

pub(super) const fn unsupported_video_negotiation(
    stage: &'static str,
    message: &'static str,
) -> PublicFailure {
    PublicFailure::new("unsupported_protocol_version", stage, false, message)
}

pub(super) const fn video_negotiation_rejected() -> PublicFailure {
    PublicFailure::new(
        "video_negotiation_rejected",
        "video_negotiation",
        false,
        "The authenticated display service rejected the receiver's video offer.",
    )
}

use super::*;
pub(super) async fn run_control_stream(
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

pub(super) fn input_trace_label(command: &ControlCommand) -> Option<String> {
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

pub(super) fn require_control_services(handshake: &RsdHandshake) -> Result<(), PublicFailure> {
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
pub(super) struct InputCleanupState {
    pub(super) touch_active: bool,
    pub(super) pressed_keys: BTreeMap<u16, u8>,
    pub(super) pressed_buttons: Vec<HardwareButton>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum InputReleaseAction {
    Touch,
    Keyboard,
    HardwareButton(HardwareButton),
}

impl InputCleanupState {
    pub(super) fn release_plan(&self) -> Vec<InputReleaseAction> {
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

pub(super) trait InputReleaseSink {
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

pub(super) async fn release_all_inputs_with_sink(
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

pub(super) trait KeyboardStateSink {
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

pub(super) async fn handle_keyboard_intent_with_sink(
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

pub(super) trait HardwareButtonSink {
    async fn send(&mut self, button: HardwareButton, state: ButtonState) -> Result<(), HidError>;
}

/// Returns the minimum press duration iOS requires for a semantic button tap.
///
/// The side and Siri buttons intentionally distinguish a press-and-hold from
/// the shorter debounce-safe tap used by Home and media controls.
pub(super) fn hardware_button_tap_hold(button: HardwareButton) -> Duration {
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

pub(super) async fn handle_hardware_button_with_sink(
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

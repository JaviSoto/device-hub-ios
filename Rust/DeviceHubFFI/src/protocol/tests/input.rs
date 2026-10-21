use super::*;

#[derive(Default)]
struct MockKeyboardStateSink {
    attempts: Vec<Vec<u8>>,
    fail_at: Option<usize>,
}

impl KeyboardStateSink for MockKeyboardStateSink {
    async fn replace(&mut self, pressed: BTreeSet<KeyboardUsage>) -> Result<(), HidError> {
        self.attempts
            .push(pressed.into_iter().map(KeyboardUsage::raw).collect());
        if self.fail_at == Some(self.attempts.len()) {
            Err(HidError::Device(IdeviceError::ServiceNotFound))
        } else {
            Ok(())
        }
    }
}

#[derive(Default)]
struct MockHardwareButtonSink {
    attempts: Vec<(HardwareButton, ButtonState)>,
    fail_at: Option<usize>,
}

impl HardwareButtonSink for MockHardwareButtonSink {
    async fn send(&mut self, button: HardwareButton, state: ButtonState) -> Result<(), HidError> {
        self.attempts.push((button, state));
        if self.fail_at == Some(self.attempts.len()) {
            Err(HidError::Device(IdeviceError::ServiceNotFound))
        } else {
            Ok(())
        }
    }
}

#[test]
fn hardware_button_taps_use_the_device_required_hold_duration() {
    assert_eq!(
        hardware_button_tap_hold(HardwareButton::Home),
        Duration::from_millis(50)
    );
    assert_eq!(
        hardware_button_tap_hold(HardwareButton::Lock),
        Duration::from_millis(300)
    );
    assert_eq!(
        hardware_button_tap_hold(HardwareButton::Siri),
        Duration::from_secs(1)
    );
    assert_eq!(
        hardware_button_tap_hold(HardwareButton::VolumeUp),
        Duration::from_millis(50)
    );
}

#[tokio::test]
async fn semantic_taps_emit_ordered_edges_and_retain_failed_releases_for_cleanup() {
    let mut keyboard_cleanup = InputCleanupState {
        pressed_keys: BTreeMap::from([(0x05, 0b0000_0010)]),
        ..Default::default()
    };
    let mut keyboard = MockKeyboardStateSink::default();
    handle_keyboard_intent_with_sink(
        KeyboardIntent::Tap {
            usage: 0x04,
            modifiers: 0b0000_0001,
        },
        &mut keyboard_cleanup,
        &mut keyboard,
    )
    .await
    .unwrap();
    assert_eq!(
        keyboard.attempts,
        vec![vec![0x04, 0x05, 0xE0, 0xE1], vec![0x05, 0xE1]]
    );
    assert_eq!(
        keyboard_cleanup.pressed_keys,
        BTreeMap::from([(0x05, 0b0000_0010)])
    );

    let mut failed_keyboard_cleanup = InputCleanupState::default();
    let mut failed_keyboard = MockKeyboardStateSink {
        fail_at: Some(2),
        ..Default::default()
    };
    let failure = handle_keyboard_intent_with_sink(
        KeyboardIntent::Tap {
            usage: 0x04,
            modifiers: 0b1000_0001,
        },
        &mut failed_keyboard_cleanup,
        &mut failed_keyboard,
    )
    .await
    .unwrap_err();
    assert_eq!(failure.code, "input_delivery_failed");
    assert_eq!(
        failed_keyboard.attempts,
        vec![vec![0x04, 0xE0, 0xE7], Vec::new()]
    );
    assert_eq!(
        failed_keyboard_cleanup.pressed_keys,
        BTreeMap::from([(0x04, 0b1000_0001)])
    );

    let intent = crate::model::HardwareButtonIntent {
        button: DhHardwareButton::Home,
        phase: DhButtonPhase::Tap,
    };
    let mut button_cleanup = InputCleanupState::default();
    let mut button = MockHardwareButtonSink::default();
    handle_hardware_button_with_sink(intent, &mut button_cleanup, &mut button)
        .await
        .unwrap();
    assert_eq!(
        button.attempts,
        vec![
            (HardwareButton::Home, ButtonState::Down),
            (HardwareButton::Home, ButtonState::Up),
        ]
    );
    assert!(button_cleanup.pressed_buttons.is_empty());

    let mut failed_button_cleanup = InputCleanupState::default();
    let mut failed_button = MockHardwareButtonSink {
        fail_at: Some(2),
        ..Default::default()
    };
    let failure =
        handle_hardware_button_with_sink(intent, &mut failed_button_cleanup, &mut failed_button)
            .await
            .unwrap_err();
    assert_eq!(failure.code, "input_delivery_failed");
    assert_eq!(
        failed_button.attempts,
        vec![
            (HardwareButton::Home, ButtonState::Down),
            (HardwareButton::Home, ButtonState::Up),
        ]
    );
    assert_eq!(
        failed_button_cleanup.pressed_buttons,
        vec![HardwareButton::Home]
    );
}

#[derive(Default)]
struct MockReleaseSink {
    attempts: Vec<InputReleaseAction>,
    fail: Option<InputReleaseAction>,
}

impl InputReleaseSink for MockReleaseSink {
    async fn release(&mut self, action: InputReleaseAction) -> Result<(), HidError> {
        self.attempts.push(action);
        if self.fail == Some(action) {
            Err(HidError::Device(IdeviceError::ServiceNotFound))
        } else {
            Ok(())
        }
    }
}

#[test]
fn release_all_is_reverse_ordered_idempotent_and_continues_after_failure() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let mut cleanup = InputCleanupState {
            touch_active: true,
            pressed_keys: BTreeMap::from([(0x04, 0), (0x05, 0b0000_0010)]),
            pressed_buttons: vec![HardwareButton::Home, HardwareButton::VolumeUp],
        };
        let mut sink = MockReleaseSink {
            fail: Some(InputReleaseAction::Keyboard),
            ..Default::default()
        };

        let failure = release_all_inputs_with_sink(&mut cleanup, &mut sink)
            .await
            .unwrap_err();
        assert_eq!(failure.stage, "input_cleanup");
        assert_eq!(
            sink.attempts,
            vec![
                InputReleaseAction::Touch,
                InputReleaseAction::Keyboard,
                InputReleaseAction::HardwareButton(HardwareButton::VolumeUp),
                InputReleaseAction::HardwareButton(HardwareButton::Home),
            ]
        );
        assert!(!cleanup.touch_active);
        assert_eq!(
            cleanup.pressed_keys,
            BTreeMap::from([(0x04, 0), (0x05, 0b0000_0010)])
        );
        assert!(cleanup.pressed_buttons.is_empty());

        let mut retry = MockReleaseSink::default();
        release_all_inputs_with_sink(&mut cleanup, &mut retry)
            .await
            .unwrap();
        assert_eq!(retry.attempts, vec![InputReleaseAction::Keyboard]);
        assert!(cleanup.release_plan().is_empty());

        let mut idempotent = MockReleaseSink::default();
        release_all_inputs_with_sink(&mut cleanup, &mut idempotent)
            .await
            .unwrap();
        assert!(idempotent.attempts.is_empty());
    });
}

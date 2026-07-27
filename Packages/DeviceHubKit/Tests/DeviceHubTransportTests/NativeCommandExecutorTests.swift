import CustomDump
import DeviceHubCore
@testable import DeviceHubTransport
import Testing

@Suite("Native command executor", .timeLimit(.minutes(1)))
struct NativeCommandExecutorTests {
    @Test("commands execute in submission order without overlap")
    func commandsAreFIFO() async throws {
        let sender = ControlledNativeSender()
        let executor = NativeCommandExecutor { command async throws(NativeSessionFailure) in
            try await sender.send(command)
        }
        let first = DeviceCommand.button(.home, phase: .press)
        let second = DeviceCommand.button(.home, phase: .release)
        let third = DeviceCommand.button(.lock, phase: .press)

        let firstSubmission = try await executor.submit(first)
        await sender.waitUntilReceived(1)
        let secondSubmission = try await executor.submit(second)
        let thirdSubmission = try await executor.submit(third)

        var receivedCommands = await sender.receivedCommands()
        expectNoDifference(receivedCommands, [first])
        await sender.completeNext()
        try await firstSubmission.value()

        await sender.waitUntilReceived(2)
        receivedCommands = await sender.receivedCommands()
        expectNoDifference(receivedCommands, [first, second])
        await sender.completeNext()
        try await secondSubmission.value()

        await sender.waitUntilReceived(3)
        receivedCommands = await sender.receivedCommands()
        expectNoDifference(receivedCommands, [first, second, third])
        await sender.completeNext()
        try await thirdSubmission.value()

        #expect(await sender.maximumConcurrentSendCount() == 1)
    }

    @Test("overflow is rejected without disturbing accepted commands")
    func overflowRejectsOnlyTheNewCommand() async throws {
        let sender = ControlledNativeSender()
        let executor = NativeCommandExecutor(
            pendingCommandCapacity: 2
        ) { command async throws(NativeSessionFailure) in
            try await sender.send(command)
        }
        let first = DeviceCommand.rotation(.rotateLeft)
        let second = DeviceCommand.rotation(.rotateRight)
        let third = DeviceCommand.buttonTap(.lock)

        let firstSubmission = try await executor.submit(first)
        await sender.waitUntilReceived(1)
        let secondSubmission = try await executor.submit(second)
        let thirdSubmission = try await executor.submit(third)

        do {
            _ = try await executor.submit(.rotation(.rotateLeft))
            Issue.record("An overflowing command was accepted.")
        } catch {
            #expect(error == NativeCommandExecutorError.saturated)
        }

        await sender.completeNext()
        try await firstSubmission.value()
        await sender.waitUntilReceived(2)
        await sender.completeNext()
        try await secondSubmission.value()
        await sender.waitUntilReceived(3)
        await sender.completeNext()
        try await thirdSubmission.value()

        let receivedCommands = await sender.receivedCommands()
        expectNoDifference(receivedCommands, [first, second, third])
    }

    @Test("shutdown preserves the reserved release-all barrier at saturation")
    func shutdownPreservesReleaseAllBarrier() async throws {
        let sender = ControlledNativeSender()
        let executor = NativeCommandExecutor(
            pendingCommandCapacity: 2
        ) { command async throws(NativeSessionFailure) in
            try await sender.send(command)
        }
        let first = try await executor.submit(.rotation(.rotateLeft))
        await sender.waitUntilReceived(1)
        let queuedFirst = try await executor.submit(
            .rotation(.rotateRight)
        )
        let queuedSecond = try await executor.submit(
            .buttonTap(.lock)
        )
        let releaseAll = try await executor.submit(.releaseAllInput)

        do {
            _ = try await executor.submit(.releaseAllInput)
            Issue.record("A second reserved release-all was accepted.")
        } catch {
            #expect(error == NativeCommandExecutorError.saturated)
        }

        let shutdown = Task {
            await executor.shutdown()
        }
        do {
            try await queuedFirst.value()
            Issue.record("A queued command executed after shutdown began.")
        } catch {
            #expect(error == NativeCommandExecutorError.disconnected)
        }
        do {
            try await queuedSecond.value()
            Issue.record("A queued command executed after shutdown began.")
        } catch {
            #expect(error == NativeCommandExecutorError.disconnected)
        }

        await sender.completeNext()
        try await first.value()
        await sender.waitUntilReceived(2)
        let receivedBeforeRelease = await sender.receivedCommands()
        #expect(receivedBeforeRelease.last == .releaseAllInput)
        await sender.completeNext()
        try await releaseAll.value()

        #expect(await shutdown.value == nil)
        let receivedCommands = await sender.receivedCommands()
        expectNoDifference(
            receivedCommands,
            [.rotation(.rotateLeft), .releaseAllInput]
        )
    }

    @Test("atomic taps each cross the native boundary once")
    func atomicTapsSendExactlyOnce() async throws {
        let sender = ControlledNativeSender()
        let executor = NativeCommandExecutor { command async throws(NativeSessionFailure) in
            try await sender.send(command)
        }
        let keyTap = DeviceCommand.keyTap(
            .character("a"),
            modifiers: [.command, .shift]
        )
        let buttonTap = DeviceCommand.buttonTap(.home)

        let keySubmission = try await executor.submit(keyTap)
        await sender.waitUntilReceived(1)
        await sender.completeNext()
        try await keySubmission.value()
        let buttonSubmission = try await executor.submit(buttonTap)
        await sender.waitUntilReceived(2)
        await sender.completeNext()
        try await buttonSubmission.value()

        let receivedCommands = await sender.receivedCommands()
        expectNoDifference(receivedCommands, [keyTap, buttonTap])
    }

    @Test("shutdown rejects queued and later commands")
    func shutdownRejectsCommands() async throws {
        let sender = ControlledNativeSender()
        let executor = NativeCommandExecutor { command async throws(NativeSessionFailure) in
            try await sender.send(command)
        }
        let first = try await executor.submit(.rotation(.rotateLeft))
        await sender.waitUntilReceived(1)
        let queued = try await executor.submit(.rotation(.rotateRight))

        let shutdown = Task {
            await executor.shutdown()
        }
        do {
            try await queued.value()
            Issue.record("A queued command executed after shutdown began.")
        } catch {
            #expect(error == NativeCommandExecutorError.disconnected)
        }
        do {
            _ = try await executor.submit(.buttonTap(.home))
            Issue.record("A command was accepted after shutdown began.")
        } catch {
            #expect(error == NativeCommandExecutorError.disconnected)
        }

        await sender.completeNext()
        try await first.value()
        await sender.waitUntilReceived(2)
        var receivedCommands = await sender.receivedCommands()
        #expect(receivedCommands.last == .releaseAllInput)
        await sender.completeNext()
        #expect(await shutdown.value == nil)
        receivedCommands = await sender.receivedCommands()
        expectNoDifference(
            receivedCommands,
            [.rotation(.rotateLeft), .releaseAllInput]
        )
    }

    @Test("shutdown releases held input in reverse acquisition order")
    func shutdownReleasesHeldInput() async throws {
        let sender = ControlledNativeSender()
        let executor = NativeCommandExecutor { command async throws(NativeSessionFailure) in
            try await sender.send(command)
        }
        let began = TouchCommand(
            contactID: 7,
            point: TargetPixelPoint(x: 10, y: 20),
            phase: .began
        )
        let moved = TouchCommand(
            contactID: 7,
            point: TargetPixelPoint(x: 11, y: 21),
            phase: .moved
        )
        let key = KeyCommand(
            key: .character("a"),
            phase: .press,
            modifiers: [.command, .shift]
        )
        let originals: [DeviceCommand] = [
            .button(.home, phase: .press),
            .touch(began),
            .key(key),
            .touch(moved)
        ]

        for (offset, command) in originals.enumerated() {
            let submission = try await executor.submit(command)
            await sender.waitUntilReceived(offset + 1)
            await sender.completeNext()
            try await submission.value()
        }

        let shutdown = Task {
            await executor.shutdown()
        }
        let releaseAllFailure = NativeSessionFailure(
            code: "invalid_state",
            stage: "session_teardown",
            retryable: false
        )
        await sender.waitUntilReceived(originals.count + 1)
        var receivedCommands = await sender.receivedCommands()
        #expect(receivedCommands.last == .releaseAllInput)
        await sender.completeNext(with: .failure(releaseAllFailure))
        let releases: [DeviceCommand] = [
            .key(KeyCommand(
                key: key.key,
                phase: .release,
                modifiers: key.modifiers
            )),
            .touch(TouchCommand(
                contactID: moved.contactID,
                point: moved.point,
                phase: .cancelled
            )),
            .button(.home, phase: .release)
        ]
        for (offset, release) in releases.enumerated() {
            await sender.waitUntilReceived(originals.count + offset + 2)
            receivedCommands = await sender.receivedCommands()
            #expect(receivedCommands.last == release)
            await sender.completeNext()
        }

        #expect(await shutdown.value == releaseAllFailure)
        receivedCommands = await sender.receivedCommands()
        expectNoDifference(
            receivedCommands,
            originals + [.releaseAllInput] + releases
        )
    }
}

private actor ControlledNativeSender {
    private var activeSendCount = 0
    private var commands: [DeviceCommand] = []
    private var completions: [
        CheckedContinuation<Result<Void, NativeSessionFailure>, Never>
    ] = []
    private var maximumActiveSendCount = 0
    private var receiptWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func send(
        _ command: DeviceCommand
    ) async throws(NativeSessionFailure) {
        activeSendCount += 1
        maximumActiveSendCount = max(
            maximumActiveSendCount,
            activeSendCount
        )
        commands.append(command)
        resumeSatisfiedReceiptWaiters()
        let result = await withCheckedContinuation { continuation in
            completions.append(continuation)
        }
        activeSendCount -= 1
        try result.get()
    }

    func waitUntilReceived(_ count: Int) async {
        guard commands.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            receiptWaiters.append((count, continuation))
        }
    }

    func completeNext(
        with result: Result<Void, NativeSessionFailure> = .success(())
    ) {
        completions.removeFirst().resume(returning: result)
    }

    func receivedCommands() -> [DeviceCommand] {
        commands
    }

    func maximumConcurrentSendCount() -> Int {
        maximumActiveSendCount
    }

    private func resumeSatisfiedReceiptWaiters() {
        let satisfied = receiptWaiters.filter {
            commands.count >= $0.count
        }
        receiptWaiters.removeAll {
            commands.count >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

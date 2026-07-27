import DeviceHubCore

/// Sanitized terminal outcomes from the session's ordered command lane.
enum NativeCommandExecutorError: Error, Equatable, Sendable {
    case disconnected
    case native(NativeSessionFailure)
    case saturated
}

/// Awaitable completion for a command accepted by the ordered session lane.
struct NativeCommandSubmission: Sendable {
    fileprivate let promise: NativeCommandPromise

    func value() async throws(NativeCommandExecutorError) {
        try await promise.value().get()
    }
}

/// Serializes semantic commands before they enter an artifact-backed session.
actor NativeCommandExecutor {
    private static let defaultPendingCommandCapacity = 64

    typealias SendOperation =
        @Sendable (DeviceCommand) async throws(NativeSessionFailure) -> Void

    private struct PendingCommand {
        let command: DeviceCommand
        let promise: NativeCommandPromise
    }

    fileprivate enum HeldInput {
        case button(DeviceButton)
        case key(DeviceKey, modifiers: KeyModifiers)
        case touch(contactID: UInt8, point: TargetPixelPoint)

        var releaseCommand: DeviceCommand {
            switch self {
            case let .button(button):
                .button(button, phase: .release)
            case let .key(key, modifiers):
                .key(KeyCommand(
                    key: key,
                    phase: .release,
                    modifiers: modifiers
                ))
            case let .touch(contactID, point):
                .touch(TouchCommand(
                    contactID: contactID,
                    point: point,
                    phase: .cancelled
                ))
            }
        }
    }

    private var acceptingCommands = true
    private var didReleaseAllInput = false
    private var heldInputs: [HeldInput] = []
    private var pendingCommands: [PendingCommand] = []
    private let pendingCommandCapacity: Int
    private let sendOperation: SendOperation
    private var shutdownTask: Task<NativeSessionFailure?, Never>?
    private var workerTask: Task<Void, Never>?

    init(
        pendingCommandCapacity: Int = defaultPendingCommandCapacity,
        send: @escaping SendOperation
    ) {
        precondition(
            pendingCommandCapacity > 0,
            "The native command queue capacity must be positive."
        )
        self.pendingCommandCapacity = pendingCommandCapacity
        sendOperation = send
    }

    /// Enqueues one command and returns independently awaitable completion.
    ///
    /// Ordinary pending work is capped. One additional slot is reserved for a
    /// release-all barrier so saturation cannot prevent input cleanup.
    func submit(
        _ command: DeviceCommand
    ) throws(NativeCommandExecutorError) -> NativeCommandSubmission {
        guard acceptingCommands else {
            throw .disconnected
        }
        if command == .releaseAllInput {
            guard !pendingCommands.contains(where: {
                $0.command == .releaseAllInput
            }) else {
                throw .saturated
            }
        } else {
            let ordinaryPendingCount = pendingCommands.count {
                $0.command != .releaseAllInput
            }
            guard ordinaryPendingCount < pendingCommandCapacity else {
                throw .saturated
            }
        }
        let promise = NativeCommandPromise()
        pendingCommands.append(
            PendingCommand(command: command, promise: promise)
        )
        startWorkerIfNeeded()
        return NativeCommandSubmission(promise: promise)
    }

    /// Stops accepting work and waits until an in-flight native call returns.
    func shutdown() async -> NativeSessionFailure? {
        if let shutdownTask {
            return await shutdownTask.value
        }

        acceptingCommands = false
        let rejectedCommands = pendingCommands.filter {
            $0.command != .releaseAllInput
        }
        pendingCommands.removeAll {
            $0.command != .releaseAllInput
        }
        for pending in rejectedCommands {
            await pending.promise.resolve(.failure(.disconnected))
        }

        let workerTask = workerTask
        let shutdownTask = Task<NativeSessionFailure?, Never> { [weak self] in
            await workerTask?.value
            return await self?.performCleanup()
        }
        self.shutdownTask = shutdownTask
        return await shutdownTask.value
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else {
            return
        }
        workerTask = Task {
            await self.drain()
        }
    }

    private func drain() async {
        while !pendingCommands.isEmpty {
            let pending = pendingCommands.removeFirst()
            do {
                try await sendOperation(pending.command)
                trackSuccessful(pending.command)
                await pending.promise.resolve(.success(()))
            } catch {
                await pending.promise.resolve(.failure(.native(error)))
            }
        }
        workerTask = nil
    }

    private func trackSuccessful(_ command: DeviceCommand) {
        switch command {
        case .releaseAllInput:
            didReleaseAllInput = true
            heldInputs.removeAll(keepingCapacity: false)

        case let .button(button, phase):
            didReleaseAllInput = false
            switch phase {
            case .press:
                guard !heldInputs.containsButton(button) else {
                    return
                }
                heldInputs.append(.button(button))
            case .release:
                heldInputs.removeLastButton(button)
            }

        case let .key(command):
            didReleaseAllInput = false
            switch command.phase {
            case .press:
                if let index = heldInputs.lastKeyIndex(command.key) {
                    heldInputs[index] = .key(
                        command.key,
                        modifiers: command.modifiers
                    )
                } else {
                    heldInputs.append(.key(
                        command.key,
                        modifiers: command.modifiers
                    ))
                }
            case .release:
                heldInputs.removeLastKey(command.key)
            }

        case let .touch(command):
            didReleaseAllInput = false
            switch command.phase {
            case .began:
                if let index =
                    heldInputs.lastTouchIndex(command.contactID)
                {
                    heldInputs[index] = .touch(
                        contactID: command.contactID,
                        point: command.point
                    )
                } else {
                    heldInputs.append(.touch(
                        contactID: command.contactID,
                        point: command.point
                    ))
                }
            case .moved:
                guard let index =
                    heldInputs.lastTouchIndex(command.contactID)
                else {
                    return
                }
                heldInputs[index] = .touch(
                    contactID: command.contactID,
                    point: command.point
                )
            case .cancelled, .ended:
                heldInputs.removeLastTouch(command.contactID)
            }

        case .buttonTap, .keyTap, .rotation, .tap:
            break
        }
    }

    private func performCleanup() async -> NativeSessionFailure? {
        var firstFailure: NativeSessionFailure?
        if !didReleaseAllInput {
            do {
                try await sendOperation(.releaseAllInput)
                trackSuccessful(.releaseAllInput)
            } catch {
                firstFailure = error
            }
        }
        let releaseFailure = await releaseHeldInputs()
        return firstFailure ?? releaseFailure
    }

    private func releaseHeldInputs() async -> NativeSessionFailure? {
        let releases = heldInputs.reversed().map(\.releaseCommand)
        heldInputs.removeAll(keepingCapacity: false)
        var firstFailure: NativeSessionFailure?
        for release in releases {
            do {
                try await sendOperation(release)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        return firstFailure
    }
}

private extension [NativeCommandExecutor.HeldInput] {
    func containsButton(_ button: DeviceButton) -> Bool {
        lastIndex {
            guard case let .button(candidate) = $0 else {
                return false
            }
            return candidate == button
        } != nil
    }

    func lastKeyIndex(_ key: DeviceKey) -> Index? {
        lastIndex {
            guard case let .key(candidate, _) = $0 else {
                return false
            }
            return candidate == key
        }
    }

    func lastTouchIndex(_ contactID: UInt8) -> Index? {
        lastIndex {
            guard case let .touch(candidate, _) = $0 else {
                return false
            }
            return candidate == contactID
        }
    }

    mutating func removeLastButton(_ button: DeviceButton) {
        guard let index = lastIndex(where: {
            guard case let .button(candidate) = $0 else {
                return false
            }
            return candidate == button
        }) else {
            return
        }
        remove(at: index)
    }

    mutating func removeLastKey(_ key: DeviceKey) {
        guard let index = lastKeyIndex(key) else {
            return
        }
        remove(at: index)
    }

    mutating func removeLastTouch(_ contactID: UInt8) {
        guard let index = lastTouchIndex(contactID) else {
            return
        }
        remove(at: index)
    }
}

private actor NativeCommandPromise {
    private var result: Result<Void, NativeCommandExecutorError>?
    private var waiters: [
        CheckedContinuation<Result<Void, NativeCommandExecutorError>, Never>
    ] = []

    func value() async -> Result<Void, NativeCommandExecutorError> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve(
        _ result: Result<Void, NativeCommandExecutorError>
    ) {
        guard self.result == nil else {
            return
        }
        self.result = result
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}

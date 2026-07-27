import DeviceHubCore
import Foundation

extension RemotePairingBonjourTransport {
    private struct CandidateVerificationJob: Sendable {
        let deviceID: DeviceID
        let revision: UInt64
        let service: ValidatedRemotePairingService
        let serviceKey: String
    }

    private enum CandidateVerificationStep {
        case job(CandidateVerificationJob)
        case resolutionFailed
        case stopped
    }

    func enqueueCandidateVerification(
        _ serviceKey: String,
        state: inout BrowsingState
    ) {
        guard
            state.servicesByName[serviceKey] != nil,
            state.matchesByServiceName[serviceKey] == nil,
            !state.queuedVerificationServiceNames.contains(serviceKey),
            !state.rejectedServiceNames.contains(serviceKey),
            let deviceID = resolvedDeviceID(
                for: serviceKey,
                state: state
            ),
            !claimedDeviceIDs.contains(deviceID)
        else {
            return
        }
        state.pendingVerificationServiceNames.append(serviceKey)
        state.queuedVerificationServiceNames.insert(serviceKey)
    }

    func startCandidateVerificationIfNeeded(token: UUID) {
        guard
            candidateVerificationTask == nil,
            let state = browsingState,
            state.token == token,
            !state.pendingVerificationServiceNames.isEmpty
        else {
            return
        }

        let taskToken = UUID()
        candidateVerificationToken = taskToken
        candidateVerificationTask = Task { [weak self] in
            await self?.runCandidateVerification(
                browsingToken: token,
                taskToken: taskToken
            )
        }
    }

    private func runCandidateVerification(
        browsingToken: UUID,
        taskToken: UUID
    ) async {
        candidateLoop: while !Task.isCancelled {
            switch nextCandidateVerificationStep(
                browsingToken: browsingToken,
                taskToken: taskToken
            ) {
            case let .job(job):
                let didVerify = await verifyCandidate(
                    job.deviceID,
                    job.service
                )
                guard !Task.isCancelled else {
                    break
                }
                await completeCandidateVerification(
                    job,
                    verifiedDeviceID: didVerify ? job.deviceID : nil,
                    browsingToken: browsingToken,
                    taskToken: taskToken
                )
            case .resolutionFailed:
                await record(.ambiguousAnnouncement)
            case .stopped:
                break candidateLoop
            }
        }

        guard candidateVerificationToken == taskToken else {
            return
        }
        activeCandidateDeviceID = nil
        activeCandidateServiceKey = nil
        candidateVerificationTask = nil
        candidateVerificationToken = nil
        startCandidateVerificationIfNeeded(token: browsingToken)
    }

    private func nextCandidateVerificationStep(
        browsingToken: UUID,
        taskToken: UUID
    ) -> CandidateVerificationStep {
        guard
            candidateVerificationToken == taskToken,
            var state = browsingState,
            state.token == browsingToken
        else {
            return .stopped
        }

        while !state.pendingVerificationServiceNames.isEmpty {
            let serviceKey = state.pendingVerificationServiceNames.removeFirst()
            state.queuedVerificationServiceNames.remove(serviceKey)
            guard
                let service = state.servicesByName[serviceKey],
                let revision = state.revisionsByServiceName[serviceKey]
            else {
                continue
            }
            let deviceID: DeviceID
            do {
                guard let resolvedDeviceID = try KnownDeviceResolver.resolve(
                    service,
                    among: state.knownDevices
                ) else {
                    continue
                }
                deviceID = resolvedDeviceID
            } catch {
                browsingState = state
                return .resolutionFailed
            }
            browsingState = state
            activeCandidateDeviceID = deviceID
            activeCandidateServiceKey = serviceKey
            return .job(CandidateVerificationJob(
                deviceID: deviceID,
                revision: revision,
                service: service,
                serviceKey: serviceKey
            ))
        }

        browsingState = state
        activeCandidateDeviceID = nil
        activeCandidateServiceKey = nil
        return .stopped
    }

    private func completeCandidateVerification(
        _ job: CandidateVerificationJob,
        verifiedDeviceID: DeviceID?,
        browsingToken: UUID,
        taskToken: UUID
    ) async {
        guard
            candidateVerificationToken == taskToken,
            var state = browsingState,
            state.token == browsingToken,
            state.revisionsByServiceName[job.serviceKey] == job.revision,
            state.servicesByName[job.serviceKey] == job.service,
            !claimedDeviceIDs.contains(job.deviceID)
        else {
            return
        }

        activeCandidateDeviceID = nil
        activeCandidateServiceKey = nil
        if let verifiedDeviceID {
            state.rejectedServiceNames.remove(job.serviceKey)
            state.matchesByServiceName[job.serviceKey] = verifiedDeviceID
            browsingState = state
            yieldAvailability(state)
        } else {
            state.rejectedServiceNames.insert(job.serviceKey)
            browsingState = state
            await record(.unknownAnnouncement)
        }
    }

    func stopCandidateVerification() async {
        guard let task = candidateVerificationTask else {
            activeCandidateDeviceID = nil
            activeCandidateServiceKey = nil
            candidateVerificationToken = nil
            return
        }
        candidateVerificationTask = nil
        candidateVerificationToken = nil
        activeCandidateDeviceID = nil
        activeCandidateServiceKey = nil
        task.cancel()
        await task.value
    }

    func removePendingVerification(
        for deviceID: DeviceID,
        state: inout BrowsingState
    ) {
        let serviceKeys = Set(
            state.servicesByName.keys.filter {
                resolvedDeviceID(for: $0, state: state) == deviceID
            }
        )
        state.pendingVerificationServiceNames.removeAll {
            serviceKeys.contains($0)
        }
        state.queuedVerificationServiceNames.subtract(serviceKeys)
    }

    func resolvedDeviceID(
        for serviceKey: String,
        state: BrowsingState
    ) -> DeviceID? {
        guard let service = state.servicesByName[serviceKey] else {
            return nil
        }
        do {
            return try KnownDeviceResolver.resolve(
                service,
                among: state.knownDevices
            )
        } catch {
            recordCandidateResolutionFailure()
            return nil
        }
    }

    /// Preserves synchronous fail-closed lookup while making resolver
    /// invariant failures visible through the redacted diagnostics channel.
    private func recordCandidateResolutionFailure() {
        Task { [weak self] in
            await self?.record(.ambiguousAnnouncement)
        }
    }

    func yieldAvailability(_ state: BrowsingState) {
        state.continuation.yield(
            availabilitySnapshot(
                knownDevices: state.knownDevices,
                reachableDeviceIDs: Set(
                    state.matchesByServiceName.values
                ).union(claimedDeviceIDs)
            )
        )
    }

    func availabilitySnapshot(
        knownDevices: [KnownRemotePairingDevice],
        reachableDeviceIDs: Set<DeviceID>
    ) -> [RemotePairingAvailability] {
        knownDevices
            .map { device in
                RemotePairingAvailability(
                    deviceID: device.deviceID,
                    reachability: reachableDeviceIDs.contains(device.deviceID)
                        ? .reachable
                        : .unavailable
                )
            }
            .sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }
    }
}

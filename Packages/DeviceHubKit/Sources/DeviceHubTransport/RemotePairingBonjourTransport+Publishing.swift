import Foundation

extension RemotePairingBonjourTransport {
    func beginPairingAdvertisement(
        token: UUID,
        continuation:
        AsyncThrowingStream<
            PairingAdvertisementEvent,
            Error
        >.Continuation,
        listenerPort: UInt16,
        displayName: String,
        model: String
    ) async {
        if ignoredPublishingTerminations.remove(token) != nil {
            return
        }
        if let existingToken = publishingState?.token {
            await finishPairingAdvertisement(
                token: existingToken,
                error: nil
            )
        }
        publishingState = PublishingState(
            continuation: continuation,
            token: token
        )

        let identity: PairableHostIdentity
        do {
            identity = try await loadPairableHostIdentity()
        } catch {
            await finishPairingAdvertisement(
                token: token,
                error: .pairingRecordsUnavailable
            )
            return
        }
        guard publishingState?.token == token else {
            return
        }

        let advertisement: PairableHostAdvertisement
        do {
            advertisement = try PairableHostAdvertisement(
                identifier: identity.identifier,
                alternateIRK: identity.alternateIRK,
                displayName: displayName,
                model: model,
                listenerPort: Int(listenerPort)
            )
        } catch {
            await finishPairingAdvertisement(
                token: token,
                error: .invalidPairableHostConfiguration
            )
            return
        }

        do {
            try await publisher.start(advertisement) { [weak self] event in
                Task {
                    await self?.receivePublisherEvent(
                        event,
                        token: token
                    )
                }
            }
        } catch {
            await finishPairingAdvertisement(
                token: token,
                error: .publisherStartFailed(code: error.code)
            )
        }
    }

    private func receivePublisherEvent(
        _ event: BonjourPublisherEvent,
        token: UUID
    ) async {
        guard var state = publishingState, state.token == token else {
            return
        }
        switch event {
        case let .failed(failure):
            await finishPairingAdvertisement(
                token: token,
                error: .publisherFailed(code: failure.code)
            )

        case .published:
            guard !state.didPublish else {
                return
            }
            state.didPublish = true
            publishingState = state
            state.continuation.yield(.published)
        }
    }

    func cancelPairingAdvertisement(token: UUID) async {
        guard let state = publishingState, state.token == token else {
            if ignoredPublishingTerminations.remove(token) == nil {
                ignoredPublishingTerminations.insert(token)
            }
            return
        }
        publishingState = nil
        await publisher.stop()
    }

    func finishPairingAdvertisement(
        token: UUID,
        error: RemotePairingBonjourError?
    ) async {
        guard let state = publishingState, state.token == token else {
            return
        }
        publishingState = nil
        ignoredPublishingTerminations.insert(token)
        if let error {
            state.continuation.finish(throwing: error)
        } else {
            state.continuation.finish()
        }
        await publisher.stop()
    }
}

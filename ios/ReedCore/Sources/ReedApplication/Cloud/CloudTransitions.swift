import Foundation
import ReedDomain

extension CloudSyncEngine {
    public func preview() async throws -> CloudSummary { try await remote.summary() }

    /// The caller confirms this epoch after showing the two libraries' sizes.
    public func enable(expectedEpoch: UUID) async throws {
        try await exclusively {
            let state = try await self.local.state()
            guard state.mode == .local || state.mode == .revoked else { throw CloudError.invalidTransition }
            guard await self.network.allowsTransfer(wifiOnly: state.wifiOnly) else { throw CloudError.networkRestricted }
            let preview = try await self.remote.summary()
            guard preview.epoch == expectedEpoch else { throw CloudError.epochChanged }
            if state.mode == .local || state.epoch != expectedEpoch {
                try await self.media.verifyLocal(ids: self.local.referencedMedia())
            }
            try await self.participation.suspendLocalNotifications()
            try await self.local.begin(epoch: expectedEpoch)
            try await self.participation.prepareJoin()
            try await self.exchange()
        }
    }

    public func disable() async throws {
        try await exclusively {
            let state = try await self.local.state()
            if state.mode != .leaving {
                guard state.participates else { throw CloudError.invalidTransition }
                try await self.local.setMode(.disabling)
                try await self.exchange()
                try await self.requireSettled()
                try await self.media.verifyLocal(ids: self.local.referencedMedia())
                // This is the local boundary: later edits belong only to this phone.
                try await self.local.disconnect()
            }
            try await self.finishLeaving()
        }
    }

    /// Explicit confirmation after another device deleted the cloud or revoked this phone.
    public func keepLocalAfterRevocation() async throws {
        try await exclusively {
            guard try await self.local.state().mode == .revoked else { throw CloudError.invalidTransition }
            try await self.media.verifyLocal(ids: self.local.referencedMedia())
            try await self.local.abandonRevoked()
            try await self.finishLeaving()
        }
    }

    public func deleteCloud(expectedEpoch: UUID) async throws {
        try await exclusively {
            let state = try await self.local.state()
            guard state.participates else { throw CloudError.invalidTransition }
            try state.check(epoch: expectedEpoch)
            try await self.exchange()
            try await self.requireSettled()
            try await self.media.verifyLocal(ids: self.local.referencedMedia())
            _ = try await self.remote.reset(epoch: expectedEpoch)
            try await self.local.setMode(.revoked)
            try await self.local.abandonRevoked()
            try await self.finishLeaving()
        }
    }

    private func requireSettled() async throws {
        let summary = try await local.summary()
        guard summary.pending == 0, summary.conflicts == 0, summary.unapplied == 0,
              try await local.mediaToDownload().isEmpty else { throw CloudError.pendingChanges }
    }
    private func finishLeaving() async throws {
        try await participation.leave()
        try await local.finishDisconnect()
        try await participation.resumeLocalNotifications()
        emit(CloudProgress(.idle))
    }
}

import Foundation

public enum ReturnReason: String, Codable, Sendable {
    case firstReturn, longWait, preferred, coverage, explicit, noCandidates
    public var explanation: String {
        switch self {
        case .firstReturn: "Впервые возвращаем эту карточку"
        case .longWait: "Давно не возвращали"
        case .preferred: "Вы попросили возвращать такие карточки чаще"
        case .coverage: "Для охвата: одна из самых давно ожидающих карточек"
        case .explicit: "По вашему расписанию"
        case .noCandidates: "Нет карточки, подходящей по правилам и паузе 72 часа"
        }
    }
}
public struct ReturnReservation: Sendable {
    public let cardID: UUID
    public let date: Date
    public init(cardID: UUID, date: Date) { self.cardID = cardID; self.date = date }
}
public struct ReturnDecision: Codable, Equatable, Sendable {
    public let cardID: UUID?
    public let reason: ReturnReason
    public let waitingDays: Double?
    public let automaticOrdinal: Int?
    public init(cardID: UUID?, reason: ReturnReason, waitingDays: Double? = nil, automaticOrdinal: Int? = nil) {
        self.cardID = cardID; self.reason = reason; self.waitingDays = waitingDays; self.automaticOrdinal = automaticOrdinal
    }
}

public enum ReturnSelector {
    public static let cooldown: TimeInterval = 72 * 3600

    public struct PreparedCandidates: Sendable {
        fileprivate struct Entry: Sendable { let card: ReturnCandidate; let key: String }
        fileprivate let automatic: [Entry]
        fileprivate let explicit: [UUID: ReturnCandidate]
        public init(_ candidates: [ReturnCandidate], settings: ReturnSettings) {
            automatic = candidates.filter { ReturnPolicy.admits($0, settings: settings, explicit: false) }.map { Entry(card: $0, key: $0.id.uuidString) }
            explicit = Dictionary(candidates.filter { ReturnPolicy.admits($0, settings: settings, explicit: true) }.map { ($0.id,$0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Preparation is reusable across slots; every eligible card still participates.
    public static func select(slot: ReturnTimeSlot, candidates: [ReturnCandidate], settings: ReturnSettings,
                              reservations: [ReturnReservation], previousAutomaticOrdinal: Int,
                              historyEnabled: Bool, sourcesUsedToday: Set<UUID> = []) -> ReturnDecision {
        select(slot: slot, prepared: PreparedCandidates(candidates, settings: settings), settings: settings,
               reservations: reservations, previousAutomaticOrdinal: previousAutomaticOrdinal,
               historyEnabled: historyEnabled, sourcesUsedToday: sourcesUsedToday)
    }
    public static func select(slot: ReturnTimeSlot, prepared: PreparedCandidates, settings: ReturnSettings,
                              reservations: [ReturnReservation], previousAutomaticOrdinal: Int,
                              historyEnabled: Bool, sourcesUsedToday: Set<UUID> = []) -> ReturnDecision {
        if let id = slot.explicitCardID {
            return ReturnDecision(cardID: prepared.explicit[id]?.id, reason: prepared.explicit[id] == nil ? .noCandidates : .explicit)
        }
        let blocked = Set(reservations.filter { abs($0.date.timeIntervalSince(slot.date)) < cooldown }.map(\.cardID))
        var last: [UUID: Date] = [:]
        for reservation in reservations where reservation.date <= slot.date {
            last[reservation.cardID] = max(last[reservation.cardID] ?? .distantPast, reservation.date)
        }
        let ordinal = previousAutomaticOrdinal + 1, coverage = ordinal % 5 == 0
        let prefixHash = SlotPlanner.stableHash(slot.id)
        var winner: (entry: PreparedCandidates.Entry, wait: Double, score: Double, never: Bool, boosted: Bool, hash: UInt64?)?
        for entry in prepared.automatic {
            let card = entry.card
            guard !blocked.contains(card.id), card.deferredUntil.map({ slot.date >= $0 }) ?? true else { continue }
            let waiting = max(0, slot.date.timeIntervalSince(last[card.id] ?? card.createdAt) / 86400)
            let boosted = settings.boostEnabled && (settings.boostFolderID.map { card.folderID == $0 } ?? card.isFavorite)
            var score = max(0.1, waiting) * (boosted ? 2 : 1)
            if historyEnabled {
                let unseen = min(1, max(0, slot.date.timeIntervalSince(card.lastManualOpening ?? card.createdAt) / (90 * 86400)))
                score += unseen + Double(min(3, card.manualOpeningDays)) * 0.2
            }
            if let source = card.sourceID, !sourcesUsedToday.contains(source) { score += 0.25 }
            let never = last[card.id] == nil
            var wins = winner == nil, hash: UInt64?
            if let current = winner {
                if coverage && never != current.never { wins = never }
                else if coverage && waiting != current.wait { wins = waiting > current.wait }
                else if !coverage && score != current.score { wins = score > current.score }
                else {
                    let candidateHash = SlotPlanner.stableHash(entry.key, startingAt: prefixHash)
                    let currentHash = current.hash ?? SlotPlanner.stableHash(current.entry.key, startingAt: prefixHash)
                    winner?.hash = currentHash; hash = candidateHash
                    wins = candidateHash == currentHash ? entry.key < current.entry.key : candidateHash < currentHash
                }
            }
            if wins { winner = (entry,waiting,score,never,boosted,hash) }
        }
        guard let winner else { return ReturnDecision(cardID: nil, reason: .noCandidates) }
        let reason: ReturnReason = coverage ? .coverage : winner.boosted ? .preferred : winner.never ? .firstReturn : .longWait
        return ReturnDecision(cardID: winner.entry.card.id, reason: reason, waitingDays: winner.wait, automaticOrdinal: ordinal)
    }
}

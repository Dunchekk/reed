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

    /// All eligible metadata participates: no top-N shortlist or sampling window.
    public static func select(slot: ReturnTimeSlot, candidates: [ReturnCandidate], settings: ReturnSettings,
                              reservations: [ReturnReservation], previousAutomaticOrdinal: Int,
                              historyEnabled: Bool, sourcesUsedToday: Set<UUID> = []) -> ReturnDecision {
        if let id = slot.explicitCardID {
            guard let card = candidates.first(where: { $0.id == id }), ReturnPolicy.admits(card, settings: settings, explicit: true) else {
                return ReturnDecision(cardID: nil, reason: .noCandidates)
            }
            return ReturnDecision(cardID: id, reason: .explicit)
        }
        let blocked = Set(reservations.filter { abs($0.date.timeIntervalSince(slot.date)) < cooldown }.map(\.cardID))
        var last: [UUID: Date] = [:]
        for reservation in reservations where reservation.date <= slot.date {
            last[reservation.cardID] = max(last[reservation.cardID] ?? .distantPast, reservation.date)
        }
        let eligible = candidates.filter { !blocked.contains($0.id) && ReturnPolicy.admits($0, settings: settings, explicit: false) }
        guard !eligible.isEmpty else { return ReturnDecision(cardID: nil, reason: .noCandidates) }
        let ordinal = previousAutomaticOrdinal + 1, coverage = ordinal % 5 == 0
        func waiting(_ card: ReturnCandidate) -> Double { max(0, slot.date.timeIntervalSince(last[card.id] ?? card.createdAt) / 86400) }
        func boosted(_ card: ReturnCandidate) -> Bool {
            settings.boostEnabled && (settings.boostFolderID.map { card.folderID == $0 } ?? card.isFavorite)
        }
        func score(_ card: ReturnCandidate) -> Double {
            var result = max(0.1, waiting(card)) * (boosted(card) ? 2 : 1)
            if historyEnabled {
                let unseen = min(1, max(0, slot.date.timeIntervalSince(card.lastManualOpening ?? card.createdAt) / (90 * 86400)))
                result += unseen + Double(min(3, card.manualOpeningDays)) * 0.2
            }
            if let source = card.sourceID, !sourcesUsedToday.contains(source) { result += 0.25 }
            return result
        }
        let chosen = eligible.min { left, right in
            if coverage {
                if (last[left.id] == nil) != (last[right.id] == nil) { return last[left.id] == nil }
                if waiting(left) != waiting(right) { return waiting(left) > waiting(right) }
            } else if score(left) != score(right) { return score(left) > score(right) }
            let l = SlotPlanner.stableHash(slot.id + left.id.uuidString), r = SlotPlanner.stableHash(slot.id + right.id.uuidString)
            return l == r ? left.id.uuidString < right.id.uuidString : l < r
        }!
        let reason: ReturnReason = coverage ? .coverage : boosted(chosen) ? .preferred : last[chosen.id] == nil ? .firstReturn : .longWait
        return ReturnDecision(cardID: chosen.id, reason: reason, waitingDays: waiting(chosen), automaticOrdinal: ordinal)
    }
}

import Foundation

public enum MatchMode: String, Codable, CaseIterable, Sendable { case any, all }
public enum WordRule: String, CaseIterable, Codable, Sendable { case globalInclude, globalExclude, channelInclude, channelExclude }

public struct ReturnFilter: Codable, Equatable, Sendable {
    public var tags: Set<UUID> = []
    public var folders: Set<UUID> = []
    public var authors: Set<UUID> = []
    public var words = ""
    public var tagMode: MatchMode = .any
    public var authorMode: MatchMode = .any
    public var wordMode: MatchMode = .all
    public var createdAfter: Date?
    public var createdBefore: Date?
    public init() {}
    public var isEmpty: Bool { tags.isEmpty && folders.isEmpty && authors.isEmpty && TextNormalization.tokens(words).isEmpty && createdAfter == nil && createdBefore == nil }

    /// Nonempty groups intersect. An empty allow rule admits all; an empty deny rule denies none.
    public func matches(_ card: ReturnCandidate, wordRule: WordRule) -> Bool {
        func match(_ requested: Set<UUID>, _ actual: Set<UUID>, mode: MatchMode) -> Bool {
            requested.isEmpty || (mode == .any ? !requested.isDisjoint(with: actual) : requested.isSubset(of: actual))
        }
        return match(tags, card.tags, mode: tagMode)
            && (folders.isEmpty || card.folderID.map { folders.contains($0) } == true)
            && match(authors, card.authors, mode: authorMode)
            && (TextNormalization.tokens(words).isEmpty || card.wordMatches.contains(wordRule))
            && (createdAfter == nil || card.createdAt >= createdAfter!)
            && (createdBefore == nil || card.createdAt < createdBefore!)
    }
}

public struct ReturnSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var notificationsEnabled = false
    public var dailyLimit = 3
    public var weekdays: Set<Int> = Set(1...7)
    public var firstMinute = 570
    public var lastMinute = 1230
    public var minimumIntervalMinutes = 60
    public var jitterMinutes = 30
    public var globalInclude = ReturnFilter()
    public var globalExclude = ReturnFilter()
    public var channelInclude = ReturnFilter()
    public var channelExclude = ReturnFilter()
    public var boostEnabled = false
    public var boostFolderID: UUID?
    public init() {}

    public func validate() throws {
        guard (1...10).contains(dailyLimit), weekdays.isSubset(of: Set(1...7)),
              (0...1439).contains(firstMinute), (0...1439).contains(lastMinute), firstMinute <= lastMinute,
              (60...720).contains(minimumIntervalMinutes), (0...60).contains(jitterMinutes),
              (dailyLimit - 1) * minimumIntervalMinutes <= lastMinute - firstMinute else { throw ReturnError.invalidSchedule }
        for filter in [globalInclude, globalExclude, channelInclude, channelExclude] {
            guard filter.tags.count <= 100, filter.folders.count <= 100, filter.authors.count <= 100,
                  filter.words.utf8.count <= 8192, TextNormalization.tokens(filter.words).count <= 64 else { throw ReturnError.invalidFilter }
            if let after = filter.createdAfter, let before = filter.createdBefore, after >= before { throw ReturnError.invalidFilter }
        }
    }
}

/// Lightweight metadata, plus FTS match flags supplied by the storage adapter.
public struct ReturnCandidate: Sendable {
    public let id: UUID
    public var createdAt: Date
    public var sourceID: UUID?
    public var folderID: UUID?
    public var tags: Set<UUID> = []
    public var authors: Set<UUID> = []
    public var isFavorite = false
    public var isHidden = false
    public var isDeleted = false
    public var allowsReturns = true
    public var notificationsEnabled = true
    public var wordMatches: Set<WordRule> = []
    public var lastManualOpening: Date?
    public var manualOpeningDays = 0
    public init(id: UUID, createdAt: Date) { self.id = id; self.createdAt = createdAt }
}

public enum ReturnPolicy {
    public static func admits(_ card: ReturnCandidate, settings: ReturnSettings, explicit: Bool) -> Bool {
        guard settings.enabled, settings.notificationsEnabled, card.allowsReturns, card.notificationsEnabled,
              !card.isDeleted, !card.isHidden else { return false }
        if explicit { return true }
        return settings.globalInclude.matches(card, wordRule: .globalInclude)
            && settings.channelInclude.matches(card, wordRule: .channelInclude)
            && (settings.globalExclude.isEmpty || !settings.globalExclude.matches(card, wordRule: .globalExclude))
            && (settings.channelExclude.isEmpty || !settings.channelExclude.matches(card, wordRule: .channelExclude))
    }
}

public enum ReturnError: Error, Equatable, Sendable {
    case invalidSchedule, invalidFilter, conflictingExplicitTimes, tooManyExplicitTimes, stalePlan
}

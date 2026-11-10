import Foundation
import Testing
import ReedDomain

@Test func returnGatesIntersectRulesButExplicitTimeOverridesOnlyFilters() throws {
    let tag = UUID(), folder = UUID()
    var card = ReturnCandidate(id: UUID(), createdAt: Date())
    card.tags = [tag]; card.folderID = folder
    var settings = ReturnSettings(); settings.enabled = true; settings.notificationsEnabled = true
    settings.globalInclude.tags = [tag]; settings.channelInclude.folders = [folder]
    #expect(ReturnPolicy.admits(card, settings: settings, explicit: false))
    settings.globalExclude.tags = [tag]
    #expect(!ReturnPolicy.admits(card, settings: settings, explicit: false))
    #expect(ReturnPolicy.admits(card, settings: settings, explicit: true))
    for disabled in 0..<4 {
        var gated = card; var rule = settings
        if disabled == 0 { gated.allowsReturns = false }
        if disabled == 1 { gated.notificationsEnabled = false }
        if disabled == 2 { rule.enabled = false }
        if disabled == 3 { rule.notificationsEnabled = false }
        #expect(!ReturnPolicy.admits(gated, settings: rule, explicit: true))
    }
    card.isHidden = true
    #expect(!ReturnPolicy.admits(card, settings: settings, explicit: false))
}

@Test func returnFiltersMatchPrefixFlagsAndAnyAllMetadata() {
    let first = UUID(), second = UUID()
    var card = ReturnCandidate(id: UUID(), createdAt: Date()); card.tags = [first]
    var filter = ReturnFilter(); filter.tags = [first, second]
    #expect(filter.matches(card, wordRule: .globalInclude))
    filter.tagMode = .all
    #expect(!filter.matches(card, wordRule: .globalInclude))
    card.tags.insert(second); filter.words = "ёлка"
    #expect(!filter.matches(card, wordRule: .globalInclude))
    card.wordMatches = [.globalInclude]
    #expect(filter.matches(card, wordRule: .globalInclude))
}

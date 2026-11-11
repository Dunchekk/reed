import Foundation
import Testing
import ReedDomain

@Test func cloudCardReferencesSharedMetadataInsteadOfCopyingIt() throws {
    let card = Card(text:"Отрывок",source:Source(title:"Книга",authors:[Author(name:"Автор")]),tags:[Tag(name:"Тег")],attachmentIDs:[UUID(),UUID()])
    let document = CloudCard(card), payload = try CloudValue.encode(document)
    let encoded = String(decoding:try CloudCoding.encoder().encode(payload),as:UTF8.self)
    #expect(!encoded.contains("Книга")); #expect(!encoded.contains("Автор")); #expect(!encoded.contains("Тег"))
    #expect(try payload.decode(CloudCard.self).attachmentIDs == card.attachmentIDs)
    #expect(try payload.decode(CloudCard.self).sourceID == card.source?.id)
}
@Test func cloudEpochAndTransitionAreExplicit() throws {
    var state = CloudState(); let epoch = UUID()
    try state.begin(epoch:epoch); #expect(state.mode == .enabling)
    #expect(throws:CloudError.invalidTransition) { try state.begin(epoch:epoch) }
    #expect(throws:CloudError.epochChanged) { try state.check(epoch:UUID()) }
}
@Test func cloudTombstoneRoundTripsAsAnExplicitNull() throws {
    let record = CloudRecord(key:CloudKey(.card,UUID()),version:2,sequence:3,payload:.null)
    let data = try CloudCoding.encoder().encode(record)
    #expect(String(decoding:data,as:UTF8.self).contains("\"payload\":null"))
    #expect(try CloudCoding.decoder().decode(CloudRecord.self,from:data) == record)
}

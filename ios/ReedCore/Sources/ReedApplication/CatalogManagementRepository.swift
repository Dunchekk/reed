import ReedDomain

public protocol CatalogManagementRepository: Sendable {
    func entries(kind: CatalogKind) async throws -> CatalogSnapshot
    func update(kind: CatalogKind, mutation: CatalogMutation, expectedRevision: Int64) async throws
}

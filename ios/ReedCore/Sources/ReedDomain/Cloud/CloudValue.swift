import Foundation

/// JSON at the synchronization boundary; typed projections validate each record kind.
public enum CloudValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([CloudValue]), object([String: CloudValue])
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([CloudValue].self) { self = .array(result) }
        else { self = .object(try value.decode([String: CloudValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .string(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .object(let result): try value.encode(result)
        }
    }
    public static func encode<T: Encodable>(_ value: T) throws -> CloudValue {
        try CloudCoding.decoder().decode(CloudValue.self, from: CloudCoding.encoder().encode(value)).normalized()
    }
    /// Normalize identifiers and set-valued arrays only; user text is never case-folded.
    public func normalized(field: String? = nil) -> CloudValue {
        let identifiers: Set<String> = ["id", "sourceID", "folderID", "cardID", "explicitCardID", "boostFolderID"]
        let arrays: Set<String> = ["tagIDs", "attachmentIDs", "authorIDs", "tags", "authors", "folders"]
        let unordered: Set<String> = ["tagIDs", "tags", "authors", "folders", "weekdays", "minutes"]
        switch self {
        case .string(let value) where field.map(identifiers.contains) == true || field.map(arrays.contains) == true:
            return UUID(uuidString: value).map { .string($0.uuidString.lowercased()) } ?? self
        case .array(let values):
            let normalized = values.map { $0.normalized(field: field) }
            if field.map(unordered.contains) == true {
                return .array(normalized.sorted { left, right in
                    switch (left, right) {
                    case let (.string(a), .string(b)): a < b
                    case let (.number(a), .number(b)): a < b
                    default: false
                    }
                })
            }
            return .array(normalized)
        case .object(let values): return .object(Dictionary(uniqueKeysWithValues: values.map { key, value in (key, value.normalized(field: key)) }))
        default: return self
        }
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try CloudCoding.decoder().decode(type, from: CloudCoding.encoder().encode(self))
    }
}
public enum CloudCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer(); try value.encode(format.string(from: date))
        }
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer(), value = try container.decode(String.self)
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: value) { return date }
            format.formatOptions = [.withInternetDateTime]
            guard let date = format.date(from: value) else { throw CloudError.invalidRecord }
            return date
        }
        return decoder
    }
}
public enum CloudError: Error, Equatable, Sendable {
    case invalidRecord, epochChanged, conflict, operationReused, missingMedia, corruptedMedia
    case deviceRevoked, networkRestricted
    case busy, pendingChanges, unavailable, wrongAccount, invalidTransition, quotaExceeded
}

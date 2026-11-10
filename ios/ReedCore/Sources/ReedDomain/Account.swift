import Foundation

public struct Account: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let phone: PhoneNumber

    public init(id: UUID, phone: PhoneNumber) {
        self.id = id
        self.phone = phone
    }
}

/// A normalized +7 phone number. Delivery coverage is a provider concern.
public struct PhoneNumber: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set("0123456789+()- ")
        guard trimmed.allSatisfy({ allowed.contains($0) }),
              !trimmed.dropFirst().contains("+") else {
            throw ValidationError.invalidPhone
        }
        let digits = trimmed.filter { $0 >= "0" && $0 <= "9" }
        guard digits.count == 11, digits.first == "7" || digits.first == "8",
              !trimmed.hasPrefix("+") || digits.first == "7" else {
            throw ValidationError.invalidPhone
        }
        value = "+7" + digits.dropFirst()
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum ValidationError: Error, Equatable, Sendable {
    case invalidPhone
}

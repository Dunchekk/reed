import ReedDomain

/// Expiring server credentials must not revoke an already confirmed local account.
public enum SessionAccess: Equatable, Sendable {
    case signedOut
    case local(Account)
    case authenticated(Account)

    public var localAccount: Account? {
        switch self {
        case .signedOut: nil
        case .local(let account), .authenticated(let account): account
        }
    }

    public var allowsServerOperations: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

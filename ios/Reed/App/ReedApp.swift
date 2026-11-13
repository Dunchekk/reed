import SwiftUI
import ReedApplication

@main
struct ReedApp: App {
    @UIApplicationDelegateAdaptor(ReedAppDelegate.self) private var appDelegate
    @State private var authentication: AuthenticationModel

    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "ReedAPIBaseURL") as? String ?? ""
        var baseURL: URL?
        if let url = URL(string: configured), url.scheme == "https", url.host != nil {
            baseURL = url
        }
        #if DEBUG
        if baseURL == nil { baseURL = URL(string: "http://127.0.0.1:3000") }
        #endif
        var store: any SessionStore = KeychainSessionStore()
        #if DEBUG
        if UITestBootstrap.enabled { store = UITestSessionStore(); baseURL = nil }
        #endif
        let client = baseURL.map { HTTPAuthenticationClient(baseURL: $0) }
        let tokens = client.map { SessionTokenProvider(store: store, client: $0) }
        if let baseURL, let tokens { LibrarySessionController.shared.configureCloud(.init(baseURL: baseURL, tokens: tokens)) }
        else { LibrarySessionController.shared.configureCloud(nil) }
        _authentication = State(initialValue: AuthenticationModel(client: client, store: store, tokens: tokens))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if !authentication.isRestored {
                    VStack(spacing: 16) {
                        Text(authentication.errorMessage ?? "Открываем Reed…")
                        if authentication.errorMessage != nil { Button("Повторить", action: authentication.restore) }
                    }.task { authentication.restore() }
                } else if let session = authentication.session, session.deletionProgress != nil {
                    AccountDeletionRecoveryView(authentication: authentication, account: session.account)
                } else if let account = authentication.account {
                    LibraryHostView(account: account, authentication: authentication).id(account.id)
                        .task { await authentication.refreshIfNeeded() }
                } else {
                    SignInView(model: authentication)
                }
            }
                .preferredColorScheme(.dark)
                .tint(ReedTheme.foreground)
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }
}

import SwiftUI
import ReedDomain

enum ReedTheme {
    static let background = Color("main-backround-color")
    static let foreground = Color("text-main")
    static let secondary = Color("text-second-color")
    static let tertiary = Color("text-third-color")
    static let surface = Color("third-style-color")
    static let raised = Color("second-style-color")
    static let radius: CGFloat = 4
    static let border: CGFloat = 0.8
    static let inset: CGFloat = 16
}

enum ReedTextRole {
    case display, screen, cardTitle, section, body, caption, metadata
    var size: CGFloat {
        switch self {
        case .display: 40
        case .screen: 32
        case .cardTitle: 20
        case .section: 18
        case .body: 16
        case .caption: 14
        case .metadata: 12
        }
    }
    var relativeStyle: Font.TextStyle {
        switch self {
        case .display, .screen: .largeTitle
        case .cardTitle, .section: .title3
        case .body: .body
        case .caption: .subheadline
        case .metadata: .caption
        }
    }
}

private struct ReedFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    init(_ role: ReedTextRole) { _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.relativeStyle) }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: .regular)) }
}

extension View {
    func reedFont(_ role: ReedTextRole) -> some View { modifier(ReedFont(role)) }
    func reedField() -> some View {
        padding(12).background(ReedTheme.background)
            .overlay(RoundedRectangle(cornerRadius: ReedTheme.radius).stroke(ReedTheme.foreground, lineWidth: ReedTheme.border))
    }
}

struct ReedPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.reedFont(.caption).frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(ReedTheme.background)
            .background(ReedTheme.foreground, in: RoundedRectangle(cornerRadius: ReedTheme.radius))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

func libraryErrorMessage(_ error: any Error) -> String {
    switch error as? LibraryError {
    case .emptyText: "Добавьте текст карточки."
    case .emptyMetadata: "Название источника, папки или тега не может быть пустым."
    case .conflict: "Карточка уже изменилась. Откройте её заново, чтобы сохранить правки."
    case .notFound: "Карточка больше недоступна."
    case .invalidQuery: "Проверьте период и поисковый запрос."
    default: "Не удалось выполнить действие. Попробуйте ещё раз."
    }
}

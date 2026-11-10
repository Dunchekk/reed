import Foundation

enum ReedDatePresentation {
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "ru_RU")))
    }
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.twoDigits).year().locale(Locale(identifier: "ru_RU")))
    }
}

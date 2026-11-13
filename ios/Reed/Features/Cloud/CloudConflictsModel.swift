import Foundation
import Observation
import ReedDomain
import ReedApplication

@MainActor @Observable
final class CloudConflictsModel {
    private(set) var conflicts: [CloudConflict] = []
    private(set) var catalog = LibraryCatalog(sources: [], authors: [], tags: [], folders: [])
    private(set) var cardTitles: [UUID:String] = [:]
    private(set) var working = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let repository: any CloudRepository
    @ObservationIgnored private let library: any LibraryRepository
    @ObservationIgnored private let engine: CloudSyncEngine?
    init(repository: any CloudRepository, library: any LibraryRepository, engine: CloudSyncEngine?) {
        self.repository = repository; self.library = library; self.engine = engine
    }
    func load() async {
        do {
            conflicts = try await repository.conflicts(); catalog = try await library.catalog()
            var ids = Set<UUID>()
            for conflict in conflicts {
                for value in [conflict.local, conflict.remote.payload] where value != .null {
                    switch conflict.remote.kind {
                    case .cardReturn: if let rule = try? value.decode(CardReturnSettings.self) { ids.insert(rule.cardID) }
                    case .opening: if let opening = try? value.decode(CloudOpening.self) { ids.insert(opening.cardID) }
                    case .returnHistory: if let event = try? value.decode(CloudReturnHistory.self), let id = event.decision.cardID { ids.insert(id) }
                    default: break
                    }
                }
            }
            var titles: [UUID:String] = [:]
            for id in ids { if let card = try await library.card(id: id) { titles[id] = card.displayTitle } }
            cardTitles = titles
        }
        catch { errorMessage = cloudErrorMessage(error) }
    }
    func resolve(id: UUID, choice: CloudResolution) async -> Bool {
        guard !working, let engine else { return false }
        working = true; errorMessage = nil
        defer { working = false }
        do { try await engine.resolve(id: id, choice: choice) }
        catch { errorMessage = cloudErrorMessage(error) }
        await load()
        return !conflicts.contains { $0.id == id }
    }
}

/// Readable comparison only. These descriptions never determine the merge result.
struct CloudVersionDescription {
    var title = ""
    var text = ""
    var fields: [(String,String)] = []
    var photos: [UUID] = []
    init(kind: CloudRecordKind, value: CloudValue, catalog: LibraryCatalog, cardTitles: [UUID:String] = [:]) {
        guard value != .null else { title = "Запись удалена"; text = kind == .card ? "Постоянное удаление. Изменения карточки можно сохранить отдельной копией." : "Постоянное удаление этой записи."; return }
        func yes(_ value: Bool) -> String { value ? "Да" : "Нет" }
        func minute(_ value: Int) -> String { String(format: "%02d:%02d",value/60,value%60) }
        func weekdays(_ values: Set<Int>) -> String {
            let names = [1:"Вс",2:"Пн",3:"Вт",4:"Ср",5:"Чт",6:"Пт",7:"Сб"]
            return [2,3,4,5,6,7,1].filter(values.contains).compactMap { names[$0] }.joined(separator: ", ")
        }
        func filter(_ value: ReturnFilter) -> String {
            var parts: [String] = []
            if !value.tags.isEmpty { parts.append("Теги (\(value.tagMode == .any ? "любой" : "все")): " + value.tags.map { id in catalog.tags.first { $0.id == id }?.name ?? "Недоступный тег" }.sorted().joined(separator: ", ")) }
            if !value.folders.isEmpty { parts.append("Папки: " + value.folders.map { id in catalog.folders.first { $0.id == id }?.name ?? "Недоступная папка" }.sorted().joined(separator: ", ")) }
            if !value.authors.isEmpty { parts.append("Авторы (\(value.authorMode == .any ? "любой" : "все")): " + value.authors.map { id in catalog.authors.first { $0.id == id }?.name ?? "Недоступный автор" }.sorted().joined(separator: ", ")) }
            if !value.words.isEmpty { parts.append("Слова (\(value.wordMode == .any ? "любое" : "все")): \(value.words)") }
            if let date = value.createdAfter { parts.append("После: \(ReedDatePresentation.dateTime(date))") }
            if let date = value.createdBefore { parts.append("До: \(ReedDatePresentation.dateTime(date))") }
            return parts.isEmpty ? "Не заданы" : parts.joined(separator: "\n")
        }
        do {
            switch kind {
            case .card:
                let card = try value.decode(CloudCard.self)
                title = card.title.isEmpty ? "Карточка" : card.title; text = card.text; photos = card.attachmentIDs
                fields = [("Комментарий",card.comment), ("Страница",card.page),
                    ("Источник",card.sourceID.map { id in catalog.sources.first { $0.id == id }?.displayName ?? "Источник пока недоступен" } ?? "Не выбран"),
                    ("Папка",card.folderID.map { id in catalog.folders.first { $0.id == id }?.name ?? "Папка пока недоступна" } ?? "Не выбрана"),
                    ("Теги",card.tagIDs.map { id in catalog.tags.first { $0.id == id }?.name ?? "Недоступный тег" }.joined(separator: ", ")),
                    ("Избранное",yes(card.isFavorite)), ("Скрыта",yes(card.isHidden)), ("Возвращения",yes(card.allowsReturns)),
                    ("В корзине",card.deletedAt.map(ReedDatePresentation.dateTime) ?? "Нет"),
                    ("Создана",ReedDatePresentation.dateTime(card.createdAt)), ("Изменена",ReedDatePresentation.dateTime(card.updatedAt))]
            case .author, .tag, .folder: title = try value.decode(Author.self).name
            case .source:
                let source = try value.decode(CloudSource.self); title = source.title
                fields = [("Авторы",source.authorIDs.map { id in catalog.authors.first { $0.id == id }?.name ?? "Недоступный автор" }.joined(separator: ", ")), ("Ссылка",source.url ?? "")]
            case .historyPreference: title = "История открытий"; fields = [("Сбор и использование",yes(try value.decode(CloudHistoryPreference.self).enabled))]
            case .opening:
                let event = try value.decode(CloudOpening.self); title = "Открытие карточки"
                fields = [("Карточка",cardTitles[event.cardID] ?? "Удалена или ещё не загружена"), ("Время",ReedDatePresentation.dateTime(event.date)), ("Переход",event.origin == .manual ? "Из приложения" : "Из уведомления")]
            case .cardReturn:
                let settings = try value.decode(CardReturnSettings.self); title = "Расписание карточки"
                fields = [("Карточка",cardTitles[settings.cardID] ?? "Удалена или ещё не загружена"), ("Уведомления",yes(settings.notificationsEnabled)), ("Время",settings.minutes.sorted().map(minute).joined(separator: ", ")),
                    ("Дни",weekdays(settings.weekdays)), ("Отложена до",settings.deferredUntil.map(ReedDatePresentation.dateTime) ?? "Не отложена")]
            case .returnSettings:
                let settings = try value.decode(ReturnSettings.self); title = "Правила возвращений"
                fields = [("Возвращения",yes(settings.enabled)), ("Уведомления",yes(settings.notificationsEnabled)), ("В день",String(settings.dailyLimit)),
                    ("Дни",weekdays(settings.weekdays)), ("Окно времени","\(minute(settings.firstMinute))–\(minute(settings.lastMinute))"),
                    ("Минимальный интервал","\(settings.minimumIntervalMinutes) мин"), ("Разброс времени","\(settings.jitterMinutes) мин"),
                    ("Общие разрешения",filter(settings.globalInclude)), ("Общие исключения",filter(settings.globalExclude)),
                    ("Разрешения уведомлений",filter(settings.channelInclude)), ("Исключения уведомлений",filter(settings.channelExclude)),
                    ("Усиление папки",yes(settings.boostEnabled)), ("Выбранная папка",settings.boostFolderID.map { id in catalog.folders.first { $0.id == id }?.name ?? "Недоступная папка" } ?? "Не выбрана")]
            case .returnHistory:
                let event = try value.decode(CloudReturnHistory.self); title = "Сохранённое возвращение"
                fields = [("Карточка",event.decision.cardID.map { cardTitles[$0] ?? "Удалена или ещё не загружена" } ?? "Нет подходящей карточки"), ("Время",ReedDatePresentation.dateTime(event.slot.date)), ("Причина",event.decision.reason.explanation)]
            }
            fields = fields.filter { !$0.1.isEmpty }
        } catch { title = "Не удалось прочитать версию"; text = "Обновите экран перед выбором." }
    }
}

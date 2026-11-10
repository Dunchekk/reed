import SwiftUI
import ReedDomain

struct ReturnFilterView: View {
    @Binding var filter: ReturnFilter
    let catalog: LibraryCatalog
    let title: String
    var body: some View {
        Form {
            Section {
                Text("Непустые группы пересекаются. В пустом списке включений разрешено всё; пустой список исключений ничего не исключает.").reedFont(.caption)
            }
            Section("Теги") {
                modePicker("Совпадение тегов", mode: $filter.tagMode)
                ForEach(catalog.tags) { tag in Toggle(tag.name, isOn: membership(tag.id, in: $filter.tags)) }
            }
            Section("Папки: любая из выбранных") {
                ForEach(catalog.folders) { folder in Toggle(folder.name, isOn: membership(folder.id, in: $filter.folders)) }
            }
            Section("Авторы") {
                modePicker("Совпадение авторов", mode: $filter.authorMode)
                ForEach(catalog.authors) { author in Toggle(author.name, isOn: membership(author.id, in: $filter.authors)) }
            }
            Section("Слова: начало слова, е = ё") {
                TextField("Слова через пробел", text: $filter.words, axis: .vertical).accessibilityIdentifier("return.filter.words")
                modePicker("Совпадение слов", mode: $filter.wordMode)
            }
            Section("Когда добавлена карточка") {
                Toggle("Начало периода", isOn: Binding(get: { filter.createdAfter != nil }, set: { filter.createdAfter = $0 ? Calendar.current.startOfDay(for: Date()) : nil }))
                if filter.createdAfter != nil {
                    DatePicker("Начиная с", selection: Binding(get: { filter.createdAfter ?? Date() }, set: { filter.createdAfter = Calendar.current.startOfDay(for: $0) }), displayedComponents: .date)
                }
                Toggle("Конец периода", isOn: Binding(get: { filter.createdBefore != nil }, set: { filter.createdBefore = $0 ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) : nil }))
                if filter.createdBefore != nil {
                    DatePicker("По включительно", selection: Binding(get: { (filter.createdBefore ?? Date()).addingTimeInterval(-1) }, set: { filter.createdBefore = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) }), displayedComponents: .date)
                }
            }
            Button("Очистить этот список", role: .destructive) { filter = ReturnFilter() }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private func modePicker(_ title: String, mode: Binding<MatchMode>) -> some View {
        Picker(title, selection: mode) { Text("Хотя бы один").tag(MatchMode.any); Text("Все").tag(MatchMode.all) }
    }
    private func membership(_ id: UUID, in set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { value in if value { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let days = [(2,"Понедельник"),(3,"Вторник"),(4,"Среда"),(5,"Четверг"),(6,"Пятница"),(7,"Суббота"),(1,"Воскресенье")]
    var body: some View {
        ForEach(days, id: \.0) { value, title in
            Toggle(title, isOn: Binding(get: { selection.contains(value) }, set: { enabled in if enabled { selection.insert(value) } else { selection.remove(value) } }))
        }
    }
}

func minuteBinding(_ value: Binding<Int>) -> Binding<Date> {
    Binding(get: { Calendar.current.date(bySettingHour: value.wrappedValue / 60, minute: value.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
        set: { value.wrappedValue = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) })
}

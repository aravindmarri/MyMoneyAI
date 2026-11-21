import SwiftUI
import SwiftData

struct CategoriesView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    @State private var editing: CategoryEditorRoute?
    @State private var deleting: SpendingCategory?
    @State private var reassigning: SpendingCategory?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach([CategoryKind.expense, .income]) { kind in
                Section(kind.displayName) {
                    ForEach(categories.filter { $0.kind == kind }) { c in
                        Button { editing = .edit(c) } label: {
                            Label {
                                Text(c.name).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: c.symbol).foregroundStyle(Theme.color(c.colorIdentifier))
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { requestDelete(c) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .brandScreen()
        .navigationTitle("Categories")
        .toolbar {
            Menu {
                Button("Expense Category") { editing = .new(.expense) }
                Button("Income Category") { editing = .new(.income) }
            } label: { Image(systemName: "plus") }
            .accessibilityLabel("Add category")
        }
        .sheet(item: $editing) { CategoryEditorView(route: $0) }
        .sheet(item: $reassigning) { ReassignCategoryView(category: $0) }
        .confirmationDialog("Delete Category?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { c in
            Button("Delete \(c.name)", role: .destructive) {
                do { try app.referenceData.deleteCategory(id: c.id, reassignment: nil) } catch { errorMessage = error.localizedDescription }
            }
        } message: { _ in Text("No transactions use this category.") }
        .alert("Can't Delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func requestDelete(_ c: SpendingCategory) {
        do {
            if try app.referenceData.usage(ofCategory: c.id).isUnused { deleting = c } else { reassigning = c }
        } catch { errorMessage = error.localizedDescription }
    }
}

enum CategoryEditorRoute: Identifiable {
    case new(CategoryKind)
    case edit(SpendingCategory)
    var id: String {
        switch self {
        case .new(let k): "new-\(k.rawValue)"
        case .edit(let c): c.id.uuidString
        }
    }
}

struct CategoryEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let route: CategoryEditorRoute
    @State private var name: String
    @State private var symbol: String
    @State private var color: String
    @State private var errorMessage: String?

    static let symbols = ["tag.fill", "cart.fill", "fork.knife", "cup.and.saucer.fill", "car.fill", "bus.fill", "fuelpump.fill",
                          "house.fill", "bolt.fill", "drop.fill", "wifi", "phone.fill", "bag.fill", "gift.fill", "tshirt.fill",
                          "cross.case.fill", "pills.fill", "heart.fill", "film.fill", "gamecontroller.fill", "music.note",
                          "book.fill", "graduationcap.fill", "airplane", "bed.double.fill", "pawprint.fill", "figure.run",
                          "wrench.and.screwdriver.fill", "briefcase.fill", "banknote.fill", "percent", "building.columns.fill"]
    static let colors = ["blue", "green", "orange", "red", "purple", "pink", "teal", "indigo", "yellow", "mint", "cyan", "brown", "gray"]

    init(route: CategoryEditorRoute) {
        self.route = route
        switch route {
        case .new:
            _name = State(initialValue: ""); _symbol = State(initialValue: "tag.fill"); _color = State(initialValue: "blue")
        case .edit(let c):
            _name = State(initialValue: c.name); _symbol = State(initialValue: c.symbol); _color = State(initialValue: c.colorIdentifier)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: symbol).foregroundStyle(.white).frame(width: 40, height: 40)
                            .background(Theme.color(color), in: Circle())
                        TextField("Name", text: $name)
                    }
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.symbols, id: \.self) { s in
                            Button { symbol = s } label: {
                                Image(systemName: s).frame(width: 36, height: 36)
                                    .background(symbol == s ? Theme.color(color).opacity(0.25) : .clear, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(s)
                            .accessibilityAddTraits(symbol == s ? .isSelected : [])
                        }
                    }
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                        ForEach(Self.colors, id: \.self) { c in
                            Button { color = c } label: {
                                Circle().fill(Theme.color(c)).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(.primary, lineWidth: color == c ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c)
                            .accessibilityAddTraits(color == c ? .isSelected : [])
                        }
                    }
                }
            }
            .brandScreen()
            .navigationTitle(isNew ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Can't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var isNew: Bool { if case .new = route { true } else { false } }

    private func save() {
        do {
            switch route {
            case .new(let kind): try app.referenceData.createCategory(name: name, symbol: symbol, colorIdentifier: color, kind: kind)
            case .edit(let c): try app.referenceData.updateCategory(c, name: name, symbol: symbol, colorIdentifier: color)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

/// Shown when deleting a category that is in use. The user must choose where its transactions go.
struct ReassignCategoryView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.displayOrder) private var categories: [SpendingCategory]
    let category: SpendingCategory
    @State private var target: UUID?
    @State private var usage = CategoryUsage()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("“\(category.name)” is used by \(usage.transactions) transaction(s)\(usage.bills > 0 ? " and \(usage.bills) bill(s)" : ""). Choose where to move them.")
                    if usage.budgets > 0 {
                        Text("\(usage.budgets) budget(s) for this category will be turned off.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Move To") {
                    Picker("Move to", selection: $target) {
                        Text("Leave uncategorized").tag(UUID?.none)
                        ForEach(categories.filter { $0.kind == category.kind && $0.id != category.id }) { c in
                            Label(c.name, systemImage: c.symbol).tag(Optional(c.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Button("Move and Delete Category", role: .destructive, action: confirm)
                }
            }
            .brandScreen()
            .navigationTitle("Delete Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { usage = (try? app.referenceData.usage(ofCategory: category.id)) ?? CategoryUsage() }
            .alert("Can't Delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func confirm() {
        do {
            try app.referenceData.deleteCategory(id: category.id, reassignment: target.map { .moveTo($0) } ?? .leaveUncategorized)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

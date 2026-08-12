import SwiftUI

/// Where a category-transactions push originated on the Budget tab (GH #56):
/// the category name shows all time, the "Spent" caption shows one month.
struct CategoryTransactionsDestination: Hashable {
    let categoryId: String
    let categoryName: String
    /// "yyyy-MM" to narrow to one month; nil means all time.
    let month: String?
}

/// Every transaction counting toward one category's spend, pushed from the
/// Budget tab (GH #56), above it the category's note (GH #131). The row set
/// mirrors the budget month's spent query (see
/// BudgetDatabase.fetchCategoryTransactions), so a month-scoped list sums to
/// the "Spent" figure the user tapped.
struct CategoryTransactionsView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let destination: CategoryTransactionsDestination

    @State private var transactions: [Transaction] = []
    @State private var searchText = ""
    @State private var loaded = false
    @State private var editingTransaction: Transaction?
    /// Starts `.unsupported` so the section stays hidden until the read
    /// confirms this file can store notes (GH #131).
    @State private var note: EntityNote = .unsupported
    @State private var editingNote = false

    private var scopeTitle: String {
        destination.month.map { MonthPicker.title(for: $0) } ?? "All Time"
    }

    private var filteredTransactions: [Transaction] {
        if searchText.isEmpty {
            return transactions
        }
        let matcher = TransactionSearchMatcher(searchText)
        return transactions.filter { matcher.matches($0) }
    }

    /// The category's note. Hidden while searching — a search is about finding
    /// transactions, not reading guidance — and on files with no `notes` table,
    /// where an edit could never save.
    private var noteSection: some View {
        Section("Note") {
            if note.isEmpty {
                Button {
                    editingNote = true
                } label: {
                    // Tinted: an empty note row is an invitation to act, where
                    // an existing note is content to read.
                    Label("Add Note", systemImage: "note.text.badge.plus")
                        .foregroundStyle(Color.accentColor)
                }
                // Plain: a tinted List button would tint the label twice over.
                .buttonStyle(.plain)
                .accessibilityIdentifier("categoryNoteRow")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    // Attributed so markdown links and bare URLs in the note
                    // are tappable (GH #190). That's also why this row is a
                    // tap gesture rather than the Button the empty state uses:
                    // a Button label swallows link taps, where links inside a
                    // gesture-carrying row take precedence over the gesture.
                    Text(NoteLinkText.attributed(note.text))
                        .multilineTextAlignment(.leading)
                        // Multi-line notes are the point — let the row grow
                        // instead of truncating the guidance to one line.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { editingNote = true }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("categoryNoteRow")
            }
        }
    }

    /// Kept as a row inside the List rather than replacing the whole view, so a
    /// category with no transactions yet still shows (and can add) its note.
    private var emptyTransactionsRow: some View {
        ContentUnavailableView(
            "No Transactions",
            systemImage: "list.bullet.rectangle",
            description: Text("Nothing in \(destination.categoryName) for \(scopeTitle.lowercased() == "all time" ? "any month" : scopeTitle)")
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var transactionsSection: some View {
        Section {
            if !transactions.isEmpty && filteredTransactions.isEmpty {
                Text("No matching transactions")
                    .foregroundStyle(.secondary)
            }
            ForEach(filteredTransactions) { transaction in
                Group {
                    // Split children only display at full opacity, without
                    // tap/swipe: the edit form has no split support, and
                    // deleting one leg would break the parent's amount.
                    if transaction.parentId == nil {
                        Button {
                            editingTransaction = transaction
                        } label: {
                            TransactionRow(transaction: transaction, onToggleCleared: {
                                Task {
                                    await budgetStore.toggleCleared(transaction)
                                    await reload()
                                }
                            })
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        TransactionRow(transaction: transaction)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if transaction.parentId == nil {
                        Button(role: .destructive) {
                            Task {
                                await budgetStore.deleteTransaction(transaction)
                                await reload()
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingTransaction = transaction
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.yellow)
                    }
                }
            }
        } header: {
            HStack {
                Text(scopeTitle)
                Spacer()
                // Sums the filtered rows so the total matches what's on screen
                // while searching.
                Text("Total \(budgetStore.displayBalance(filteredTransactions.reduce(0) { $0 + $1.amount }))")
            }
        }
    }

    var body: some View {
        List {
            if note.supported && searchText.isEmpty {
                noteSection
            }
            if transactions.isEmpty && loaded {
                emptyTransactionsRow
            } else {
                transactionsSection
            }
        }
        .readableWidth()
        .navigationTitle(destination.categoryName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions")
        .task { await reload() }
        .refreshable {
            await budgetStore.sync()
            await reload()
        }
        .sheet(item: $editingTransaction, onDismiss: {
            Task { await reload() }
        }) { transaction in
            AddTransactionView(editing: transaction)
                .environmentObject(budgetStore)
        }
        .sheet(isPresented: $editingNote, onDismiss: {
            Task { await reloadNote() }
        }) {
            NoteEditorView(
                noteId: destination.categoryId,
                title: destination.categoryName,
                note: note.text
            )
            .environmentObject(budgetStore)
        }
    }

    private func reload() async {
        transactions = await budgetStore.fetchCategoryTransactions(
            categoryId: destination.categoryId,
            month: destination.month
        )
        await reloadNote()
        loaded = true
    }

    private func reloadNote() async {
        note = await budgetStore.fetchNote(id: destination.categoryId)
    }
}

#Preview {
    NavigationStack {
        CategoryTransactionsView(
            destination: CategoryTransactionsDestination(
                categoryId: "cat-1",
                categoryName: "Food",
                month: nil
            )
        )
        .environmentObject(BudgetStore.previewInstance())
    }
}

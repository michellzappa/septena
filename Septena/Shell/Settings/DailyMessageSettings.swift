import SwiftUI

// Settings detail screens for the optional daily-message dashboard footer:
//   • DailyMessageQuotesEditor — add / remove the user's own quote lines.
//   • ReadwiseConnectView      — token entry + highlight sync.
// Both are pushed from the "Daily message" section of HomeSettingsPane and
// read the shared QuoteStore / ReadwiseProvider singletons directly.

// MARK: - User quotes

struct DailyMessageQuotesEditor: View {
  @State private var quotes: [QuoteEntity] = []
  @State private var newText = ""
  @State private var newAttribution = ""

  var body: some View {
    Form {
      Section {
        TextField("Quote", text: $newText, axis: .vertical)
          .lineLimit(1...4)
        TextField("Attribution (optional)", text: $newAttribution)
        Button("Add quote") { add() }
          .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } header: {
        Text("Add your own")
      } footer: {
        Text("Your lines join the rotation alongside the packs you've enabled.")
      }

      if quotes.isEmpty {
        Section {
          Text("No quotes yet.")
            .foregroundStyle(.secondary)
        }
      } else {
        Section {
          ForEach(quotes) { quote in
            VStack(alignment: .leading, spacing: 3) {
              Text(quote.text)
              if !quote.attribution.isEmpty {
                Text(quote.attribution)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          .onDelete(perform: delete)
        } header: {
          Text("Your quotes")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Your quotes")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .septenaQuotesChanged)) { _ in
      reload()
    }
  }

  private func reload() {
    quotes = QuoteStore.shared.all(origin: "user")
  }

  private func add() {
    QuoteStore.shared.addUserQuote(text: newText, attribution: newAttribution)
    newText = ""
    newAttribution = ""
  }

  private func delete(at offsets: IndexSet) {
    for index in offsets { QuoteStore.shared.delete(id: quotes[index].id) }
  }
}

// MARK: - Readwise

struct ReadwiseConnectView: View {
  // The shared provider is @Observable, so reading its state here tracks it.
  private var provider: ReadwiseProvider { ReadwiseProvider.shared }

  @AppStorage(SettingsKey.dailyMessageReadwiseEnabled) private var readwiseEnabled = true

  @State private var tokenInput = ""
  @State private var statusMessage: String?
  @State private var isError = false

  var body: some View {
    Form {
      if provider.hasToken {
        connectedSections
      } else {
        connectSection
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Readwise")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  @ViewBuilder
  private var connectSection: some View {
    Section {
      SecureField("Access token", text: $tokenInput)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
      Button("Connect") { connect() }
        .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || provider.isSyncing)
      if let statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(isError ? Color.red : .secondary)
      }
    } header: {
      Text("Connect Readwise")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text("Pulls your highlights into the daily-message rotation. The token is kept in your Keychain, syncs to your other devices via iCloud Keychain, and is never sent to any Septena server.")
        Link("Get your access token", destination: URL(string: "https://readwise.io/access_token")!)
      }
    }
  }

  @ViewBuilder
  private var connectedSections: some View {
    Section {
      Toggle(isOn: $readwiseEnabled) {
        Text("Show in daily message")
      }
    } footer: {
      Text("Turn off to drop your Readwise highlights from the rotation without disconnecting — your imported highlights, packs, and own quotes stay.")
    }

    Section {
      LabeledContent("Status") {
        if provider.isSyncing {
          Text("Syncing…").foregroundStyle(.secondary)
        } else {
          Text("Connected").foregroundStyle(.green)
        }
      }
      if let count = provider.lastSyncCount {
        LabeledContent("Highlights", value: "\(count)")
      }
      if let when = provider.lastSyncedAt {
        LabeledContent("Last synced", value: when.formatted(date: .abbreviated, time: .shortened))
      }
      Button("Sync now") { sync() }
        .disabled(provider.isSyncing)
      if let statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(isError ? Color.red : .secondary)
      }
    } footer: {
      Text("Highlights are stored on this device and re-imported per device from your own token. Re-syncing only adds what's new.")
    }

    Section {
      NavigationLink {
        ReadwiseBookPickerView()
      } label: {
        LabeledContent("Choose books", value: booksSummary)
      }
      .disabled(provider.isSyncing)
    } footer: {
      Text("Pick which books and articles feed the rotation. With \u{201C}All books\u{201D} on, new ones you add to Readwise are included automatically.")
    }

    Section {
      Button("Disconnect", role: .destructive) { disconnect() }
        .disabled(provider.isSyncing)
    } footer: {
      Text("Removes the token and the imported highlights from the rotation. Your own quotes are untouched.")
    }
  }

  private var booksSummary: String {
    guard let ids = provider.selectedBookIDs else { return "All books" }
    if ids.isEmpty { return "None" }
    return ids.count == 1 ? "1 book" : "\(ids.count) books"
  }

  private func connect() {
    let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return }
    provider.setToken(token)
    statusMessage = nil
    isError = false
    Task {
      let ok = await provider.validateToken()
      guard ok else {
        provider.clearToken()
        statusMessage = "Couldn't verify that token. Check it and try again."
        isError = true
        return
      }
      tokenInput = ""
      await runSync()
    }
  }

  private func sync() {
    statusMessage = nil
    isError = false
    Task { await runSync() }
  }

  private func runSync() async {
    do {
      let n = try await provider.sync()
      statusMessage = "Imported \(n) highlights."
      isError = false
    } catch {
      statusMessage = "Sync failed. \(provider.lastSyncError ?? "")"
      isError = true
    }
  }

  private func disconnect() {
    provider.clearToken()
    QuoteStore.shared.deleteAllReadwise()
    statusMessage = nil
    isError = false
  }
}

// MARK: - Readwise book picker

/// Lets the user narrow which Readwise sources feed the rotation. Edits the
/// provider's `selectedBookIDs` and re-syncs on dismiss so the highlight set
/// (and the parent's count) reflects the choice. Selection is device-local —
/// same as the rest of the Readwise integration.
struct ReadwiseBookPickerView: View {
  private var provider: ReadwiseProvider { ReadwiseProvider.shared }

  @State private var books: [ReadwiseBook] = []
  @State private var isLoading = true
  @State private var loadError: String?
  @State private var importAll = true
  @State private var selected: Set<Int> = []
  @State private var dirty = false

  var body: some View {
    Form {
      if isLoading {
        Section {
          HStack(spacing: 8) {
            ProgressView()
            Text("Loading your library…").foregroundStyle(.secondary)
          }
        }
      } else if let loadError {
        Section {
          Text(loadError).foregroundStyle(.red)
          Button("Try again") { Task { await load() } }
        }
      } else {
        Section {
          Toggle("All books", isOn: $importAll)
            .onChange(of: importAll) { _, on in
              dirty = true
              if on { selected = Set(books.map(\.id)) }
            }
        } footer: {
          Text("When on, every book and article is included — and anything new you add to Readwise joins automatically.")
        }

        if !importAll {
          Section {
            ForEach(books) { book in
              Button { toggle(book.id) } label: {
                HStack(alignment: .firstTextBaseline) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).foregroundStyle(.primary)
                    Text(subtitle(book)).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 12)
                  if selected.contains(book.id) {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                  }
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          } header: {
            HStack {
              Text("\(selected.count) of \(books.count) selected")
              Spacer()
              Button(selected.count == books.count ? "Deselect all" : "Select all") {
                dirty = true
                selected = selected.count == books.count ? [] : Set(books.map(\.id))
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Choose books")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await load() }
    .onDisappear { persistAndSync() }
  }

  private func subtitle(_ book: ReadwiseBook) -> String {
    let count = book.numHighlights == 1 ? "1 highlight" : "\(book.numHighlights) highlights"
    return book.author.isEmpty ? count : "\(book.author) · \(count)"
  }

  private func toggle(_ id: Int) {
    dirty = true
    if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
  }

  private func load() async {
    isLoading = true
    loadError = nil
    do {
      let fetched = try await provider.fetchBooks()
      books = fetched
      if let stored = provider.selectedBookIDs {
        importAll = false
        // Keep only ids that still exist in the library.
        selected = stored.intersection(Set(fetched.map(\.id)))
      } else {
        importAll = true
        selected = Set(fetched.map(\.id))
      }
    } catch {
      loadError = "Couldn't load your library. \(provider.lastSyncError ?? "Check your connection and try again.")"
    }
    isLoading = false
  }

  private func persistAndSync() {
    guard dirty else { return }
    provider.setSelectedBookIDs(importAll ? nil : selected)
    Task { try? await provider.sync() }
  }
}

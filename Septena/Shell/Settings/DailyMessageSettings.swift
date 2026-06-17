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
        Text("Pulls your highlights into the daily-message rotation. The token stays on this device and is never sent to any Septena server.")
        Link("Get your access token", destination: URL(string: "https://readwise.io/access_token")!)
      }
    }
  }

  @ViewBuilder
  private var connectedSections: some View {
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
      Text("Synced highlights follow you across your devices. Re-syncing only adds what's new.")
    }

    Section {
      Button("Disconnect", role: .destructive) { disconnect() }
        .disabled(provider.isSyncing)
    } footer: {
      Text("Removes the token and the imported highlights from the rotation. Your own quotes are untouched.")
    }
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

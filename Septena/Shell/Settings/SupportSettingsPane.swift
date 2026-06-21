import SwiftUI

struct SupportSettingsPane: View {
  @State private var tickets: [CommunitySupportTicket] = []
  // Starts true so the first render shows a spinner, not the "no tickets" empty
  // state, while the initial fetch is in flight.
  @State private var loading = true
  @State private var errorMessage: String?
  @State private var showingComposer = false
  @State private var role = "user"

  /// nil = still checking, false = no iCloud (show email fallback), true =
  /// ready to transact (iCloud + App Attest, or a Sign in with Apple session).
  @State private var canUseInAppSupport: Bool?
  /// iCloud is present but this device needs Sign in with Apple (no App Attest).
  @State private var needsAppleSignIn = false

  private var isMaintainer: Bool {
    role == "maintainer" || role == "moderator"
  }

  var body: some View {
    List {
      if canUseInAppSupport == nil {
        Section { HStack { ProgressView(); Text("Checking iCloud…").foregroundStyle(.secondary) } }
      } else if needsAppleSignIn {
        CommunitySignInSection { Task { await reload() } }
        fallbackSection
      } else if canUseInAppSupport == false {
        fallbackSection
      } else {
        if isMaintainer {
          Section {
            Label("You're a maintainer — you're seeing every ticket.", systemImage: "checkmark.seal.fill")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        Section {
          Button {
            showingComposer = true
          } label: {
            Label("New support ticket", systemImage: "square.and.pencil")
          }
        } footer: {
          // Block F (docs/MAKER_IDENTITY.md): personal, without pretending the
          // support desk is a brand. Only non-maintainers see it.
          if !isMaintainer {
            Text("You're reaching me directly — I'm the one person who makes Septena, and I read every ticket.")
          }
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }

        Section("Tickets") {
          if loading && tickets.isEmpty {
            HStack {
              ProgressView()
              Text("Loading…")
                .foregroundStyle(.secondary)
            }
          } else if tickets.isEmpty {
            ContentUnavailableView("No tickets", systemImage: "tray", description: Text("Support conversations you start will appear here."))
          } else {
            ForEach(tickets) { ticket in
              NavigationLink {
                SupportTicketDetailView(ticketID: ticket.id, isMaintainer: isMaintainer)
              } label: {
                SupportTicketRow(ticket: ticket)
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task {
      if canUseInAppSupport == nil { await refreshAccess() }
      if canUseInAppSupport == true { await loadData() }
    }
    .refreshable {
      await reload()
    }
    .sheet(isPresented: $showingComposer) {
      SupportTicketComposer { thread in
        tickets.removeAll { $0.id == thread.ticket.id }
        tickets.insert(thread.ticket, at: 0)
      }
    }
    .toolbar {
      if canUseInAppSupport == true {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showingComposer = true
          } label: {
            Image(systemName: "square.and.pencil")
          }
          .accessibilityLabel("New support ticket")
        }
      }
    }
  }

  private var fallbackSection: some View {
    Section {
      Link(destination: URL(string: "mailto:mz@envisioning.com")!) {
        Label("Email support", systemImage: "envelope")
      }
      Text("Email goes straight to me — I make Septena alone. In-app tickets tie to your Apple ID; sign in to iCloud to use them, or email any time.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      OpenAppleAccountButton()
    }
  }

  @MainActor
  private func refreshAccess() async {
    let access = await CommunityClient.shared.access()
    canUseInAppSupport = (access == .ready)
    needsAppleSignIn = (access == .needsAppleSignIn)
  }

  /// Role + tickets concurrently — separate endpoints, no need to serialize.
  @MainActor
  private func loadData() async {
    async let roleLoad: Void = loadRole()
    async let ticketsLoad: Void = loadTickets()
    _ = await (roleLoad, ticketsLoad)
  }

  @MainActor
  private func reload() async {
    await refreshAccess()
    if canUseInAppSupport == true { await loadData() }
  }

  @MainActor
  private func loadRole() async {
    role = (try? await CommunityClient.shared.me().user.role) ?? role
  }

  @MainActor
  private func loadTickets() async {
    loading = true
    defer { loading = false }
    do {
      tickets = try await CommunityClient.shared.supportTickets()
      errorMessage = nil
    } catch {
      errorMessage = supportErrorText(error)
    }
  }
}

private struct SupportTicketRow: View {
  let ticket: CommunitySupportTicket

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(ticket.subject)
          .font(.body)
          .lineLimit(2)
        Spacer(minLength: 8)
        SupportStatusBadge(status: ticket.status)
      }
      HStack(spacing: 8) {
        Label(categoryLabel(ticket.category), systemImage: categoryIcon(ticket.category))
        Text(ticket.lastMessageAt)
          .lineLimit(1)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}

private struct SupportTicketDetailView: View {
  let ticketID: String
  var isMaintainer: Bool = false

  @State private var thread: CommunitySupportThread?
  @State private var reply = ""
  @State private var loading = false
  @State private var sending = false
  @State private var changingStatus = false
  @State private var isInternalNote = false
  @State private var errorMessage: String?

  var body: some View {
    List {
      if let ticket = thread?.ticket {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(ticket.subject)
                .font(.headline)
              Spacer()
              SupportStatusBadge(status: ticket.status)
            }
            Label(categoryLabel(ticket.category), systemImage: categoryIcon(ticket.category))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
      }

      if let errorMessage {
        Section {
          Text(errorMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Section("Messages") {
        if loading && thread == nil {
          HStack {
            ProgressView()
            Text("Loading…")
              .foregroundStyle(.secondary)
          }
        } else {
          ForEach(thread?.messages ?? []) { message in
            SupportMessageRow(message: message)
          }
        }
      }

      // Maintainers can reply to any ticket (including closed); regular users
      // only while the ticket is open.
      if isMaintainer || thread?.ticket.status != "closed" {
        Section("Reply") {
          TextEditor(text: $reply)
            .frame(minHeight: 96)
          if isMaintainer {
            Toggle(isOn: $isInternalNote) {
              Label("Internal note", systemImage: "eye.slash")
            }
          }
          Button {
            Task { await sendReply() }
          } label: {
            if sending {
              ProgressView()
            } else {
              Label(isInternalNote ? "Add internal note" : "Send reply",
                    systemImage: isInternalNote ? "lock.doc" : "paperplane")
            }
          }
          .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
      }

      if isMaintainer, let ticket = thread?.ticket {
        Section {
          if ticket.status == "closed" {
            Button {
              Task { await setStatus("waiting_on_maintainer") }
            } label: {
              Label("Reopen ticket", systemImage: "lock.open")
            }
            .disabled(changingStatus)
          } else {
            Button(role: .destructive) {
              Task { await setStatus("closed") }
            } label: {
              Label("Close ticket", systemImage: "lock")
            }
            .disabled(changingStatus)
          }
        } header: {
          Text("Manage")
        } footer: {
          Text("Closing keeps the conversation but stops the user from replying. Internal notes are visible only to maintainers.")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Ticket")
    .task { await loadThread() }
    .refreshable { await loadThread() }
  }

  @MainActor
  private func setStatus(_ status: String) async {
    changingStatus = true
    defer { changingStatus = false }
    do {
      thread = try await CommunityClient.shared.setSupportTicketStatus(id: ticketID, status: status)
      errorMessage = nil
    } catch {
      errorMessage = supportErrorText(error)
    }
  }

  @MainActor
  private func loadThread() async {
    loading = true
    defer { loading = false }
    do {
      thread = try await CommunityClient.shared.supportTicket(id: ticketID)
      errorMessage = nil
    } catch {
      errorMessage = supportErrorText(error)
    }
  }

  @MainActor
  private func sendReply() async {
    let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    sending = true
    defer { sending = false }
    do {
      thread = try await CommunityClient.shared.postSupportMessage(
        ticketID: ticketID,
        body: body,
        isInternal: isInternalNote && isMaintainer
      )
      reply = ""
      isInternalNote = false
      errorMessage = nil
    } catch {
      errorMessage = supportErrorText(error)
    }
  }
}

private struct SupportMessageRow: View {
  let message: CommunitySupportMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Label(roleLabel(message.authorRole), systemImage: roleIcon(message.authorRole))
          .font(.caption.weight(.semibold))
        if message.isInternal {
          Text("Internal")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .foregroundStyle(.orange)
        }
        Spacer()
        Text(message.createdAt)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Text(message.body)
        .font(.callout)
        .textSelection(.enabled)
    }
    .padding(.vertical, 4)
    .listRowBackground(message.isInternal ? Color.orange.opacity(0.06) : nil)
  }
}

private struct SupportTicketComposer: View {
  let onCreated: (CommunitySupportThread) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var category = "bug"
  @State private var subject = ""
  @State private var messageBody = ""
  @State private var sending = false
  @State private var errorMessage: String?

  private var canSend: Bool {
    subject.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 &&
    !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !sending
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Category", selection: $category) {
            Label("Bug", systemImage: "ladybug").tag("bug")
            Label("Account", systemImage: "person.crop.circle").tag("account")
            Label("Data", systemImage: "externaldrive").tag("data")
            Label("Idea", systemImage: "lightbulb").tag("idea")
            Label("Other", systemImage: "ellipsis.circle").tag("other")
          }
          TextField("Subject", text: $subject)
          TextEditor(text: $messageBody)
            .frame(minHeight: 160)
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("New Ticket")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await create() }
          } label: {
            if sending {
              ProgressView()
            } else {
              Text("Send")
            }
          }
          .disabled(!canSend)
        }
      }
    }
  }

  @MainActor
  private func create() async {
    sending = true
    defer { sending = false }
    do {
      let thread = try await CommunityClient.shared.createSupportTicket(
        category: category,
        subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
        body: messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      onCreated(thread)
      dismiss()
    } catch {
      errorMessage = supportErrorText(error)
    }
  }
}

private struct SupportStatusBadge: View {
  let status: String

  var body: some View {
    Text(statusLabel(status))
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(statusTint(status).opacity(0.14), in: Capsule())
      .foregroundStyle(statusTint(status))
  }
}

private func supportErrorText(_ error: Error) -> String {
  if case CommunityClient.ClientError.cloudKitUserUnavailable = error {
    return "iCloud is unavailable. Email support instead."
  }
  if case CommunityClient.ClientError.badResponse(let code) = error {
    if code == 403 { return "In-app support is not available on this device yet." }
    if code == 429 { return "Too many requests. Try again later." }
    return "Support request failed with HTTP \(code)."
  }
  return error.localizedDescription
}

private func statusLabel(_ status: String) -> String {
  switch status {
  case "open": return "Open"
  case "waiting_on_user": return "Your turn"
  case "waiting_on_maintainer": return "Pending"
  case "closed": return "Closed"
  default: return status
  }
}

private func statusTint(_ status: String) -> Color {
  switch status {
  case "waiting_on_user": return .orange
  case "waiting_on_maintainer": return .blue
  case "closed": return .secondary
  default: return .green
  }
}

private func categoryLabel(_ category: String) -> String {
  switch category {
  case "bug": return "Bug"
  case "account": return "Account"
  case "data": return "Data"
  case "idea": return "Idea"
  default: return "Other"
  }
}

private func categoryIcon(_ category: String) -> String {
  switch category {
  case "bug": return "ladybug"
  case "account": return "person.crop.circle"
  case "data": return "externaldrive"
  case "idea": return "lightbulb"
  default: return "ellipsis.circle"
  }
}

private func roleLabel(_ role: String) -> String {
  switch role {
  case "maintainer": return "Septena"
  case "moderator": return "Moderator"
  default: return "You"
  }
}

private func roleIcon(_ role: String) -> String {
  switch role {
  case "maintainer": return "checkmark.seal.fill"
  case "moderator": return "shield"
  default: return "person.crop.circle"
  }
}

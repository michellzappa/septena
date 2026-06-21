import SwiftUI

/// Testimonials: every user can leave one short quote (+ optional rating) about
/// Septena. Backed by the community Worker; maintainer-approved before it's
/// eligible for the public website. Author identity rides the public-profile
/// gate, like the roadmap.
struct CommunityTestimonialPane: View {
  @State private var mine: CommunityTestimonial?
  @State private var others: [CommunityTestimonial] = []
  @State private var role = "user"

  @State private var editing = false
  @State private var draftBody = ""
  @State private var draftRating: Int? = nil

  // Starts true so the first render shows a spinner, not the empty state, while
  // the initial fetch is in flight.
  @State private var loading = true
  @State private var busy = false
  @State private var errorMessage: String?

  /// nil = still checking, false = no iCloud (show fallback), true = ready to
  /// transact (iCloud + App Attest, or a Sign in with Apple session).
  @State private var canUse: Bool?
  /// iCloud is present but this device needs Sign in with Apple (no App Attest).
  @State private var needsAppleSignIn = false
  private var isMaintainer: Bool { role == "maintainer" || role == "moderator" }

  private var canSubmit: Bool {
    let n = draftBody.trimmingCharacters(in: .whitespacesAndNewlines).count
    return n >= 10 && n <= 500 && !busy
  }

  var body: some View {
    List {
      if canUse == nil {
        Section { HStack { ProgressView(); Text("Checking iCloud…").foregroundStyle(.secondary) } }
      } else if needsAppleSignIn {
        CommunitySignInSection { Task { await reload() } }
      } else if canUse == false {
        fallbackSection
      } else if loading && mine == nil && others.isEmpty {
        Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
      } else {
        if isMaintainer {
          Section {
            Label("You're a maintainer — swipe a testimonial to approve, feature, or hide.",
                  systemImage: "checkmark.seal.fill")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        yourTestimonialSection

        if let errorMessage {
          Section { Text(errorMessage).font(.callout).foregroundStyle(.secondary) }
        }

        Section(isMaintainer ? "All testimonials" : "What others say") {
          if loading && others.isEmpty {
            HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
          } else if others.isEmpty {
            Text(isMaintainer ? "No testimonials yet." : "No published testimonials yet.")
              .font(.callout).foregroundStyle(.secondary)
          } else {
            ForEach(others) { t in
              TestimonialRow(testimonial: t, showStatus: isMaintainer)
                .contextMenu {
                  if isMaintainer {
                    if t.status != "approved" {
                      Button {
                        Task { await moderate(t, status: "approved") }
                      } label: { Label("Approve", systemImage: "checkmark.circle") }
                    }
                    Button {
                      Task { await moderate(t, isFeatured: !t.isFeatured) }
                    } label: { Label(t.isFeatured ? "Unfeature" : "Feature", systemImage: "star") }
                    Button(role: .destructive) {
                      Task { await moderate(t, status: "hidden") }
                    } label: { Label("Hide", systemImage: "eye.slash") }
                  }
                }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task {
      if canUse == nil { await refreshAccess() }
      if canUse == true { await loadData() }
    }
    .refreshable {
      await reload()
    }
  }

  @ViewBuilder
  private var yourTestimonialSection: some View {
    if editing || mine == nil {
      Section {
        TextEditor(text: $draftBody).frame(minHeight: 100)
        StarRatingPicker(rating: $draftRating)
        HStack {
          Button {
            Task { await submit() }
          } label: {
            if busy { ProgressView() } else { Text(mine == nil ? "Share testimonial" : "Save changes") }
          }
          .disabled(!canSubmit)
          if editing {
            Spacer()
            Button("Cancel") { editing = false; resetDraft() }
              .foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Your testimonial")
      } footer: {
        Text("A sentence or two about how Septena helps you (10–500 characters). With your profile public, it can appear with your name on the website once approved.")
      }
    } else if let mine {
      Section {
        TestimonialRow(testimonial: mine, showStatus: true)
        Button {
          draftBody = mine.body; draftRating = mine.rating; editing = true
        } label: { Label("Edit", systemImage: "pencil") }
        Button(role: .destructive) {
          Task { await deleteMine() }
        } label: { Label("Delete", systemImage: "trash") }
      } header: {
        Text("Your testimonial")
      } footer: {
        Text(statusFooter(mine.status))
      }
    }
  }

  private var fallbackSection: some View {
    Section {
      Label("Sign in to iCloud to leave a testimonial.", systemImage: "quote.bubble")
        .foregroundStyle(.secondary)
      Text("Testimonials are tied to your Apple ID — sign in to iCloud, then come back.")
        .font(.footnote).foregroundStyle(.secondary)
      OpenAppleAccountButton()
    }
  }

  private func resetDraft() { draftBody = ""; draftRating = nil }

  private func statusFooter(_ status: String) -> String {
    switch status {
    case "approved": return "Published — eligible to appear on the website."
    case "hidden": return "Hidden by a maintainer. Editing resubmits it for review."
    default: return "Pending review. A maintainer will approve it before it can show publicly."
    }
  }

  @MainActor private func refreshAccess() async {
    let access = await CommunityClient.shared.access()
    canUse = (access == .ready)
    needsAppleSignIn = (access == .needsAppleSignIn)
  }

  /// Role + data concurrently — separate endpoints, no need to serialize.
  @MainActor private func loadData() async {
    async let roleLoad: Void = loadRole()
    async let dataLoad: Void = load()
    _ = await (roleLoad, dataLoad)
  }

  @MainActor private func reload() async {
    await refreshAccess()
    if canUse == true { await loadData() }
  }

  @MainActor private func loadRole() async {
    role = (try? await CommunityClient.shared.me().user.role) ?? role
  }

  @MainActor private func load() async {
    loading = true
    defer { loading = false }
    do {
      async let m = CommunityClient.shared.myTestimonial()
      async let o = CommunityClient.shared.testimonials()
      mine = try await m
      others = try await o
      errorMessage = nil
    } catch {
      errorMessage = communityTestimonialErrorText(error)
    }
  }

  @MainActor private func submit() async {
    let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard body.count >= 10 else { return }
    busy = true; defer { busy = false }
    do {
      mine = try await CommunityClient.shared.putTestimonial(body: body, rating: draftRating)
      editing = false
      resetDraft()
      errorMessage = nil
      await load()
    } catch {
      errorMessage = communityTestimonialErrorText(error)
    }
  }

  @MainActor private func deleteMine() async {
    busy = true; defer { busy = false }
    do {
      try await CommunityClient.shared.deleteTestimonial()
      mine = nil
      resetDraft()
      errorMessage = nil
      await load()
    } catch {
      errorMessage = communityTestimonialErrorText(error)
    }
  }

  @MainActor private func moderate(_ t: CommunityTestimonial, status: String? = nil, isFeatured: Bool? = nil) async {
    busy = true; defer { busy = false }
    do {
      others = try await CommunityClient.shared.moderateTestimonial(id: t.id, status: status, isFeatured: isFeatured)
      errorMessage = nil
    } catch {
      errorMessage = communityTestimonialErrorText(error)
    }
  }
}

private struct TestimonialRow: View {
  let testimonial: CommunityTestimonial
  var showStatus = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let rating = testimonial.rating {
        StarsView(rating: rating)
      }
      Text("“\(testimonial.body)”").font(.callout).textSelection(.enabled)
      HStack(spacing: 8) {
        if let by = testimonial.author?.label {
          Text("— \(by)").font(.caption).foregroundStyle(.secondary)
          CommunityBadge(role: testimonial.author?.role, supporterTier: testimonial.author?.supporterTier)
        } else {
          Text("— Anonymous").font(.caption).foregroundStyle(.tertiary)
        }
        if testimonial.isFeatured {
          Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
        }
        Spacer()
        if showStatus {
          TestimonialStatusBadge(status: testimonial.status)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

private struct StarsView: View {
  let rating: Int
  var body: some View {
    HStack(spacing: 2) {
      ForEach(1...5, id: \.self) { i in
        Image(systemName: i <= rating ? "star.fill" : "star")
          .font(.caption2)
          .foregroundStyle(.yellow)
      }
    }
    .accessibilityLabel("\(rating) out of 5")
  }
}

private struct StarRatingPicker: View {
  @Binding var rating: Int?
  var body: some View {
    HStack(spacing: 6) {
      ForEach(1...5, id: \.self) { i in
        Image(systemName: (rating ?? 0) >= i ? "star.fill" : "star")
          .font(.title3)
          .foregroundStyle(.yellow)
          .onTapGesture { rating = i }
          .accessibilityLabel("\(i) star\(i == 1 ? "" : "s")")
      }
      Spacer()
      if rating != nil {
        Button("Clear") { rating = nil }
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Rating optional").font(.caption).foregroundStyle(.tertiary)
      }
    }
  }
}

private struct TestimonialStatusBadge: View {
  let status: String
  var body: some View {
    Text(label)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(tint.opacity(0.14), in: Capsule())
      .foregroundStyle(tint)
  }
  private var label: String {
    switch status {
    case "approved": return "Published"
    case "hidden": return "Hidden"
    default: return "Pending"
    }
  }
  private var tint: Color {
    switch status {
    case "approved": return .green
    case "hidden": return .secondary
    default: return .orange
    }
  }
}

private func communityTestimonialErrorText(_ error: Error) -> String {
  if case CommunityClient.ClientError.cloudKitUserUnavailable = error {
    return "iCloud is unavailable. Sign in to iCloud and try again."
  }
  if case CommunityClient.ClientError.badResponse(let code) = error {
    switch code {
    case 403: return "Testimonials aren't available on this device yet."
    case 429: return "Too many requests. Try again in a moment."
    default:  return "Request failed with HTTP \(code)."
    }
  }
  return error.localizedDescription
}

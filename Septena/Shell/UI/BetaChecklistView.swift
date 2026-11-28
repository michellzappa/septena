// The Beta screen (ADR 0064, docs/BETA_ONBOARDING_SPEC.md §7): the deal,
// one row per item to tick, a note per item through Contact Support, and the
// weekly "I used Septena for real". Shared by iPhone, iPad and Mac: a page in
// Settings on every one. Every word comes from `GET /v1/beta`
// (`BetaCenter`), never from the string catalog.

import SwiftUI

struct BetaChecklistView: View {
  @State private var center = BetaCenter.shared
  /// The item whose note is open in Contact Support.
  @State private var noteItem: BetaWire.Item?

  var body: some View {
    Form {
      if let checklist = center.checklist {
        content(checklist)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(center.checklist?.copy.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .task { await center.refresh() }
    .sheet(item: $noteItem) { item in
      noteSheet(item)
    }
  }

  @ViewBuilder
  private func content(_ checklist: BetaChecklist) -> some View {
    let copy = checklist.copy
    Section {
      Text(copy.deal)
        .font(.septenaTaskTitle)
        .fixedSize(horizontal: false, vertical: true)
      Text(copy.intro)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    ForEach(checklist.items) { item in
      Section {
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .font(.septenaCardTitle)
          Text(item.`try`)
            .font(.septenaNotes)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        Toggle(copy.tried, isOn: Binding(
          get: { checklist.tried[item.id] != nil },
          set: { center.setTried(item, $0) }
        ))
        Button(copy.note) { noteItem = item }
      }
    }

    Section {
      Button(copy.ack) { center.acknowledge() }
    } footer: {
      if let done = checklist.ackDone { Text(done) }
    }
  }

  /// The app's Contact Support form, its first line "Beta: <item>".
  private func noteSheet(_ item: BetaWire.Item) -> some View {
    NavigationStack {
      SupportView(prefill: center.checklist?.noteSubject(item))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(RegistrySupport.closeTitle) { noteItem = nil }
          }
        }
    }
    #if os(macOS)
    .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 620)
    #endif
  }
}

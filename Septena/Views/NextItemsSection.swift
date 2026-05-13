import SwiftUI

// Today-screen "everything else" rendering: chores, habits, supplements.
// Split into two views (open / done) so the parent can place all open items
// above tasks-done. Shared state lives in NextItemsModel.

// MARK: - Shared model

@MainActor
final class NextItemsModel: ObservableObject {
  @Published var habits: [HabitDayItem] = []
  @Published var habitBuckets: [String] = []
  @Published var supplements: [SupplementDayItem] = []
  @Published var chores: [ChoreItem] = []
  /// Chores deferred this session — kept visible (with badge) until reload.
  @Published var deferredChores: [String: String] = [:]
  /// Chores marked done this session — same treatment.
  @Published var completedChores: Set<String> = []

  private let today: String = SeptenaDate.today

  // MARK: - Open / Done splits (the source of truth for both subviews)

  var openHabits: [HabitDayItem] {
    habits.filter { !$0.done && !$0.skipped }
  }

  var doneHabits: [HabitDayItem] {
    habits.filter { $0.done || $0.skipped }
  }

  var openSupplements: [SupplementDayItem] {
    supplements.filter { !$0.done }
  }

  var doneSupplements: [SupplementDayItem] {
    supplements.filter { $0.done }
  }

  /// Chores due today or overdue, not yet acted on this session.
  var openChores: [ChoreItem] {
    chores
      .filter { $0.daysOverdue >= 0 }
      .filter { !completedChores.contains($0.id) && deferredChores[$0.id] == nil }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
  }

  /// Chores acted on this session (completed or deferred). Stay visible until
  /// next full reload removes them from `chores` or shifts their daysOverdue.
  var doneChores: [ChoreItem] {
    chores.filter { completedChores.contains($0.id) || deferredChores[$0.id] != nil }
  }

  var hasAnyOpen: Bool {
    !openHabits.isEmpty || !openSupplements.isEmpty || !openChores.isEmpty
  }

  var hasAnyDone: Bool {
    !doneHabits.isEmpty || !doneSupplements.isEmpty || !doneChores.isEmpty
  }

  // MARK: - Loading

  func load(client: SeptenaClient) async {
    async let h = try? await client.habitsDay(date: today)
    async let s = try? await client.supplementsDay(date: today)
    async let c = try? await client.chores()
    let (hRes, sRes, cRes) = await (h, s, c)
    if let hRes {
      habits = hRes.buckets.flatMap { hRes.grouped[$0] ?? [] }
      habitBuckets = hRes.buckets
    }
    if let sRes { supplements = sRes.items }
    if let cRes { chores = cRes }
    // Reload clears the per-session "kept visible" buckets — server is now
    // the source of truth.
    deferredChores = [:]
    completedChores = []
  }

  // MARK: - Mutations (optimistic local flips, server-side write)

  func toggleHabit(_ habit: HabitDayItem, client: SeptenaClient) {
    let next = !habit.done
    if next { Haptics.success() } else { Haptics.tap() }
    if let i = habits.firstIndex(where: { $0.id == habit.id }) {
      habits[i].done = next
      if next { habits[i].skipped = false }
    }
    Task {
      do { try await client.toggleHabit(id: habit.id, date: today, done: next) }
      catch { await load(client: client) }
    }
  }

  func skipHabit(_ habit: HabitDayItem, skipped: Bool, client: SeptenaClient) {
    Haptics.tick()
    if let i = habits.firstIndex(where: { $0.id == habit.id }) {
      habits[i].skipped = skipped
      if skipped { habits[i].done = false }
    }
    Task {
      do { try await client.skipHabit(id: habit.id, date: today, skipped: skipped) }
      catch { await load(client: client) }
    }
  }

  func toggleSupplement(_ supp: SupplementDayItem, client: SeptenaClient) {
    let next = !supp.done
    if next { Haptics.success() } else { Haptics.tap() }
    if let i = supplements.firstIndex(where: { $0.id == supp.id }) {
      supplements[i].done = next
    }
    Task {
      do { try await client.toggleSupplement(id: supp.id, date: today, done: next) }
      catch { await load(client: client) }
    }
  }

  func completeChore(_ chore: ChoreItem, client: SeptenaClient) {
    Haptics.success()
    completedChores.insert(chore.id)
    deferredChores.removeValue(forKey: chore.id)
    Task {
      do { try await client.completeChore(id: chore.id, date: today) }
      catch {
        completedChores.remove(chore.id)
        await load(client: client)
      }
    }
  }

  func deferChore(_ chore: ChoreItem, mode: String, label: String, client: SeptenaClient) {
    Haptics.tick()
    deferredChores[chore.id] = label
    completedChores.remove(chore.id)
    Task {
      do { try await client.deferChore(id: chore.id, mode: mode) }
      catch {
        deferredChores.removeValue(forKey: chore.id)
        await load(client: client)
      }
    }
  }

  func uncompleteChore(_ chore: ChoreItem, client: SeptenaClient) {
    Haptics.tap()
    completedChores.remove(chore.id)
    Task {
      do { try await client.uncompleteChore(id: chore.id, date: today) }
      catch { await load(client: client) }
    }
  }
}

// MARK: - Open subview (rendered above tasks-done)

struct NextOpenSection: View {
  @ObservedObject var model: NextItemsModel
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var theme: SectionTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !model.openChores.isEmpty {
        sectionHeader("Chores", icon: "list.bullet.clipboard",
                      tint: theme.color(for: "chores"))
        ForEach(model.openChores) { chore in
          ChoreRow(chore: chore, model: model, client: client,
                   tint: theme.color(for: "chores"))
          Hairline()
        }
      }

      if !model.openHabits.isEmpty {
        sectionHeader("Habits", icon: "repeat",
                      tint: theme.color(for: "habits"))
        ForEach(model.habitBuckets, id: \.self) { bucket in
          let inBucket = model.openHabits.filter { $0.bucket == bucket }
          if !inBucket.isEmpty {
            bucketLabel(bucket)
            ForEach(inBucket) { habit in
              HabitRow(habit: habit, model: model, client: client,
                       tint: theme.color(for: "habits"))
              Hairline()
            }
          }
        }
      }

      if !model.openSupplements.isEmpty {
        sectionHeader("Supplements", icon: "pills",
                      tint: theme.color(for: "supplements"))
        ForEach(model.openSupplements) { supp in
          SupplementRow(supplement: supp, model: model, client: client,
                        tint: theme.color(for: "supplements"))
          Hairline()
        }
      }
    }
  }
}

// MARK: - Done subview (rendered after tasks-done)

struct NextDoneSection: View {
  @ObservedObject var model: NextItemsModel
  @EnvironmentObject var client: SeptenaClient
  @EnvironmentObject var theme: SectionTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // No section headers in the done strip — keep it visually quiet.
      // Items still wear their section accent on the (filled) check.
      ForEach(model.doneChores) { chore in
        ChoreRow(chore: chore, model: model, client: client,
                 tint: theme.color(for: "chores"))
        Hairline()
      }
      ForEach(model.doneHabits) { habit in
        HabitRow(habit: habit, model: model, client: client,
                 tint: theme.color(for: "habits"))
        Hairline()
      }
      ForEach(model.doneSupplements) { supp in
        SupplementRow(supplement: supp, model: model, client: client,
                      tint: theme.color(for: "supplements"))
        Hairline()
      }
    }
  }
}

// MARK: - Row primitives

private struct HabitRow: View {
  let habit: HabitDayItem
  @ObservedObject var model: NextItemsModel
  let client: SeptenaClient
  let tint: Color

  var body: some View {
    let inactive = habit.done || habit.skipped
    HStack(spacing: 12) {
      ThingsCheckbox(
        tint: habit.skipped && !habit.done ? Theme.inkSecondary : tint,
        isDone: inactive
      ) { model.toggleHabit(habit, client: client) }

      Text(habit.emoji ?? "•").font(.system(size: 16))
      Text(habit.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(inactive ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(inactive)
        .opacity(inactive ? 0.5 : 1)
      Spacer()
      if habit.skipped {
        StatusBadge(text: "Skipped")
      } else if let t = habit.time {
        Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 12)
    .frame(minHeight: Theme.rowHeight)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        model.skipHabit(habit, skipped: !habit.skipped, client: client)
      } label: {
        Label(habit.skipped ? "Unskip" : "Skip",
              systemImage: habit.skipped ? "arrow.uturn.left" : "forward.end")
      }
      .tint(Theme.inkSecondary)
    }
  }
}

private struct SupplementRow: View {
  let supplement: SupplementDayItem
  @ObservedObject var model: NextItemsModel
  let client: SeptenaClient
  let tint: Color

  var body: some View {
    HStack(spacing: 12) {
      ThingsCheckbox(tint: tint, isDone: supplement.done) {
        model.toggleSupplement(supplement, client: client)
      }
      Text(supplement.emoji ?? "•").font(.system(size: 16))
      Text(supplement.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(supplement.done ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(supplement.done)
        .opacity(supplement.done ? 0.5 : 1)
      Spacer()
      if let t = supplement.time {
        Text(t).font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 12)
    .frame(minHeight: Theme.rowHeight)
  }
}

private struct ChoreRow: View {
  let chore: ChoreItem
  @ObservedObject var model: NextItemsModel
  let client: SeptenaClient
  let tint: Color

  var body: some View {
    let isDone = model.completedChores.contains(chore.id)
    let deferLabel = model.deferredChores[chore.id]
    let inactive = isDone || deferLabel != nil

    HStack(spacing: 12) {
      ThingsCheckbox(
        tint: deferLabel != nil ? Theme.inkSecondary : tint,
        isDone: inactive
      ) {
        if isDone {
          model.uncompleteChore(chore, client: client)
        } else {
          model.completeChore(chore, client: client)
        }
      }
      Text(chore.emoji ?? "•").font(.system(size: 16))
      Text(chore.name)
        .font(.septenaTaskTitle)
        .foregroundStyle(inactive ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(inactive)
        .opacity(inactive ? 0.5 : 1)
      Spacer()
      if isDone {
        StatusBadge(text: "Done")
      } else if let label = deferLabel {
        StatusBadge(text: label)
      } else {
        choreOverdueBadge(chore.daysOverdue)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 12)
    .frame(minHeight: Theme.rowHeight)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        model.deferChore(chore, mode: "day", label: "Tomorrow", client: client)
      } label: {
        Label("Tomorrow", systemImage: "calendar.badge.plus")
      }
      .tint(Theme.inkSecondary)
      Button {
        model.deferChore(chore, mode: "weekend", label: "Weekend", client: client)
      } label: {
        Label("Weekend", systemImage: "calendar.badge.clock")
      }
      .tint(Theme.inkSecondary.opacity(0.7))
    }
  }

  @ViewBuilder
  private func choreOverdueBadge(_ days: Int) -> some View {
    if days > 0 {
      Text("\(days)d over").font(.septenaMeta).foregroundStyle(Theme.overdueRed)
    } else if days == 0 {
      Text("today").font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
    } else {
      Text("\(-days)d").font(.septenaMeta).foregroundStyle(Theme.inkSecondary)
    }
  }
}

// MARK: - Shared chrome

private struct StatusBadge: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.septenaMeta)
      .foregroundStyle(Theme.inkSecondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Theme.mutedSurface, in: Capsule())
  }
}

@ViewBuilder
private func sectionHeader(_ title: String, icon: String, tint: Color) -> some View {
  HStack(spacing: 8) {
    Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
    Text(title).font(.septenaSectionTitle).foregroundStyle(Theme.inkPrimary)
  }
  .padding(.horizontal, Theme.hPadding)
  .padding(.top, Theme.sectionSpacing)
  .padding(.bottom, 6)
}

@ViewBuilder
private func bucketLabel(_ bucket: String) -> some View {
  Text(bucket.uppercased())
    .font(.system(size: 11, weight: .semibold, design: .monospaced))
    .tracking(0.8)
    .foregroundStyle(Theme.inkSecondary)
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, 12)
    .padding(.bottom, 4)
}

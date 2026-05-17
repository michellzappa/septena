import SwiftUI

// Today-screen "everything else" rendering: chores, habits, supplements.
// Split into two views (open / done) so the parent can place all open items
// above tasks-done. Shared state lives in NextItemsModel.

// MARK: - Shared model

@MainActor
@Observable
final class NextItemsModel {
  var habits: [HabitDayItem] = []
  var habitBuckets: [String] = []
  var supplements: [SupplementDayItem] = []
  var chores: [ChoreItem] = []
  /// Chores deferred this session — kept visible (with badge) until reload.
  var deferredChores: [String: String] = [:]
  /// Chores marked done this session — same treatment.
  var completedChores: Set<String> = []
  /// Habits the user toggled/skipped this session. Keeps them rendered in
  /// the open list (struck through) so the row doesn't hop to the bottom
  /// the moment you check it.
  var actedHabits: Set<String> = []
  /// Same idea for supplements.
  var actedSupplements: Set<String> = []

  /// Flips true after the first network response (success or failure) so the
  /// empty state never flashes during the initial load.
  var hasLoaded: Bool = false

  private let today: String = SeptenaDate.today

  // MARK: - Open / Done splits (the source of truth for both subviews)

  /// Show an item in the open list if it's still pending OR if the user
  /// just acted on it this session (keeps it from jumping to "done").
  var openHabits: [HabitDayItem] {
    habits.filter { h in
      actedHabits.contains(h.id) || (!h.done && !h.skipped)
    }
  }

  var doneHabits: [HabitDayItem] {
    habits.filter { h in
      !actedHabits.contains(h.id) && (h.done || h.skipped)
    }
  }

  var openSupplements: [SupplementDayItem] {
    supplements.filter { s in
      actedSupplements.contains(s.id) || !s.done
    }
  }

  var doneSupplements: [SupplementDayItem] {
    supplements.filter { s in
      !actedSupplements.contains(s.id) && s.done
    }
  }

  /// Chores due today or overdue. Linger in the open list after completion
  /// (struck through) so the row doesn't vanish under the user's finger —
  /// same treatment as habits/supplements. Deferred chores hide because
  /// "defer" rescheduled them to a future day.
  var openChores: [ChoreItem] {
    chores
      .filter { $0.daysOverdue >= 0 }
      .filter { c in
        completedChores.contains(c.id) || deferredChores[c.id] == nil
      }
      .sorted { ($0.daysOverdue, $0.name) > ($1.daysOverdue, $1.name) }
  }

  /// Deferred-this-session chores only. Completed chores stay in the open
  /// list (lingering) to match the habit / supplement pattern.
  var doneChores: [ChoreItem] {
    chores.filter { !completedChores.contains($0.id) && deferredChores[$0.id] != nil }
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
    actedHabits = []
    actedSupplements = []
    hasLoaded = true
  }

  // MARK: - Mutations (optimistic local flips, server-side write)

  func toggleHabit(_ habit: HabitDayItem, client: SeptenaClient) {
    let next = !habit.done
    if next { Haptics.success() } else { Haptics.tap() }
    if let i = habits.firstIndex(where: { $0.id == habit.id }) {
      habits[i].done = next
      if next { habits[i].skipped = false }
    }
    actedHabits.insert(habit.id)
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
    actedHabits.insert(habit.id)
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
    actedSupplements.insert(supp.id)
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
  var model: NextItemsModel
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  /// Habits are bucketed by time-of-day on the server ("morning" / "afternoon"
  /// / "evening"). The Next screen only shows the habits for *now* — earlier
  /// buckets shouldn't linger as catch-up debt, and later buckets shouldn't
  /// surface ahead of time. One-bucket-at-a-time keeps the screen focused.
  private var currentHabitBucket: String {
    let hour = Calendar.current.component(.hour, from: Date())
    switch hour {
    case ..<12:  return "morning"
    case 12..<17: return "afternoon"
    default:      return "evening"
    }
  }

  private var habitsNow: [HabitDayItem] {
    let bucket = currentHabitBucket
    return model.openHabits.filter { $0.bucket == bucket }
  }

  var body: some View {
    let chores = model.openChores
    let habits = habitsNow
    let supplements = model.openSupplements

    VStack(alignment: .leading, spacing: 0) {
      if !chores.isEmpty {
        sectionHeader("Chores", icon: "list.bullet.clipboard",
                      tint: theme.color(for: "chores"))
        ForEach(chores) { chore in
          ChoreRow(chore: chore, model: model, client: client,
                   tint: theme.color(for: "chores"))
        }
      }

      if !habits.isEmpty {
        if !chores.isEmpty { Hairline().padding(.top, 8) }
        habitBucketHeader(bucket: currentHabitBucket,
                          tint: theme.color(for: "habits"))
        ForEach(habits) { habit in
          HabitRow(habit: habit, model: model, client: client,
                   tint: theme.color(for: "habits"))
        }
      }

      if !supplements.isEmpty {
        if !chores.isEmpty || !habits.isEmpty { Hairline().padding(.top, 8) }
        sectionHeader("Supplements", icon: "pills",
                      tint: theme.color(for: "supplements"))
        ForEach(supplements) { supp in
          SupplementRow(supplement: supp, model: model, client: client,
                        tint: theme.color(for: "supplements"))
        }
      }
    }
  }
}

// MARK: - Done subview (rendered after tasks-done)

struct NextDoneSection: View {
  var model: NextItemsModel
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  var body: some View {
    let chores = model.doneChores
    let habits = model.doneHabits
    let supplements = model.doneSupplements

    VStack(alignment: .leading, spacing: 0) {
      // No section headers in the done strip — keep it visually quiet.
      // Items still wear their section accent on the (filled) check. One
      // hairline between adjacent kinds rather than between every row.
      if !chores.isEmpty {
        ForEach(chores) { chore in
          ChoreRow(chore: chore, model: model, client: client,
                   tint: theme.color(for: "chores"))
        }
      }
      if !habits.isEmpty {
        if !chores.isEmpty { Hairline().padding(.top, 8) }
        ForEach(habits) { habit in
          HabitRow(habit: habit, model: model, client: client,
                   tint: theme.color(for: "habits"))
        }
      }
      if !supplements.isEmpty {
        if !chores.isEmpty || !habits.isEmpty { Hairline().padding(.top, 8) }
        ForEach(supplements) { supp in
          SupplementRow(supplement: supp, model: model, client: client,
                        tint: theme.color(for: "supplements"))
        }
      }
    }
  }
}

// MARK: - Row primitives

// Shared by NextOpenSection (current-bucket strip) and HabitsDestinationView
// (full all-day list). Internal so the Habits mini-app can reuse the same
// row instead of duplicating the swipe/toggle/skip vocabulary.
struct HabitRow: View {
  let habit: HabitDayItem
  var model: NextItemsModel
  let client: SeptenaClient
  let tint: Color

  var body: some View {
    let inactive = habit.done || habit.skipped
    HStack(spacing: 12) {
      TaskCheckbox(
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
    .padding(.vertical, Theme.rowVPadding)
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

// Shared by NextOpenSection and SupplementsDestinationView. Same toggle
// semantics as HabitRow without the skip vocab — supplements are simpler
// (taken / not taken).
struct SupplementRow: View {
  let supplement: SupplementDayItem
  var model: NextItemsModel
  let client: SeptenaClient
  let tint: Color

  var body: some View {
    HStack(spacing: 12) {
      TaskCheckbox(tint: tint, isDone: supplement.done) {
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
    .padding(.vertical, Theme.rowVPadding)
  }
}

// Shared by NextOpenSection and ChoresDestinationView. Same swipe vocab
// (Tomorrow / Weekend defer, complete on tap, overdue badge) for both
// callers; the Chores tab just shows every chore where Next shows only
// today's actionable subset.
struct ChoreRow: View {
  let chore: ChoreItem
  var model: NextItemsModel
  let client: SeptenaClient
  let tint: Color

  var body: some View {
    let isDone = model.completedChores.contains(chore.id)
    let deferLabel = model.deferredChores[chore.id]
    let inactive = isDone || deferLabel != nil

    HStack(spacing: 12) {
      TaskCheckbox(
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
    .padding(.vertical, Theme.rowVPadding)
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

// Reused across HabitRow / SupplementRow / ChoreRow for "Done" / "Skipped"
// / defer-label pills. Pulled out of private scope so the chores mini-app
// can render its own status pills inline.
struct StatusBadge: View {
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

// MARK: - Habit bucket header
//
// Same chrome as `sectionHeader`, plus a trailing "time left in this bucket"
// chip that rounds coarsely when there's plenty of slack and tightens up
// (minutes, then warm color, then red) as the cutoff approaches.

@ViewBuilder
private func habitBucketHeader(bucket: String, tint: Color) -> some View {
  HStack(spacing: 8) {
    Image(systemName: "repeat").font(.system(size: 14)).foregroundStyle(tint)
    Text("\(bucket.capitalized) Habits")
      .font(.septenaSectionTitle).foregroundStyle(Theme.inkPrimary)
    Spacer()
    BucketTimeLeft(bucket: bucket)
  }
  .padding(.horizontal, Theme.hPadding)
  .padding(.top, Theme.sectionSpacing)
  .padding(.bottom, 6)
}

/// Tiny "Xh / Xm left" chip that ticks once a minute. Same font as the
/// section title so it sits in the row's metrics; only the color changes
/// (secondary → orange → red) as we approach the bucket cutoff.
private struct BucketTimeLeft: View {
  let bucket: String

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { ctx in
      let parts = formatted(remaining: cutoff().timeIntervalSince(ctx.date))
      Text(parts.text)
        .font(.septenaSectionTitle)
        .foregroundStyle(parts.color)
        .monospacedDigit()
    }
  }

  /// End of the current habit window. Bucket boundaries mirror
  /// `NextOpenSection.currentHabitBucket`: noon, 5pm, midnight.
  private func cutoff() -> Date {
    let cal = Calendar.current
    let now = Date()
    let hour: Int
    switch bucket {
    case "morning":   hour = 12
    case "afternoon": hour = 17
    default:          hour = 24  // end of day → tomorrow 00:00
    }
    if hour == 24 {
      let startOfTomorrow = cal.date(byAdding: .day, value: 1,
                                     to: cal.startOfDay(for: now))!
      return startOfTomorrow
    }
    return cal.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
  }

  private func formatted(remaining seconds: TimeInterval) -> (text: String, color: Color) {
    let s = max(0, Int(seconds))
    let totalMin = s / 60
    let h = totalMin / 60
    let m = totalMin % 60

    let text: String
    if totalMin >= 120 {
      // Plenty of runway — coarse hours only.
      text = "\(h)h"
    } else if totalMin >= 60 {
      // Last hour-and-a-bit — show "1h 25m", rounded to 5m.
      let rounded = (m / 5) * 5
      text = rounded == 0 ? "\(h)h" : "\(h)h \(rounded)m"
    } else {
      // Under an hour — minutes, exact (this is the "more detail" zone).
      text = "\(totalMin)m"
    }

    let color: Color
    if totalMin < 15      { color = Theme.overdueRed }
    else if totalMin < 60 { color = .orange }
    else                  { color = Theme.inkSecondary }

    return (text, color)
  }
}


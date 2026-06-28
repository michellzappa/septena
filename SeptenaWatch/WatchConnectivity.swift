import CloudKit
import WidgetKit
import WatchKit

// MARK: - CloudKit constants (must match SeptenaCloudKit in the iOS target)

private let ckContainerID = "iCloud.com.septena.cloud"
private let ckZoneName    = "septena-v1"
private let ckZoneID      = CKRecordZone.ID(
  zoneName: ckZoneName,
  ownerName: CKCurrentUserDefaultName
)

// MARK: - WatchConnectivity

/// CloudKit-backed data source for the watch's Next view.
/// Reads one precomputed `WatchSnapshot` record (written by the iPhone) for the
/// list, and writes completion events straight to the `septena-v1` zone — no
/// WCSession or FastAPI dependency.
@Observable
final class WatchConnectivity {
  static let shared = WatchConnectivity()

  var items: [NextItem] = []
  /// Section key → authored color token from the snapshot, so the Next list
  /// can tint its group rules with the phone's actual section accents.
  var sectionColors: [String: String] = [:]
  /// The user's enabled intake trackers from the snapshot — the + menu offers
  /// one quick-log row per tracker, with container-aware choices.
  var intakeKinds: [IntakeKindWire] = []
  /// The user's most-eaten meals from the snapshot — the + menu offers them as
  /// one-tap re-log quick-selects (emoji + macro summary).
  var topMeals: [MealWire] = []
  /// Capture catalogs from the snapshot, each present only when its section is
  /// enabled on the phone — the + menu offers a quick-input row per non-empty
  /// catalog (mark a med taken / log a symptom / mark a grocery low).
  var medications: [MedicationWire] = []
  var symptoms: [SymptomWire] = []
  var groceries: [GroceryWire] = []
  /// Today's macro rings and this week's training rings from the snapshot, held
  /// so the in-app detail pages (the complications' tap targets) render the same
  /// phone-computed values the complications show. Empty until the first fetch /
  /// when the section is disabled.
  var nutritionRings: [ComplicationRing] = []
  var trainingRings: [ComplicationRing] = []
  /// The most-recent logged meals / training entries from the snapshot, listed
  /// under the rings on the summary pages as a freshness check (does the latest
  /// thing logged on the phone show up on the wrist?). Empty until the first
  /// fetch / when the section carried no data.
  var recentNutrition: [RecentLogWire] = []
  var recentTraining: [RecentLogWire] = []
  /// Today's per-tracker intake tally from the snapshot — "what I've had today",
  /// listed on the in-app Intakes summary page. Empty until the first fetch /
  /// when nothing's been logged today.
  var intakeToday: [IntakeTodayWire] = []
  /// The fasting context from the snapshot (last-meal anchor + target), present
  /// whenever the user tracks fasting and has a recent meal. The surfaces decide
  /// fed-vs-fasting live via `liveState(now:)` — the macro complication morphs to
  /// a fasting face when due, and the in-app Macros summary (its tap target) shows
  /// the live fast. Nil when untracked / no meal, so both fall back to macros.
  var fasting: FastingComplication? = nil
  /// Section keys enabled on the phone (from the snapshot), so the Next-list
  /// "Summaries" links show for an enabled section even on a day its ring data
  /// didn't ride along. Empty for older payloads — callers fall back to ring
  /// presence then.
  var enabledSections: Set<String> = []
  var bucket: String = ""
  var isLoading = false
  var errorMessage: String?
  /// Items tapped this session — held visible (struck through) for a beat
  /// before they fade, mirroring the iPhone's Next behaviour.
  var completedIDs: Set<String> = []

  private let db: CKDatabase
  /// The iPhone writes the snapshot to the default private zone.
  private let snapshotRecordID = CKRecord.ID(recordName: "watch-next-snapshot")

  private init() {
    db = CKContainer(identifier: ckContainerID).privateCloudDatabase
  }

  // MARK: - Local "done today" (sticky until the phone republishes)

  private let doneStore = UserDefaults.standard
  private func localDoneIDs(date: String) -> Set<String> {
    guard doneStore.string(forKey: "doneLocalDate") == date else { return [] }
    return Set(doneStore.stringArray(forKey: "doneLocalIDs") ?? [])
  }
  private func markDoneLocally(id: String, date: String) {
    if doneStore.string(forKey: "doneLocalDate") != date {
      doneStore.set(date, forKey: "doneLocalDate")
      doneStore.set([String](), forKey: "doneLocalIDs")
    }
    var ids = doneStore.stringArray(forKey: "doneLocalIDs") ?? []
    if !ids.contains(id) { ids.append(id) }
    doneStore.set(ids, forKey: "doneLocalIDs")
  }

  // MARK: - Date helpers

  private static let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  private var today: String { Self.dateFmt.string(from: Date()) }

  // Bucket selection is shared with the phone via `DayBucket` so the two
  // never disagree about which habits are due now.
  private func currentBucket() -> String { DayBucket.current.rawValue }

  // MARK: - Foreground fetch

  func fetchNext() {
    Task { await _fetch() }
  }

  func fetchInBackground() async {
    await _fetch()
  }

  /// A pending post-write reconcile, coalesced so a burst of wrist taps pulls
  /// once. See `scheduleReconcile`.
  private var reconcileTask: Task<Void, Never>?

  /// After a wrist log, the phone absorbs the event and republishes the snapshot
  /// (debounced), which can change *other* rows the log caused — e.g. logging a
  /// meal hides the "break your fast" suggestion, logging cardio hides the
  /// training one. The watch only optimistically hides the single tapped row, so
  /// without this it keeps showing the now-stale siblings until the next
  /// foreground. Pull the fresh snapshot a few seconds later to reconcile them.
  ///
  /// Coalesced (one fetch per burst) and delayed to give the phone time to
  /// absorb + republish. Safe: items logged on the wrist stay hidden via
  /// `localDoneIDs`, so a reconcile never resurrects what was just tapped — and
  /// if the phone is asleep and hasn't republished yet, the stale snapshot is no
  /// worse than before, and the next foreground fetch still catches up.
  private func scheduleReconcile() {
    reconcileTask?.cancel()
    reconcileTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 6_000_000_000)   // 6s: phone absorb + republish
      guard !Task.isCancelled else { return }
      await self?._fetch()
    }
  }

  @MainActor
  private func _fetch() async {
    isLoading = true
    errorMessage = nil

    do {
      let bkt = currentBucket()

      // Confirm CloudKit has a usable account first — otherwise the read can
      // block indefinitely with no feedback.
      let container = CKContainer(identifier: ckContainerID)
      let status = try await container.accountStatus()
      guard status == .available else {
        errorMessage = "iCloud not available on watch (status: \(accountStatusLabel(status)))"
        isLoading = false
        return
      }

      // One O(1) read: the iPhone precomputes the whole day's open checklist
      // into a single `WatchSnapshot` record (default zone). No zone replay.
      // Timed out so a stall surfaces as an error, never an endless spinner.
      let record = try await withTimeout(seconds: 15) { [self] in
        try await db.record(for: snapshotRecordID)
      }
      guard
        let payload  = record["payload"] as? Data,
        let response = try? JSONDecoder().decode(NextItemsResponse.self, from: payload)
      else {
        errorMessage = "Couldn't read the watch snapshot. Open Septena on your iPhone."
        isLoading = false
        return
      }

      // Sync the phone's bucket cutoffs into the watch's own app-group store so
      // DayBucket.current uses the same morning/afternoon/evening boundaries the
      // phone does. The phone's saveCutoffs() write goes to the phone's app-group
      // container, which is separate from the watch's — without this the watch
      // always uses factory defaults (morning < 12, afternoon < 17) regardless of
      // what the user set in Settings, causing bucket transitions to feel early.
      if let m = response.morningCutoff, let a = response.afternoonCutoff {
        DayBucket.saveCutoffs(DayBucketCutoffs(morningEnd: m, afternoonEnd: a))
      }
      // Narrow to the current time-of-day bucket via the shared helper (keeps
      // the watch and the iOS widget from ever disagreeing), then drop items
      // completed locally this session until the phone republishes.
      let doneLocal = localDoneIDs(date: today)
      let filtered = response.itemsForBucket(DayBucket.current)
        .filter { !doneLocal.contains($0.id) }

      self.items         = filtered
      self.sectionColors = response.sectionColors ?? [:]
      self.intakeKinds   = response.intakeKinds ?? []
      self.topMeals      = response.topMeals ?? []
      self.medications   = response.medications ?? []
      self.symptoms      = response.symptoms ?? []
      self.groceries     = response.groceries ?? []
      self.enabledSections = Set(response.enabledSections ?? [])
      self.recentNutrition = response.recentNutrition ?? []
      self.recentTraining  = response.recentTraining ?? []
      self.intakeToday     = response.intakeToday ?? []
      self.bucket        = bkt
      updateComplication()
      updateMacroComplication(response.nutritionRings, fasting: response.fasting)
      updateTrainingComplication(response.trainingRings)
      scheduleNextRefresh()
    } catch is CancellationError {
      // A newer fetch superseded this one — most often a burst of wrist taps,
      // each of which schedules a reconcile that cancels the in-flight fetch
      // (see `scheduleReconcile`). That is not a user-facing failure: leave the
      // current list untouched and just stop the spinner. Surfacing it (as the
      // catch-all once did) blanked the whole Next list with a bogus
      // "Swift.CancellationError error 1" screen on rapid tapping.
    } catch let ckError as CKError where ckError.code == .operationCancelled {
      // CloudKit reports task cancellation as `.operationCancelled` — same
      // benign supersede case as above; don't show it.
    } catch let ckError as CKError where ckError.code == .unknownItem {
      errorMessage = "No data yet. Open Septena on your iPhone to sync your watch."
    } catch {
      errorMessage = error.localizedDescription
    }

    isLoading = false
  }

  // MARK: - Helpers

  private func accountStatusLabel(_ status: CKAccountStatus) -> String {
    switch status {
    case .available:                    return "available"
    case .noAccount:                    return "no iCloud account"
    case .restricted:                   return "restricted"
    case .couldNotDetermine:            return "could not determine"
    case .temporarilyUnavailable:       return "temporarily unavailable"
    @unknown default:                   return "unknown (\(status.rawValue))"
    }
  }

  /// Races an async operation against a timeout so a hung CloudKit call
  /// surfaces as a visible error instead of an infinite spinner.
  private func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw NSError(
          domain: "SeptenaWatch", code: -1000,
          userInfo: [NSLocalizedDescriptionKey:
            "Timed out after \(Int(seconds))s — CloudKit didn't respond"]
        )
      }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      group.cancelAll()
      return result
    }
  }

  // MARK: - Mutations

  func complete(_ item: NextItem) {
    // Completable kinds are defined once in `NextBlocks` (shared with the
    // phone). This naturally excludes read-only suggestions and anything
    // that isn't a Next member.
    guard NextBlocks.isCompletable(kind: item.kind) else { return }
    guard !completedIDs.contains(item.id) else { return }   // ignore double taps
    let date = today

    // Confirm with a success haptic, mark it done, and keep it on screen
    // (struck through) for a moment before it fades out. One uniform "done"
    // feel for every completable kind — on the wrist, eyes-off, a per-section
    // rhythm reads as noise, not signal.
    WKInterfaceDevice.current().play(.success)
    completedIDs.insert(item.id)
    markDoneLocally(id: item.id, date: date)   // stays hidden across refreshes
    updateComplication()

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      items.removeAll { $0.id == item.id }
      completedIDs.remove(item.id)
    }

    Task {
      do {
        // Route off the shared `NextBlocks` descriptor: it declares the
        // completion strategy per member, so the *set* of completable kinds
        // lives in one place. The per-record writers stay bespoke (each
        // event record has different fields).
        guard let block = NextBlocks.byItemKind[item.kind] else { return }
        switch block.completion {
        case .recordStatus:
          try await saveTaskCompletion(taskID: item.id)
        case .event(let recordType):
          try await saveEvent(recordType: recordType, itemID: item.id, date: date)
        }
      } catch {
        // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
      }
    }
    scheduleReconcile()   // pull the phone's republished snapshot once it lands
  }

  // MARK: - Task row actions (cancel / off-today)

  /// Cancel a task from its long-press drawer. Task-only (the phone's cancel is
  /// task-only); `finishSuggestion` gives the same optimistic hide + haptic +
  /// reconcile as completion.
  func cancelTask(_ item: NextItem) {
    guard item.kind == "task" else { return }
    finishSuggestion(item.id)
    Task {
      do { try await saveTaskCancel(taskID: item.id) }
      catch { /* fire-and-forget; iOS reconciles on next open */ }
    }
  }

  /// Drop a task off Today from its long-press drawer — the watch's defer: it
  /// leaves the task open but removes it from the Today feed.
  func offTodayTask(_ item: NextItem) {
    guard item.kind == "task" else { return }
    finishSuggestion(item.id)
    Task {
      do { try await saveTaskOffToday(taskID: item.id) }
      catch { }
    }
  }

  /// Skip a habit / supplement for today from its long-press drawer — mirrors
  /// the phone's `skipHabit` / `skipSupplement`: writes the day event with
  /// done=0, skipped=1. Same optimistic hide + haptic + reconcile as completion.
  func skipItem(_ item: NextItem) {
    guard item.kind == "habit" || item.kind == "supplement" else { return }
    finishSuggestion(item.id)
    let date = today
    Task {
      do {
        switch item.kind {
        case "habit":      try await saveHabitSkip(habitID: item.id, date: date)
        case "supplement": try await saveSupplementSkip(supplementID: item.id, date: date)
        default: break
        }
      } catch { }
    }
  }

  /// Skip a suggestion for today — the phone's single suggestion action. Mirrors
  /// `NextSuggestionsModel.toggleSkip`: appends the id to the synced Settings
  /// blob's `next_skips[today]`, so the skip propagates to the phone (and back)
  /// exactly 1:1. Optimistic local hide first; the CloudKit write is
  /// fire-and-forget and oplock-guarded (see `saveSuggestionSkip`).
  func skipSuggestion(_ item: NextItem) {
    guard item.kind == "suggestion" else { return }
    finishSuggestion(item.id)
    let date = today
    Task {
      do { try await saveSuggestionSkip(itemID: item.id, date: date) }
      catch { /* offline or a concurrent settings write rejected us; the nudge
                 is hidden locally and a later skip re-pushes. */ }
    }
  }

  /// Defer a chore from its long-press drawer — mirrors the phone's
  /// `deferChore(mode:from:)`: writes a `ChoreEvent` with action "defer" and the
  /// computed `newDueDate`, then hides the row optimistically until reconcile.
  func deferChore(_ item: NextItem, mode: String) {
    guard item.kind == "chore" else { return }
    finishSuggestion(item.id)
    let date = today
    Task {
      do { try await saveChoreDefer(choreID: item.id, mode: mode, date: date) }
      catch { }
    }
  }

  // MARK: - Quick-log (actionable suggestions)

  /// Log a `.choice`-input suggestion (hydration / gut) with the picked value.
  /// Optimistic: hides the nudge with a success haptic, then writes the event
  /// off the `SuggestionBlocks` descriptor (shared with the phone).
  func logChoice(kind: String, value: String, itemID: String) {
    guard let block = SuggestionBlocks.byKind[kind] else { return }
    finishSuggestion(itemID)
    let date = today
    Task {
      do {
        switch block.recordType {
        case "NutritionEntry":
          // hydration: the choice value is millilitres of water.
          if let ml = Double(value) { try await saveWaterEntry(ml: ml) }
        case "GutEvent":
          // gut: the choice value is the Bristol type (1–7).
          if let bristol = Int(value) { try await saveGutEvent(bristol: bristol, date: date) }
        default:
          assertionFailure("No watch quick-log writer for '\(block.recordType)'")
        }
      } catch {
        // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
      }
    }
  }

  /// Log against an intake tracker from the wire. `value` is a
  /// `ConsumableContainer` choice token ("<method>:N" / bare method), so a
  /// wrist log lands in the current container exactly like the phone's
  /// Continue / New container rows.
  func logIntake(kind: IntakeKindWire, value: String, itemID: String) {
    finishSuggestion(itemID)
    let date = today
    Task {
      do {
        try await saveIntakeEvent(kind: kind, value: value, date: date)
      } catch {
        // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
      }
    }
  }

  /// Log a mood check-in from the two-step picker (quadrant → emotion). Writes
  /// a real `MoodEvent` at the chosen emotion's `MoodVocabulary` coordinates.
  func logMood(quadrant: String, emotion: String, arousal: Int, valence: Int, itemID: String) {
    finishSuggestion(itemID)
    let date = today
    Task {
      do {
        try await saveMoodEvent(quadrant: quadrant, emotion: emotion,
                                arousal: arousal, valence: valence, date: date)
      } catch { }
    }
  }

  /// Re-log one of the user's meals from the wrist — writes a full
  /// `NutritionEntry` (foods + macros), mirroring the phone's `logAgainNow`.
  /// A plain quick-log, not a suggestion: the confirming haptic fires here and
  /// the picker dismisses itself, so there's no Next row to optimistically hide.
  func logMeal(_ meal: MealWire) {
    WKInterfaceDevice.current().play(.success)
    Task {
      do { try await saveMealEntry(meal) }
      catch { }   // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
    }
    scheduleReconcile()   // a new meal can hide the "break your fast" suggestion
  }

  /// Mark a dose of a medication taken from the wrist — writes a "taken"
  /// `MedicationDoseEvent`, mirroring `MedicationsMutator.addDose`. A plain
  /// quick-log (no Next row to hide); the confirming haptic fires here and the
  /// picker dismisses itself.
  func logMedication(_ med: MedicationWire) {
    WKInterfaceDevice.current().play(.success)
    let date = today
    Task {
      do { try await saveMedicationDose(medicationID: med.id, date: date) }
      catch { }   // Fire-and-forget: the iOS CKSyncEngine reconciles on next open.
    }
  }

  /// Log a symptom at a chosen severity from the wrist — writes a `SymptomEvent`,
  /// mirroring `SymptomsMutator.addEvent`. Severity is the phone's 0–10 scale
  /// (the picker offers Mild/Moderate/Severe = 3/5/8, matching the phone's
  /// quick-add menu).
  func logSymptom(_ symptom: SymptomWire, severity: Int) {
    WKInterfaceDevice.current().play(.success)
    let date = today
    Task {
      do { try await saveSymptomEvent(symptomID: symptom.id, severity: severity, date: date) }
      catch { }
    }
  }

  /// Mark a grocery item low ("we ran out") from the wrist — mutates the existing
  /// `GroceryItem` record in place (low → 1), mirroring `GroceryMutator.setLow`.
  /// Optimistically drops it from the in-stock list so the menu reflects the tap
  /// at once; the phone republishes the trimmed list on absorb.
  func markGroceryLow(_ item: GroceryWire) {
    WKInterfaceDevice.current().play(.success)
    groceries.removeAll { $0.id == item.id }
    Task {
      do { try await saveGroceryLow(itemID: item.id) }
      catch { }
    }
    scheduleReconcile()
  }

  /// Shared optimistic hide for a just-logged suggestion: success haptic, mark
  /// it done locally (so it stays hidden across refreshes), then drop it from
  /// the list after the settle beat. Mirrors `complete()` without the
  /// `NextBlocks` completion path — suggestions aren't completable members.
  private func finishSuggestion(_ itemID: String) {
    guard !completedIDs.contains(itemID) else { return }
    let date = today
    WKInterfaceDevice.current().play(.success)
    completedIDs.insert(itemID)
    markDoneLocally(id: itemID, date: date)
    updateComplication()
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      items.removeAll { $0.id == itemID }
      completedIDs.remove(itemID)
    }
    scheduleReconcile()   // pull the phone's republished snapshot once it lands
  }

  /// Maps a `NextBlocks`-declared event record type to its CloudKit writer.
  /// The writers stay separate because each event record has different
  /// fields; this only routes, so adding a member is a `NextBlocks` row plus
  /// (when it's a new record type) one writer here.
  private func saveEvent(recordType: String, itemID: String, date: String) async throws {
    switch recordType {
    case "HabitEvent":      try await saveHabitEvent(habitID: itemID, date: date)
    case "SupplementEvent": try await saveSupplementEvent(supplementID: itemID, date: date)
    case "ChoreEvent":      try await saveChoreEvent(choreID: itemID, date: date)
    default:
      assertionFailure("No watch writer for NextBlocks record type '\(recordType)'")
    }
  }

  // MARK: - CloudKit write helpers

  private func saveHabitEvent(habitID: String, date: String) async throws {
    // Record name mirrors HabitEventCloudKitSchema.recordName(for:) on iOS.
    let entityID   = "habit:\(date):\(habitID)"
    let recordID   = CKRecord.ID(recordName: "habit-event:\(entityID)", zoneID: ckZoneID)
    let existing   = try? await db.record(for: recordID)
    let record     = existing ?? CKRecord(recordType: "HabitEvent", recordID: recordID)
    let now = Date()
    record["date"]       = date
    record["habitID"]    = habitID
    record["done"]       = 1
    record["skipped"]    = 0
    record["time"]       = Self.timeFmt.string(from: now)
    record["occurredAt"] = now
    try await db.save(record)
  }

  private func saveSupplementEvent(supplementID: String, date: String) async throws {
    let entityID = "supplement:\(date):\(supplementID)"
    let recordID = CKRecord.ID(recordName: "supplement-event:\(entityID)", zoneID: ckZoneID)
    let existing = try? await db.record(for: recordID)
    let record   = existing ?? CKRecord(recordType: "SupplementEvent", recordID: recordID)
    let now = Date()
    record["date"]         = date
    record["supplementID"] = supplementID
    record["done"]         = 1
    record["time"]         = Self.timeFmt.string(from: now)
    record["occurredAt"]   = now
    try await db.save(record)
  }

  /// Skip a habit for today — mirrors `saveHabitEvent` but done=0, skipped=1
  /// (the phone's `setHabitState(done:false, skipped:true)`). Upserts the same
  /// day-keyed record so a skip and a later complete don't collide.
  private func saveHabitSkip(habitID: String, date: String) async throws {
    let entityID = "habit:\(date):\(habitID)"
    let recordID = CKRecord.ID(recordName: "habit-event:\(entityID)", zoneID: ckZoneID)
    let existing = try? await db.record(for: recordID)
    let record   = existing ?? CKRecord(recordType: "HabitEvent", recordID: recordID)
    let now = Date()
    record["date"]       = date
    record["habitID"]    = habitID
    record["done"]       = 0
    record["skipped"]    = 1
    record["time"]       = Self.timeFmt.string(from: now)
    record["occurredAt"] = now
    try await db.save(record)
  }

  /// Skip a supplement for today — mirrors `saveSupplementEvent` but done=0,
  /// skipped=1 (the phone's `setSupplementState(done:false, skipped:true)`).
  private func saveSupplementSkip(supplementID: String, date: String) async throws {
    let entityID = "supplement:\(date):\(supplementID)"
    let recordID = CKRecord.ID(recordName: "supplement-event:\(entityID)", zoneID: ckZoneID)
    let existing = try? await db.record(for: recordID)
    let record   = existing ?? CKRecord(recordType: "SupplementEvent", recordID: recordID)
    let now = Date()
    record["date"]         = date
    record["supplementID"] = supplementID
    record["done"]         = 0
    record["skipped"]      = 1
    record["time"]         = Self.timeFmt.string(from: now)
    record["occurredAt"]   = now
    try await db.save(record)
  }

  /// Append a suggestion id to the synced `Settings` singleton's
  /// `next_skips[date]`, mirroring the phone's `pushSkipsToSettings`. We FETCH
  /// the live record first so the save is change-tag oplocked: if the phone
  /// changed settings since our read, CloudKit rejects this save (caught above)
  /// rather than clobbering it. The JSON is edited surgically — every other
  /// settings field is preserved untouched — and `next_skips` is pruned to today
  /// only (matching the phone) to keep the payload small.
  private func saveSuggestionSkip(itemID: String, date: String) async throws {
    let recordID = CKRecord.ID(recordName: "app", zoneID: ckZoneID)
    let record = (try? await db.record(for: recordID))
      ?? CKRecord(recordType: "Settings", recordID: recordID)

    var root: [String: Any] = {
      guard let json = record["payloadJSON"] as? String,
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return [:] }
      return obj
    }()

    // Read today's existing skips, append ours, and write back only today's
    // list — the phone prunes stale dates the same way.
    var ids: [String] = []
    if let raw = root["next_skips"] as? [String: Any],
       let arr = raw[date] as? [Any] {
      ids = arr.compactMap { $0 as? String }
    }
    guard !ids.contains(itemID) else { return }   // already skipped
    ids.append(itemID)
    root["next_skips"] = [date: ids]

    let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    record["payloadJSON"] = String(decoding: data, as: UTF8.self)
    record["updatedAt"]   = ISO8601DateFormatter().string(from: Date())
    try await db.save(record)
  }

  private func saveChoreEvent(choreID: String, date: String) async throws {
    // Each completion is a new event record; UUID avoids ID collisions.
    let eventID  = UUID().uuidString
    let recordID = CKRecord.ID(recordName: "chore-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "ChoreEvent", recordID: recordID)
    let now = Date()
    record["choreID"]    = choreID
    record["action"]     = "complete"
    record["date"]       = date
    record["time"]       = Self.timeFmt.string(from: now)
    record["occurredAt"] = now
    record["sortKey"]    = "\(date)::\(eventID)"
    try await db.save(record)
  }

  /// Defer a chore — mirrors `ChecklistMutator.deferChore` / the phone's
  /// `ChoreEventEntity` with action "defer".
  private func saveChoreDefer(choreID: String, mode: String, date: String) async throws {
    let eventID  = UUID().uuidString
    let recordID = CKRecord.ID(recordName: "chore-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "ChoreEvent", recordID: recordID)
    let now = Date()
    record["choreID"]    = choreID
    record["action"]     = "defer"
    record["date"]       = date
    record["reason"]     = mode
    if let newDue = Self.deferredDueDate(mode: mode, from: date) {
      record["newDueDate"] = newDue
    }
    record["note"]       = ""
    record["occurredAt"] = now
    record["sortKey"]    = "\(date)::\(eventID)"
    try await db.save(record)
  }

  /// Same weekend / tomorrow math as `ChecklistMutator.deferredDueDate` on iOS.
  private static func deferredDueDate(mode: String, from date: String) -> String? {
    guard let base = dateFmt.date(from: date) else { return nil }
    let calendar = Calendar.current
    switch mode {
    case "day":
      return calendar.date(byAdding: .day, value: 1, to: base).map { dateFmt.string(from: $0) }
    case "weekend":
      let weekday = calendar.component(.weekday, from: base)
      let saturday = 7
      let delta = ((saturday - weekday + 7) % 7 == 0) ? 7 : ((saturday - weekday + 7) % 7)
      return calendar.date(byAdding: .day, value: delta, to: base).map { dateFmt.string(from: $0) }
    default:
      return nil
    }
  }

  // MARK: - Task capture

  /// Quick-capture a task to the Inbox (no project/area, not Today), written
  /// straight to the `Task` record type the phone mirrors. Inbox tasks don't
  /// surface in the watch's today-scoped Next list, so there's nothing to
  /// insert locally — a success haptic confirms the write was queued; the
  /// iOS `CKSyncEngine` reconciles it into the Inbox on next fetch.
  func addInboxTask(title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    WKInterfaceDevice.current().play(.success)
    let date = today
    Task {
      do { try await saveInboxTask(title: trimmed, date: date) }
      catch { }
    }
  }

  /// Writes a fresh open `Task` record. Field names/values mirror
  /// `TaskCloudKitSchema` + `TasksBackend.create`: status "open", `created`
  /// today, `today` 0, app provenance. No area/project ⇒ Inbox.
  private func saveInboxTask(title: String, date: String) async throws {
    let id       = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: id, zoneID: ckZoneID)
    let record   = CKRecord(recordType: "Task", recordID: recordID)
    record["title"]        = title
    record["status"]       = "open"
    record["created"]      = date
    record["today"]        = 0
    record["source"]       = "app"
    record["sourceClient"] = "watch"
    record["createdAt"]    = Date()
    try await db.save(record)
  }

  // MARK: - Quick-log CloudKit writers
  //
  // Each suggestion log is a fresh event record (UUID id), mirroring the
  // phone's mutators: time-of-day lives in `occurredAt` (the phone derives the
  // display time from it and does NOT store a separate `time` field), and the
  // free-form `note` is written empty so the field registers. Record names +
  // fields match the `*CloudKitSchema` definitions so the phone mirrors them.

  /// One intake event against a tracker. Record name + fields match
  /// `IntakeEventCloudKitSchema` so the phone mirrors it like its own writes.
  /// Amount rides along only when the kind tracks amounts and the method has a
  /// default — the wrist never asks for a number.
  private func saveIntakeEvent(kind: IntakeKindWire, value: String, date: String) async throws {
    let (method, count) = ConsumableContainer.parse(value: value)
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "intake-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "IntakeEvent", recordID: recordID)
    record["kindID"]     = kind.id
    record["date"]       = date
    record["method"]     = method
    record["note"]       = ""
    record["occurredAt"] = Date()
    if let count { record["count"] = count }
    if kind.showsAmount == true,
       let amount = kind.methods.first(where: { $0.token == method })?.defaultAmount {
      record["amount"] = amount
    }
    try await db.save(record)
  }

  /// A water log — a macro-free `NutritionEntry`. Mirrors the phone's hydration
  /// quick-actions (`PlatformDelegates` / `HydrationIntents`): emoji 💧, the
  /// `["Water"]` foods marker (stored as the single line "Water"), zero macros,
  /// and the amount in `waterMl`. Time-of-day lives in `loggedAt`.
  private func saveWaterEntry(ml: Double) async throws {
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "nutrition-entry:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "NutritionEntry", recordID: recordID)
    record["loggedAt"] = Date()
    record["emoji"]    = "💧"
    record["foods"]    = "Water"   // the phone's HydrationPlugin.waterFoodsMarker
    record["note"]     = ""
    record["source"]   = "manual"
    record["proteinG"] = 0
    record["fatG"]     = 0
    record["carbsG"]   = 0
    record["waterMl"]  = ml
    try await db.save(record)
  }

  /// A full meal log — a `NutritionEntry` carrying the re-logged meal's foods
  /// and macros. Mirrors the phone's `NutritionMutator.addEntry`: foods are
  /// newline-joined, optional nutrients ride along only when present, and
  /// time-of-day lives in `loggedAt`. A fresh UUID id so each re-log is its own
  /// event. Field names match `NutritionEntryCloudKitSchema` so the phone
  /// mirrors it like its own writes.
  private func saveMealEntry(_ meal: MealWire) async throws {
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "nutrition-entry:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "NutritionEntry", recordID: recordID)
    record["loggedAt"] = Date()
    if let emoji = meal.emoji, !emoji.isEmpty { record["emoji"] = emoji }
    record["foods"]    = meal.foods.joined(separator: "\n")
    record["note"]     = ""
    record["source"]   = "manual"
    record["proteinG"] = meal.proteinG
    record["fatG"]     = meal.fatG
    record["carbsG"]   = meal.carbsG
    if meal.kcal > 0 { record["kcal"] = meal.kcal }
    if let v = meal.fiberG { record["fiberG"] = v }
    if let v = meal.sugarG { record["sugarG"] = v }
    if let v = meal.saturatedFatG { record["saturatedFatG"] = v }
    if let v = meal.alcoholG { record["alcoholG"] = v }
    if let v = meal.sodiumMg { record["sodiumMg"] = v }
    if let v = meal.cholesterolMg { record["cholesterolMg"] = v }
    if let v = meal.potassiumMg { record["potassiumMg"] = v }
    try await db.save(record)
  }

  /// A medication dose taken. Record name + fields match
  /// `MedicationDoseEventCloudKitSchema` (record type "MedicationDoseEvent",
  /// name "medication-dose-event:{uuid}") so the phone mirrors it like its own
  /// write. Status "taken", source manual; time-of-day rides `occurredAt`.
  private func saveMedicationDose(medicationID: String, date: String) async throws {
    let eventID  = UUID().uuidString.lowercased()
    let recordID = CKRecord.ID(recordName: "medication-dose-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "MedicationDoseEvent", recordID: recordID)
    record["date"]         = date
    record["medicationID"] = medicationID
    record["status"]       = "taken"
    record["source"]       = "manual"
    record["occurredAt"]   = Date()
    try await db.save(record)
  }

  /// A symptom logged at a severity. Record name + fields match
  /// `SymptomEventCloudKitSchema` (record type "SymptomEvent", name
  /// "symptom-event:{uuid}"). Severity is the phone's 0–10 scale; time-of-day
  /// rides `occurredAt`.
  private func saveSymptomEvent(symptomID: String, severity: Int, date: String) async throws {
    let eventID  = UUID().uuidString.lowercased()
    let recordID = CKRecord.ID(recordName: "symptom-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "SymptomEvent", recordID: recordID)
    record["date"]       = date
    record["symptomID"]  = symptomID
    record["severity"]   = severity
    record["source"]     = "manual"
    record["occurredAt"] = Date()
    try await db.save(record)
  }

  /// Marks a grocery item low by mutating its `GroceryItem` record in place —
  /// mirrors `GroceryMutator.setLow(low: true)`: set `low` 1, leave `lastBought`
  /// (only a "bought" stamps that). Fetches the existing record so system fields
  /// and the item's other attributes round-trip untouched.
  private func saveGroceryLow(itemID: String) async throws {
    let recordID = CKRecord.ID(recordName: "grocery-item:\(itemID)", zoneID: ckZoneID)
    guard let record = try? await db.record(for: recordID) else { return }
    record["low"] = 1
    try await db.save(record)
  }

  private func saveGutEvent(bristol: Int, date: String) async throws {
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "gut-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "GutEvent", recordID: recordID)
    record["date"]       = date
    record["bristol"]    = bristol
    record["note"]       = ""
    record["occurredAt"] = Date()
    try await db.save(record)
  }

  private func saveMoodEvent(quadrant: String, emotion: String,
                             arousal: Int, valence: Int, date: String) async throws {
    let eventID  = String(UUID().uuidString.lowercased().prefix(8))
    let recordID = CKRecord.ID(recordName: "mood-event:\(eventID)", zoneID: ckZoneID)
    let record   = CKRecord(recordType: "MoodEvent", recordID: recordID)
    record["date"]       = date
    record["bucket"]     = DayBucket.current.rawValue
    record["quadrant"]   = quadrant
    record["arousal"]    = arousal
    record["valence"]    = valence
    record["emotion"]    = emotion
    record["note"]       = ""
    record["occurredAt"] = Date()
    try await db.save(record)
  }

  /// Completes a task by mutating its `Task` record in place — mirrors
  /// `TasksBackend.complete`: status → done, stamp completedAt, clear today.
  private func saveTaskCompletion(taskID: String) async throws {
    let recordID = CKRecord.ID(recordName: taskID, zoneID: ckZoneID)
    guard let record = try? await db.record(for: recordID) else { return }
    record["status"]      = "done"
    record["completedAt"] = Self.tsFmt.string(from: Date())
    record["today"]       = 0
    try await db.save(record)
  }

  /// Cancels a task — mirrors `TasksBackend.cancel`: status → cancelled, stamp
  /// completedAt. Writes the `Task` record in place; iOS reconciles on next open.
  private func saveTaskCancel(taskID: String) async throws {
    let recordID = CKRecord.ID(recordName: taskID, zoneID: ckZoneID)
    guard let record = try? await db.record(for: recordID) else { return }
    record["status"]      = "cancelled"
    record["completedAt"] = Self.tsFmt.string(from: Date())
    record["today"]       = 0
    try await db.save(record)
  }

  /// Drops a task off Today — mirrors `TasksBackend.removeFromToday`: clear the
  /// `today` flag + `todaySetOn`, plus a `scheduled` date that has already
  /// landed (a future "When" date is left intact so the task re-surfaces on its
  /// day). A live deadline is intentionally left alone — it's a real commitment.
  private func saveTaskOffToday(taskID: String) async throws {
    let recordID = CKRecord.ID(recordName: taskID, zoneID: ckZoneID)
    guard let record = try? await db.record(for: recordID) else { return }
    record["today"]      = 0
    record["todaySetOn"] = nil
    if let scheduled = record["scheduled"] as? String, scheduled <= today {
      record["scheduled"] = nil
    }
    try await db.save(record)
  }

  private static let tsFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Wall-clock "HH:mm" of the completion, mirroring `currentTimeString()` in
  /// the iOS `ChecklistMutator` so a watch-logged item carries the same
  /// time-of-day the phone would have written.
  private static let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  // MARK: - Complication

  private func updateComplication() {
    NextComplicationData(
      bucket: bucket,
      remaining: items.count,
      firstTitle: items.first?.title,
      updatedAt: Date()
    ).save()
    WidgetCenter.shared.reloadTimelines(ofKind: "SeptenaNext")
  }

  /// Mirror the phone-computed macro totals (and the live fast, if any) into the
  /// app group and refresh the macro-ring complication. The snapshot is the only
  /// source — these are phone-computed (goals, daily totals, and the fasting
  /// state machine all live there), so unlike the Next count there's nothing to
  /// update on a local wrist log. When a fast rides along, the complication
  /// morphs into a fasting face instead of drawing the rings.
  private func updateMacroComplication(_ wire: NutritionRingsWire?, fasting wire2: FastingWire?) {
    let rings = (wire?.rings ?? []).map {
      ComplicationRing(key: $0.key, value: $0.value, goal: $0.goal, colorHex: $0.colorHex)
    }
    let fast = wire2.map {
      FastingComplication(lastMealAt: $0.lastMealAt, sinceLabel: $0.sinceLabel,
                          targetHours: $0.targetHours, colorHex: $0.colorHex)
    }
    nutritionRings = rings   // held for the in-app detail page (complication tap target)
    fasting = fast           // held for the in-app page + the fasting-face morph
    MacroComplicationData(rings: rings, updatedAt: Date(), fasting: fast).save()
    WidgetCenter.shared.reloadTimelines(ofKind: "SeptenaMacroRings")
  }

  /// Mirror this week's phone-computed training totals into the app group and
  /// refresh the training-ring complication. Phone-computed like the macro
  /// rings — nothing to update on a local wrist log.
  private func updateTrainingComplication(_ wire: TrainingRingsWire?) {
    let rings = (wire?.rings ?? []).map {
      ComplicationRing(key: $0.key, value: $0.value, goal: $0.goal, colorHex: $0.colorHex)
    }
    trainingRings = rings   // held for the in-app detail page (complication tap target)
    TrainingComplicationData(rings: rings, updatedAt: Date()).save()
    WidgetCenter.shared.reloadTimelines(ofKind: "SeptenaTraining")
  }
}

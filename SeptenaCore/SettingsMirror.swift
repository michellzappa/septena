import Foundation
import SwiftData

@MainActor
enum SettingsMirror {
  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  /// Accent palette for auto-coloring a section the first time it's enabled,
  /// so a freshly onboarded dashboard isn't a wall of neutral gray. Mirrors the
  /// bright row of the app's `sectionPalette` (Tailwind-500); kept here as raw
  /// hex so UI-free SeptenaCore can assign without reaching into the app layer.
  static let autoAccentPalette: [String] = [
    "#ef4444", "#f97316", "#f59e0b", "#eab308", "#84cc16", "#22c55e",
    "#10b981", "#14b8a6", "#06b6d4", "#0ea5e9", "#3b82f6", "#6366f1",
    "#8b5cf6", "#a855f7", "#ec4899", "#f43f5e",
  ]

  /// Give a section a palette accent the first time it's enabled. No-op once it
  /// has any color (a real user pick, or a prior auto-assignment), so it never
  /// overrides a choice. Prefers a hue not already used by another section so
  /// enabled tiles stay visually distinct; falls back to a random palette hue
  /// once every one is taken. Caller saves the context.
  static func assignAutoColorIfNeeded(_ entity: SectionEntity, context: ModelContext) {
    guard entity.color.isEmpty else { return }
    let used = Set(((try? context.fetch(FetchDescriptor<SectionEntity>())) ?? [])
      .map { $0.color.lowercased() }
      .filter { !$0.isEmpty })
    let free = autoAccentPalette.filter { !used.contains($0.lowercased()) }
    if let pick = (free.isEmpty ? autoAccentPalette : free).randomElement() {
      entity.color = pick
    }
  }

  // `nonisolated`: a pure context read, so `DashboardReader` can pull
  // settings on its background context off-main. Uses a local decoder
  // rather than the enum's `@MainActor` shared one (the write methods here
  // genuinely need main — they push through CKEngine — so the enum stays
  // `@MainActor` and only this read opts out).
  nonisolated static func loadSettings(context: ModelContext) -> AppSettings? {
    let singletonID = SettingsCloudKitSchema.singletonID
    let descriptor = FetchDescriptor<SettingsEntity>(
      predicate: #Predicate { $0.id == singletonID }
    )
    guard let entity = try? context.fetch(descriptor).first else { return nil }
    return try? JSONDecoder().decode(AppSettings.self, from: entity.payloadData)
  }

  // `nonisolated`: a pure context read (mirrors `loadSettings`), so the Next
  // suggestions scorer can resolve enabled sections on a background context
  // off-main. No writes, so it's safe to opt out of the enum's `@MainActor`.
  nonisolated static func loadSections(context: ModelContext) -> [SectionConfig] {
    let descriptor = FetchDescriptor<SectionEntity>()
    let rows = (try? context.fetch(descriptor)) ?? []
    let settings = loadSettings(context: context)
    let order = settings?.sectionOrder ?? []
    let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })

    // Drop SectionEntity rows whose key isn't in the current manifest.
    // These are orphans from prior schemas (e.g. "brief", "next") that
    // CloudKit still has lying around — the manifest is the source of
    // truth for which sections the app surfaces today.
    let knownKeys = Set(SectionManifest.byKey.keys)

    return rows
      .filter { knownKeys.contains($0.id) }
      .sorted { lhs, rhs in
        let lhsRank = rank[lhs.id]
        let rhsRank = rank[rhs.id]
        switch (lhsRank, rhsRank) {
        case let (l?, r?):
          return l < r
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
      }
      .map(SectionConfig.init)
  }

  /// Insert a SectionEntity for a manifest key if it isn't already in
  /// the local store. Used at startup to backfill sections that were
  /// added to `SectionManifest` after the user's CloudKit `SectionEntity`
  /// set was last synced — without this, a newly-shipped section would
  /// stay invisible on the dashboard until manual install UX exists.
  ///
  /// `title` / `color` / `isEnabled` are pulled from the manifest's
  /// defaults so the row matches the catalog. `hasOnboarded` mirrors
  /// `isEnabled` at seed time: a section seeded enabled is already
  /// "set up" (no onboarding to run); a section seeded disabled awaits
  /// first-enable, at which point the toggle flow asks the plugin
  /// whether onboarding is required.
  /// Whether the account shows any sign of prior use — synced settings, section
  /// customizations, or life-data rows. A truly fresh account has none of these;
  /// a reinstall / new device does once the first CloudKit pull lands (even if
  /// section rows arrive in a later batch than tasks). Used to avoid treating
  /// an empty local store as a blank-slate fresh account.
  nonisolated static func accountHasExistingContent(context: ModelContext) -> Bool {
    if let settings = loadSettings(context: context) {
      if settings.onboardedAt != nil { return true }
      if !(settings.sectionOrder?.isEmpty ?? true) { return true }
      if !(settings.welcomeName?.isEmpty ?? true) { return true }
    }
    if let rows = try? context.fetch(FetchDescriptor<SectionEntity>()),
       rows.contains(where: { $0.isEnabled || $0.hasOnboarded || !$0.color.isEmpty }) {
      return true
    }
    func any<T: PersistentModel>(_ type: T.Type) -> Bool {
      var d = FetchDescriptor<T>()
      d.fetchLimit = 1
      return ((try? context.fetchCount(d)) ?? 0) > 0
    }
    return any(TaskEntity.self)
      || any(HabitDefinitionEntity.self)
      || any(SupplementDefinitionEntity.self)
      || any(GoalEntity.self)
      || any(NutritionEntryEntity.self)
      || any(ExerciseEntryEntity.self)
      || any(ChoreDefinitionEntity.self)
      || any(GutEventEntity.self)
      || any(MoodEventEntity.self)
      || any(SymptomEventEntity.self)
      || any(MedicationDoseEventEntity.self)
      || any(IntakeEventEntity.self)
      || any(GroceryItemEntity.self)
      || any(ActivityDayEntity.self)
  }

  /// Backfill every manifest key that has no local row yet. `freshAccount` is
  /// only true for a genuinely new account (no CK rows and no other account
  /// signals) — seeds everything OFF for the welcome picker. Every other case
  /// (reinstall, new device, app update) seeds from manifest defaults so a
  /// pre-pull empty store never poisons cross-device section parity.
  @discardableResult
  static func seedMissingManifestSections(context: ModelContext,
                                          freshAccount: Bool) -> Bool {
    var seededAny = false
    for manifest in SectionManifest.all {
      if seedManifestSectionIfMissing(manifest.key, context: context,
                                     freshAccount: freshAccount) {
        seededAny = true
      }
    }
    return seededAny
  }

  @discardableResult
  static func seedManifestSectionIfMissing(_ key: String,
                                           context: ModelContext,
                                           freshAccount: Bool = false) -> Bool {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    if (try? context.fetch(descriptor).first) != nil { return false }
    guard let manifest = SectionManifest.byKey[key] else { return false }
    // A genuinely fresh account (no SectionEntity rows yet) seeds everything
    // OFF so nothing is pre-selected behind the first-run welcome — the user
    // picks there, and `applyWelcomeSelection` enables their choices. An
    // established account (rows already exist) seeds a newly-shipped section
    // from its manifest default, so a new core section still lights up on the
    // update that introduces it.
    let seedEnabled = freshAccount ? false : manifest.defaultEnabled
    let entity = SectionEntity(id: manifest.key,
                               title: manifest.defaultLabel,
                               color: "",
                               isEnabled: seedEnabled,
                               hasOnboarded: seedEnabled)
    context.insert(entity)
    // A section that seeds enabled (a new core section on an established
    // account) gets an accent now so it doesn't land gray. Fresh-account seeds
    // are disabled and stay colorless until the user enables them in the welcome.
    if seedEnabled { assignAutoColorIfNeeded(entity, context: context) }
    do { try context.save() } catch {
      SeptenaLog.error("SettingsMirror.seedManifestSection", error)
      return false
    }
    return true
  }

  /// One-shot migration for users who upgrade from a build that pre-dates
  /// the `hasOnboarded` field. Sections that are *currently enabled* on
  /// this device are flipped to `hasOnboarded = true` — they've clearly
  /// been in use, so no onboarding sheet should fire on their next
  /// toggle. Disabled rows are left alone: either they were never
  /// onboarded (fresh seed) or the user explicitly disabled them
  /// after onboarding (in which case the bit's value already encodes
  /// the right thing). Idempotent; must run BEFORE seeding so newly
  /// seeded rows aren't accidentally swept into the migration.
  static func backfillHasOnboardedForLegacySections(context: ModelContext) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.hasOnboarded == false && $0.isEnabled == true }
    )
    guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
    for row in rows {
      row.hasOnboarded = true
    }
    do {
      try context.save()
    } catch {
      SeptenaLog.error("SettingsMirror.backfillHasOnboarded", error)
    }
  }

  /// Toggle `hasOnboarded` on a single section. Pushes through CKEngine.
  static func setSectionHasOnboarded(_ key: String,
                                     hasOnboarded: Bool,
                                     context: ModelContext,
                                     engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    guard entity.hasOnboarded != hasOnboarded else { return }
    entity.hasOnboarded = hasOnboarded
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionHasOnboarded", error)
    }
  }

  /// Enable (or disable) a section by key, seeding the row from the
  /// manifest if it doesn't exist yet. Enabling also flips `hasOnboarded`
  /// so an intent-driven enable never tries to present a first-enable sheet
  /// with no UI on screen. Upsert-only — never deletes (same guarantee as
  /// `replaceSections`). Pushes through CKEngine. No-op when already in the
  /// target state.
  static func setSectionEnabled(_ key: String,
                                _ enabled: Bool,
                                context: ModelContext,
                                engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    let entity: SectionEntity
    if let existing = try? context.fetch(descriptor).first {
      entity = existing
    } else {
      guard let manifest = SectionManifest.byKey[key] else { return }
      entity = SectionEntity(id: manifest.key,
                             title: manifest.defaultLabel,
                             color: "")
      context.insert(entity)
    }
    // Enabling implies onboarded (suppresses the first-enable sheet a
    // headless intent can't present); disabling leaves the bit untouched.
    let needsWrite = entity.isEnabled != enabled || (enabled && !entity.hasOnboarded)
    guard needsWrite else { return }
    entity.isEnabled = enabled
    if enabled {
      entity.hasOnboarded = true
      // First enable with no color yet → give it a distinct palette accent so
      // it doesn't land on the dashboard gray.
      assignAutoColorIfNeeded(entity, context: context)
    }
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
      NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionEnabled", error)
    }
  }

  /// Publishes this device's current timezone into the synced Settings `time`
  /// block as `home_timezone`, so the hosted MCP gateway — which has no device
  /// to read — resolves the user's real zone instead of silently defaulting to
  /// UTC. The device is the authoritative source for *home*; gateway-owned
  /// `travel_mode` / `travel_timezone` are preserved untouched. Idempotent:
  /// `upsert` only pushes when the encoded payload actually changes, so the
  /// no-change common case is a cheap local read. Creates the settings record
  /// if the user has none yet (decode of `{}` yields all-nil/defaulted fields).
  static func publishDeviceTimezone(context: ModelContext, engine: CKEngine? = nil) {
    let deviceID = TimeZone.current.identifier
    guard var settings = loadSettings(context: context)
      ?? (try? decoder.decode(AppSettings.self, from: Data("{}".utf8))) else { return }
    guard settings.time?.homeTimezone != deviceID else { return }
    settings.time = AppTimeSettings(homeTimezone: deviceID,
                                    travelMode: settings.time?.travelMode,
                                    travelTimezone: settings.time?.travelTimezone)
    upsert(settings: settings, context: context, engine: engine)
  }

  static func upsert(settings: AppSettings,
                     context: ModelContext,
                     engine: CKEngine? = nil) {
    guard let data = try? encoder.encode(settings) else { return }
    let singletonID = SettingsCloudKitSchema.singletonID
    let descriptor = FetchDescriptor<SettingsEntity>(
      predicate: #Predicate { $0.id == singletonID }
    )
    let entity = (try? context.fetch(descriptor).first)
      ?? SettingsEntity(payloadData: data)
    let changed = entity.payloadData != data
    entity.payloadData = data
    entity.updatedAt = .now
    if entity.modelContext == nil { context.insert(entity) }
    do {
      try context.save()
      if changed { engine?.noteSettingsChange() }
    } catch {
      SeptenaLog.error("SettingsMirror.upsert settings", error)
    }
  }

  /// Upsert-only. Section rows are never deleted by this code path —
  /// disabling a section toggles `isEnabled` instead so all
  /// customizations (title, color) and the row itself survive. This is
  /// the absolute guarantee that no UX action can drop a SectionEntity.
  static func replaceSections(_ sections: [SectionConfig],
                              context: ModelContext,
                              engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>()
    let existing = (try? context.fetch(descriptor)) ?? []
    let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var changedIDs: [String] = []

    for section in sections {
      if let entity = existingByID[section.key] {
        let changed = entity.title != section.label
          || entity.color != section.color
          || entity.isEnabled != section.isEnabled
          || entity.showInToday != section.showInToday
          || entity.showInSpotlight != section.showInSpotlight
          || entity.hasOnboarded != section.hasOnboarded
        entity.title = section.label
        entity.color = section.color
        entity.isEnabled = section.isEnabled
        entity.showInToday = section.showInToday
        entity.showInSpotlight = section.showInSpotlight
        entity.hasOnboarded = section.hasOnboarded
        entity.updatedAt = .now
        if changed { changedIDs.append(section.key) }
      } else {
        let entity = SectionEntity(id: section.key,
                                   title: section.label,
                                   color: section.color,
                                   isEnabled: section.isEnabled,
                                   showInToday: section.showInToday,
                                   showInSpotlight: section.showInSpotlight,
                                   hasOnboarded: section.hasOnboarded)
        context.insert(entity)
        changedIDs.append(section.key)
      }
    }

    do {
      try context.save()
      for id in changedIDs { engine?.noteSectionChange(id: id) }
    } catch {
      SeptenaLog.error("SettingsMirror.replace sections", error)
    }
  }

  /// Toggle `isEnabled` on a single section. Pushes the change through
  /// CKEngine so other devices receive it. Never deletes the row.
  static func setSectionEnabled(_ key: String,
                                enabled: Bool,
                                context: ModelContext,
                                engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    guard entity.isEnabled != enabled else { return }
    entity.isEnabled = enabled
    // First enable with no color yet → auto-assign a distinct accent so the
    // section doesn't appear gray on the dashboard.
    if enabled { assignAutoColorIfNeeded(entity, context: context) }
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
      // Tell the app a section's enabled-state changed so data-driven surfaces
      // refresh — including the Spotlight index, where `SpotlightIndexer` purges
      // a disabled section's entities and re-indexes them on enable. Matches the
      // positional overload above; this labeled one previously notified no one.
      NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionEnabled", error)
    }
  }

  /// Set a section's accent `color` (hex). Same shape as the other single-key
  /// section setters — the write boundary for `SectionEntity.color`, so views
  /// never fetch-mutate-save the row directly. Persists, syncs, never deletes.
  static func setSectionColor(_ key: String,
                              hex: String,
                              context: ModelContext,
                              engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    guard entity.color != hex else { return }
    entity.color = hex
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionColor", error)
    }
  }

  /// Toggle `showInToday` on a single section. Same shape as
  /// `setSectionEnabled`: persists, syncs, never deletes.
  static func setSectionShowInToday(_ key: String,
                                    showInToday: Bool,
                                    context: ModelContext,
                                    engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    guard entity.showInToday != showInToday else { return }
    entity.showInToday = showInToday
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionShowInToday", error)
    }
  }

  /// Toggle `showInSpotlight` on a single section — the user's opt-out from
  /// Spotlight / Siri / Apple Intelligence discoverability. Same shape as
  /// `setSectionShowInToday`, but also posts `.septenaDataChanged` so
  /// `SpotlightIndexer` reconciles immediately (purge on opt-out, re-index on
  /// opt-in). See docs/SPOTLIGHT_READABILITY_PLAN.md.
  static func setSectionShowInSpotlight(_ key: String,
                                        showInSpotlight: Bool,
                                        context: ModelContext,
                                        engine: CKEngine? = nil) {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    guard entity.showInSpotlight != showInSpotlight else { return }
    entity.showInSpotlight = showInSpotlight
    entity.updatedAt = .now
    do {
      try context.save()
      engine?.noteSectionChange(id: key)
      NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
    } catch {
      SeptenaLog.error("SettingsMirror.setSectionShowInSpotlight", error)
    }
  }

  /// Whether a section is currently exposed to Spotlight / Siri. Defaults to
  /// true for a section with no row yet (e.g. the always-on Tasks section), so
  /// the absence of an explicit opt-out means discoverable. Read by
  /// `SpotlightIndexer` to gate indexing.
  static func showInSpotlight(_ key: String, context: ModelContext) -> Bool {
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == key }
    )
    return (try? context.fetch(descriptor).first)?.showInSpotlight ?? true
  }
}

import SwiftUI
import SwiftData

/// Opens Settings on a canonical registry page ID (`RegistrySettings.PageID.*`),
/// from outside Settings (e.g. the Get Started checklist). The caller sets
/// `pending` and opens Settings; the view reads it on appear, or on
/// `didRequest` when Settings is already open.
@MainActor
enum SeptaskSettingsLink {
  static var pending: String?
  static let didRequest = Notification.Name("septask.settings.openPage")

  static func request(_ pageID: String) {
    pending = pageID
    NotificationCenter.default.post(name: didRequest, object: nil)
  }
}

/// Registry-driven Settings for Septena (iOS & macOS, docs/SETTINGS_UX_SPEC.md).
///
/// Structure, grouping, ordering, defaults, icons, and platform gates come
/// from `registry/settings.json` (`RegistrySettings` in
/// `SeptenaCore/Generated/RegistryConstants.swift`):
///   • iOS: flat, scannable grouped root `Form` — everyday Lists & Appearance
///     controls sit inline on screen 1; multi-step flows are 1 tap deep with
///     live status badges; dev/diagnostic tools sit 2 taps deep under
///     About ▸ Advanced.
///   • macOS: 6-tab `NavigationSplitView` generated from
///     `RegistrySettings.desktopTabs`, expanding `desktopInline: true` pages
///     (Connect Claude + AI Preferences) directly into the AI & Agents tab.
struct SeptaskSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store
  @Environment(SectionTheme.self) private var theme

  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String =
    RegistrySettings.Defaults.welcomeName
  @AppStorage(SettingsKey.todayShowCompleted) private var todayShowCompleted: Bool =
    RegistrySettings.Defaults.todayShowCompleted
  @AppStorage(SettingsKey.todayGroupByList) private var todayGroupByList: Bool =
    RegistrySettings.Defaults.todayGroupByList
  @AppStorage(SettingsKey.tasksShowAging) private var showAging: Bool =
    RegistrySettings.Defaults.tasksShowAging
  @AppStorage(SettingsKey.tasksShowFaded) private var showFaded: Bool =
    RegistrySettings.Defaults.tasksShowFaded
  @AppStorage(SettingsKey.tasksFilingSuggestions) private var filingSuggestions: Bool =
    RegistrySettings.Defaults.tasksFilingSuggestions
  @AppStorage(SettingsKey.tasksShowCalendarEvents) private var showCalendarEvents: Bool =
    RegistrySettings.Defaults.tasksShowCalendarEvents
  @AppStorage(SettingsKey.badgeShowOverdue, store: SeptenaAppGroup.defaults)
  private var taskBadge: Bool = RegistrySettings.Defaults.badgeShowOverdue
  @AppStorage(SettingsKey.tasksTitleLines) private var titleLines: Int =
    RegistrySettings.Defaults.tasksTitleLines
  @AppStorage(SettingsKey.tasksSwipeLeadingAction) private var swipeLeadingActionRaw: String =
    RegistrySettings.Defaults.tasksSwipeLeadingAction
  @AppStorage(SettingsKey.textSizeStep) private var textSizeStep: Int =
    RegistrySettings.Defaults.textSizeStep
  @AppStorage(SettingsKey.loggingAnimationsEnabled) private var completionAnimations: Bool =
    RegistrySettings.Defaults.loggingAnimationsEnabled
  @AppStorage(AIPolicy.modeKey) private var aiModeRaw: String =
    RegistrySettings.Defaults.aiMode

  @State private var path: [String] = []
  #if os(macOS)
  @State private var selectedTab: String? = RegistrySettings.TabID.general
  #endif

  private var currentPlatform: String {
    #if os(macOS)
    return "macos"
    #else
    return "ios"
    #endif
  }

  var body: some View {
    #if os(macOS)
    NavigationSplitView {
      List(selection: $selectedTab) {
        macSidebarContent
      }
      .navigationTitle("Settings")
      .toolbar(removing: .sidebarToggle)
      .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
    } detail: {
      NavigationStack(path: $path) {
        macTabPane(selectedTab ?? RegistrySettings.TabID.general)
          .navigationDestination(for: String.self) { page($0) }
      }
    }
    .frame(width: 820, height: 600)
    .onChange(of: selectedTab) { _, _ in
      // Switching sidebar tabs resets any pushed subpage cleanly.
      path.removeAll()
    }
    .onExitCommand { dismiss() }
    .onAppear(perform: consumeLink)
    .onReceive(NotificationCenter.default.publisher(for: SeptaskSettingsLink.didRequest)) { _ in consumeLink() }
    .task(id: TaskSyncEngine.shared.signedIn) { await PlanStatus.shared.refresh() }
    #else
    NavigationStack(path: $path) {
      Form {
        iosRootContent
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .background(SettingsTopGradient())
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: String.self) { page($0) }
      .task(id: TaskSyncEngine.shared.signedIn) { await PlanStatus.shared.refresh() }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDragIndicator(.visible)
    .onAppear(perform: consumeLink)
    .onReceive(NotificationCenter.default.publisher(for: SeptaskSettingsLink.didRequest)) { _ in consumeLink() }
    #endif
  }

  /// The depth-1 page that links to a depth-2 page (About ▸ Advanced,
  /// Privacy & Data ▸ Import & Export), read from the registry.
  private static func parentPage(of pageID: String) -> String? {
    RegistrySettings.pages.first { page in
      page.sections.contains { section in
        section.items.contains { $0.kind == "pageLink" && $0.page == pageID }
      }
    }?.id
  }

  /// Opens the canonical registry page ID requested via `SeptaskSettingsLink`.
  private func consumeLink() {
    guard let pageID = SeptaskSettingsLink.pending else { return }
    SeptaskSettingsLink.pending = nil
    #if os(macOS)
    let targetTab = owningDesktopTab(for: pageID)
    selectedTab = targetTab
    // Pages marked `desktopInline: true` (or top-level tab pages) render
    // directly inside the selected tab without pushing onto the detail stack.
    let isTabRoot = (pageID == targetTab) || isDesktopInline(pageID: pageID)
    if isTabRoot {
      path = []
    } else {
      // Defer push one turn so `.onChange(of: selectedTab)` doesn't clear it.
      DispatchQueue.main.async {
        path = [pageID]
      }
    }
    #else
    if let parent = Self.parentPage(of: pageID) {
      path = [parent, pageID]
    } else {
      path = [pageID]
    }
    #endif
  }

  // MARK: - iOS Flat Root (from RegistrySettings.rootGroups)

  #if !os(macOS)
  @ViewBuilder
  private var iosRootContent: some View {
    ForEach(RegistrySettings.rootGroups) { group in
      let visibleItems = group.items.filter(isItemVisible)
      if !visibleItems.isEmpty {
        if group.mobilePresentation == "card" {
          Section {
            NavigationLink(value: RegistrySettings.PageID.account) {
              profileCardContent
            }
          }
        } else {
          Section {
            ForEach(visibleItems) { item in
              registryItemRow(item, expandDesktopInline: false)
            }
          } header: {
            if let header = group.header {
              Text(header)
            }
          }
        }
      }
    }
    // Apple Watch moved to Account ▸ Devices & Access (2026-11-22).
  }
  #endif

  // MARK: - macOS 6-Tab Sidebar (from RegistrySettings.desktopTabs)

  #if os(macOS)
  @ViewBuilder
  private var macSidebarContent: some View {
    let identityTabs = RegistrySettings.desktopTabs.filter { $0.group == "identity" && $0.applies(to: "macos") }
    let mainTabs = RegistrySettings.desktopTabs.filter { $0.group == "main" && $0.applies(to: "macos") }
    let aboutTabs = RegistrySettings.desktopTabs.filter { $0.group == "about" && $0.applies(to: "macos") }

    if !identityTabs.isEmpty {
      Section {
        ForEach(identityTabs) { tab in
          profileCardContent
            .settingsSidebarRow(tab.id, selection: selectedTab)
        }
      }
    }

    if !mainTabs.isEmpty {
      Section {
        ForEach(mainTabs) { tab in
          macSidebarRow(tab)
            .settingsSidebarRow(tab.id, selection: selectedTab)
        }
      }
    }

    if !aboutTabs.isEmpty {
      Section {
        ForEach(aboutTabs) { tab in
          macSidebarRow(tab)
            .settingsSidebarRow(tab.id, selection: selectedTab)
        }
      }
    }
  }

  /// Bare SF Symbol in the accent color, the platform sidebar standard. No
  /// per-row rainbow tile.
  private func macSidebarRow(_ tab: RegistrySettingsTab) -> some View {
    Label {
      Text(tab.title)
    } icon: {
      Image(systemName: tab.sfSymbol)
        .foregroundStyle(Color.accentColor)
    }
  }

  @ViewBuilder
  private func macTabPane(_ tabID: String) -> some View {
    switch tabID {
    case RegistrySettings.TabID.account:
      SeptaskAccountPane()
    case RegistrySettings.TabID.privacy:
      SeptaskPrivacyPane()
    case RegistrySettings.TabID.about:
      SeptaskAboutPane()
    case RegistrySettings.TabID.aiAgents:
      Form {
        let groups = RegistrySettings.rootGroups.filter { $0.desktopTab == tabID }
        ForEach(groups) { group in
          let visibleItems = group.items.filter(isItemVisible)
          ForEach(visibleItems) { item in
            if item.kind == "pageLink", item.desktopInline, let target = item.page {
              inlineDesktopPageSections(target)
            } else {
              Section {
                registryItemRow(item, expandDesktopInline: true)
              } header: {
                if item.key == "agentsPaused" {
                  Text("Agents")
                }
              } footer: {
                if item.key == "agentsPaused" {
                  Text("While paused, no agent can pick up or work on a task. Stop one task from its conversation instead. Agents never close assigned tasks on their own — finished work lands in Review for you to accept or send back.")
                }
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(RegistrySettings.tabById[tabID]?.title ?? tabID)
    default:
      Form {
        let groups = RegistrySettings.rootGroups.filter { $0.desktopTab == tabID }
        ForEach(groups) { group in
          let visibleItems = group.items.filter(isItemVisible)
          let inlinePages = visibleItems.filter { $0.kind == "pageLink" && $0.desktopInline }
          let rows = visibleItems.filter { !($0.kind == "pageLink" && $0.desktopInline) }
          if !rows.isEmpty {
            Section {
              ForEach(rows) { item in
                registryItemRow(item, expandDesktopInline: true)
              }
            } header: {
              if let header = group.header {
                Text(header)
              }
            }
          }
          // A desktop-inline page link (Appearance) expands its page's
          // sections into the tab instead of pushing a page.
          ForEach(inlinePages) { item in
            if let target = item.page {
              inlineDesktopPageSections(target)
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(RegistrySettings.tabById[tabID]?.title ?? "Settings")
    }
  }

  @ViewBuilder
  private func inlineDesktopPageSections(_ pageID: String) -> some View {
    switch pageID {
    case RegistrySettings.PageID.claudePairing:
      SeptaskClaudePairingSections()
    case RegistrySettings.PageID.aiPreferences:
      SeptaskAIPreferencesSections()
    default:
      registryPageSections(pageID, titleAsHeader: true)
    }
  }

  private func owningDesktopTab(for pageID: String) -> String {
    if RegistrySettings.tabById[pageID] != nil { return pageID }
    if let parent = Self.parentPage(of: pageID) { return owningDesktopTab(for: parent) }
    for group in RegistrySettings.rootGroups {
      if let tab = group.desktopTab,
         group.items.contains(where: { $0.kind == "pageLink" && $0.page == pageID }) {
        return tab
      }
    }
    return RegistrySettings.TabID.general
  }

  private func isDesktopInline(pageID: String) -> Bool {
    RegistrySettings.rootGroups.contains { group in
      group.items.contains { $0.kind == "pageLink" && $0.page == pageID && $0.desktopInline }
    }
  }
  #endif

  // MARK: - Profile & Sync Card

  private var profileCardContent: some View {
    HStack(spacing: 14) {
      #if os(macOS)
      ProfileAvatar(name: welcomeName, isPlus: PlanStatus.shared.isPlus, size: 44)
      #else
      ProfileAvatar(name: welcomeName, isPlus: PlanStatus.shared.isPlus, size: 54)
      #endif
      VStack(alignment: .leading, spacing: 3) {
        Text(welcomeName.isEmpty ? "Your Profile" : welcomeName)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.primary)
        HStack(spacing: 6) {
          if TaskSyncEngine.shared.signedIn {
            if PlanStatus.shared.isPlus { SeptenaPlusBadge() } else { FreeAccountBadge() }
            Text("·")
              .font(.caption)
              .foregroundStyle(.tertiary)
            Text(liveSyncSummary)
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("On this device · Sign in to sync")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
  }

  // MARK: - Generic Registry Item Renderer

  private func isItemVisible(_ item: RegistrySettingsItem) -> Bool {
    guard item.applies(to: currentPlatform) else { return false }
    switch item.visibility {
    case "signedIn":
      return TaskSyncEngine.shared.signedIn
    case "signedOut":
      return !TaskSyncEngine.shared.signedIn
    case "debugOnly":
      #if DEBUG
      return true
      #else
      return false
      #endif
    case "minAppleOS27":
      return OnDeviceAI.pccStatus != nil
    default:
      return true
    }
  }

  @ViewBuilder
  private func registryItemRow(_ item: RegistrySettingsItem, expandDesktopInline: Bool) -> some View {
    switch item.kind {
    case "pageLink":
      if let pageID = item.page {
        NavigationLink(value: pageID) {
          HStack(spacing: 12) {
            pageLinkLabel(item)
            Spacer(minLength: 8)
            if let badge = statusText(for: item.statusKey) {
              Text(badge)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
    case "setting":
      if let key = item.key {
        settingControl(for: key, item: item)
      }
    case "customSurface":
      if let surface = item.surface {
        inlineSurface(for: surface, item: item)
      }
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func pageLinkLabel(_ item: RegistrySettingsItem) -> some View {
    let title = item.label ?? RegistrySettings.pageById[item.page ?? ""]?.title ?? ""
    if item.iconId == "settings.claude" {
      Label {
        Text(title)
      } icon: {
        Image("ClaudeMark")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: 20, height: 20)
      }
      .foregroundStyle(.primary)
    } else if let symbol = item.sfSymbol {
      Label(title, systemImage: symbol)
    } else {
      Text(title)
    }
  }

  @ViewBuilder
  private func settingControl(for key: String, item: RegistrySettingsItem) -> some View {
    let label = item.label ?? key
    switch key {
    case "todayGroupByList":
      Toggle(isOn: TaskViewOptions.announcing($todayGroupByList)) {
        rowLabel(label, detail: item.detail)
      }
    case "todayShowCompleted":
      Toggle(label, isOn: TaskViewOptions.announcing($todayShowCompleted))
    case "tasksShowAging":
      Toggle(isOn: TaskViewOptions.announcing($showAging)) {
        rowLabel(label, detail: item.detail)
      }
    case "tasksShowFaded":
      Toggle(isOn: TaskViewOptions.announcing($showFaded)) {
        rowLabel(label, detail: item.detail)
      }
    case "tasksFilingSuggestions":
      Toggle(isOn: $filingSuggestions) {
        rowLabel(label, detail: item.detail)
      }
    case "badgeShowOverdue":
      Toggle(label, isOn: $taskBadge)
    case "agentsPaused":
      Toggle(isOn: Binding(
        get: { store.agentsPaused },
        set: { store.setAgentsPaused($0, context: modelContext, engine: ckEngine) }
      )) {
        rowLabel(label, detail: item.detail)
      }
    case "loggingAnimationsEnabled":
      Toggle(isOn: $completionAnimations) {
        if let symbol = item.sfSymbol {
          Label(label, systemImage: symbol)
        } else {
          Text(label)
        }
      }
    case "tasksTitleLines":
      Picker(label, selection: $titleLines) {
        ForEach(RegistrySettings.optionsByKey["tasksTitleLines"] ?? []) { opt in
          if let intVal = Int(opt.value) {
            Text(opt.title).tag(intVal)
          }
        }
      }
    case "tasksSwipeLeadingAction":
      #if os(iOS)
      Picker(selection: $swipeLeadingActionRaw) {
        ForEach(RegistrySettings.optionsByKey["tasksSwipeLeadingAction"] ?? []) { opt in
          Text(opt.title).tag(opt.value)
        }
      } label: {
        rowLabel(label, detail: item.detail)
      }
      #else
      EmptyView()
      #endif
    case "textSizeStep":
      inlineTextSizeRow(label: label)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func inlineSurface(for surface: String, item: RegistrySettingsItem) -> some View {
    switch surface {
    case "accent_color":
      AppearancePickerView()
    default:
      EmptyView()
    }
  }

  private func inlineTextSizeRow(label: String) -> some View {
    let sliderBinding = Binding<Double>(
      get: { Double(TextSizeStep.resolve(textSizeStep).rawValue) },
      set: {
        let step = Int($0.rounded())
        textSizeStep = step
        #if os(macOS)
        FontScale.shared.setStep(step)
        #endif
      }
    )
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label)
        Spacer()
        Text(TextSizeStep.resolve(textSizeStep).label)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Slider(value: sliderBinding, in: -2...2, step: 1) {
        Text(label)
      } minimumValueLabel: {
        Image(systemName: "textformat.size.smaller")
          .foregroundStyle(.secondary)
      } maximumValueLabel: {
        Image(systemName: "textformat.size.larger")
          .foregroundStyle(.secondary)
      }
      .accessibilityValue(TextSizeStep.resolve(textSizeStep).label)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func rowLabel(_ title: String, detail: String?) -> some View {
    if let detail, !detail.isEmpty {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      Text(title)
    }
  }

  // MARK: - Live Status Badges (for Depth-0 Push Rows)

  private var liveSyncSummary: String {
    let sync = TaskSyncEngine.shared
    if sync.isSyncing { return "Syncing" }
    if sync.pendingOps > 0 { return "\(sync.pendingOps) to send" }
    return sync.wsConnected ? "Live" : "Offline"
  }

  private func statusText(for statusKey: String?) -> String? {
    guard let statusKey else { return nil }
    switch statusKey {
    case "syncStatus":
      return TaskSyncEngine.shared.signedIn ? liveSyncSummary : "On this device"
    case "planStatus":
      return PlanStatus.shared.statusLine
    case "claudeStatus":
      guard TaskSyncEngine.shared.signedIn else { return "Sign in" }
      let paired = SeptaskSyncedSettings.current().getStartedSteps?.contains(TaskNoticeStep.ID.connectAI.rawValue) == true
      return paired ? "Connected" : "Set up"
    case "aiMode":
      return (AIMode(rawValue: aiModeRaw) ?? .auto).title
    case "calendarStatus":
      guard showCalendarEvents, CalendarBridge.shared.access == .granted else { return "Off" }
      let visible = CalendarBridge.shared.allCalendars().filter { !CalendarBridge.shared.isHidden($0) }.count
      return visible == 1 ? "1 calendar" : "\(visible) calendars"
    case "remindersStatus":
      let bridge = RemindersBridge.shared
      guard bridge.access == .granted, let id = bridge.sourceListID else { return "Off" }
      return bridge.reminderLists().first(where: { $0.calendarIdentifier == id })?.title ?? "On"
    default:
      return nil
    }
  }

  // MARK: - Registry-Rendered Page Sections

  /// Renders a page's sections straight from `RegistrySettings.pages`, for
  /// pages whose rows are all plain settings and inline surfaces (Appearance).
  /// On a desktop tab the page title stands in for a missing section header.
  @ViewBuilder
  private func registryPageSections(_ pageID: String, titleAsHeader: Bool) -> some View {
    if let page = RegistrySettings.pageById[pageID] {
      ForEach(page.sections.filter { $0.applies(to: currentPlatform) }) { section in
        let visibleItems = section.items.filter(isItemVisible)
        if !visibleItems.isEmpty {
          Section {
            ForEach(visibleItems) { item in
              registryItemRow(item, expandDesktopInline: titleAsHeader)
            }
          } header: {
            if let header = section.header ?? (titleAsHeader ? page.title : nil) {
              Text(header)
            }
          } footer: {
            if let footer = section.footer {
              Text(footer)
            }
          }
        }
      }
    }
  }

  // MARK: - Depth-1 & Depth-2 Pages

  @ViewBuilder
  private func page(_ pageID: String) -> some View {
    switch pageID {
    case RegistrySettings.PageID.account:
      SeptaskAccountPane()
    case RegistrySettings.PageID.claudePairing:
      SeptaskClaudePairingPane()
    case RegistrySettings.PageID.aiPreferences:
      SeptaskAIPreferencesPane()
    case RegistrySettings.PageID.calendar:
      CalendarDetail()
        .navigationTitle(RegistrySettings.pageById[pageID]?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    case RegistrySettings.PageID.reminders:
      RemindersInboxDetail()
        .navigationTitle(RegistrySettings.pageById[pageID]?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    case RegistrySettings.PageID.importExport:
      SeptaskImportExportPane()
    case RegistrySettings.PageID.privacy:
      SeptaskPrivacyPane()
    case RegistrySettings.PageID.about:
      SeptaskAboutPane()
    case RegistrySettings.PageID.advanced:
      SeptaskAdvancedPane()
    case RegistrySettings.PageID.smartLists:
      SeptaskSmartListsPane()
    case RegistrySettings.PageID.plus:
      SeptaskPlusPane()
    case RegistrySettings.PageID.devicesAccess:
      SeptaskDevicesAccessPane()
    case RegistrySettings.PageID.appearance:
      Form {
        registryPageSections(pageID, titleAsHeader: false)
      }
      .formStyle(.grouped)
      .navigationTitle(RegistrySettings.pageById[pageID]?.title ?? "")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
    default:
      EmptyView()
    }
  }
}

// MARK: - Account (Depth 1)

private struct SeptaskAccountPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.welcomeName) private var welcomeName: String =
    RegistrySettings.Defaults.welcomeName

  var body: some View {
    Form {
      Section {
        HStack(spacing: 16) {
          ProfileAvatar(name: welcomeName, isPlus: PlanStatus.shared.isPlus, size: 64)
          VStack(alignment: .leading, spacing: 4) {
            TextField(RegistrySettings.label(surface: "account_profile_editor"), text: $welcomeName)
              .font(.title2.weight(.semibold))
              .textContentType(.givenName)
              #if os(iOS)
              .textInputAutocapitalization(.words)
              #endif
              .onChange(of: welcomeName) { _, newValue in
                store.setWelcomeName(newValue, context: modelContext, engine: ckEngine)
              }
            if TaskSyncEngine.shared.signedIn {
              if PlanStatus.shared.isPlus {
                SeptenaPlusBadge()
              } else {
                FreeAccountBadge()
              }
            } else {
              Text("On this device")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 6)
      } footer: {
        if let footer = RegistrySettings.section("profile", page: RegistrySettings.PageID.account)?.footer {
          Text(footer)
        }
      }

      Section {
        NavigationLink(value: RegistrySettings.PageID.plus) {
          LabeledContent {
            if let line = PlanStatus.shared.statusLine { Text(line) }
          } label: {
            Label(RegistrySettings.pageById[RegistrySettings.PageID.plus]?.title ?? RegistryPlans.name,
                  systemImage: RegistryIcons.sfSymbols["settings.plus"] ?? "plus.circle.fill")
          }
        }
      }

      Section {
        NavigationLink(value: RegistrySettings.PageID.devicesAccess) {
          Label(RegistrySettings.pageById[RegistrySettings.PageID.devicesAccess]?.title ?? "",
                systemImage: RegistryIcons.sfSymbols["settings.devices"] ?? "laptopcomputer.and.iphone")
        }
      }

      SeptaskSyncAccountSection()
      SeptaskSignInApprovalSection()
      SeptaskDeleteAccountSection()
    }
    .formStyle(.grouped)
    .task { await PlanStatus.shared.refresh() }
    .navigationTitle(RegistrySettings.pageById[RegistrySettings.PageID.account]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

// MARK: - Privacy (Depth 1)

/// Concise privacy overview + one canonical usage-data dial. Opt-in weekly
/// diagnostics & Community Pulse live in Settings ▸ About ▸ Advanced so
/// consumer Privacy stays unambiguous (docs/SETTINGS_UX_SPEC.md).
private struct SeptaskPrivacyPane: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.telemetryLevel) private var levelRaw: String =
    RegistrySettings.Defaults.telemetryLevel

  private var level: TelemetryClient.TelemetryLevel {
    TelemetryClient.TelemetryLevel(rawValue: levelRaw) ?? .balanced
  }

  private var dataSection: RegistrySettingsSection? {
    RegistrySettings.section("data_locality", page: RegistrySettings.PageID.privacy)
  }

  private var telemetrySection: RegistrySettingsSection? {
    RegistrySettings.section("telemetry", page: RegistrySettings.PageID.privacy)
  }

  var body: some View {
    Form {
      Section {
        Text(RegistrySettings.itemBySurface["privacy_explainer"]?.detail ?? "")
      } header: {
        Text(dataSection?.header ?? "")
      }

      if let transfer = RegistrySettings.section("transfer", page: RegistrySettings.PageID.privacy) {
        Section {
          ForEach(transfer.items.filter { $0.kind == "pageLink" }) { item in
            if let target = item.page {
              NavigationLink(value: target) {
                Label(item.label ?? "", systemImage: item.sfSymbol ?? "square.and.arrow.up")
              }
            }
          }
        }
      }

      Section {
        Picker(RegistrySettings.label(key: "telemetryLevel"), selection: Binding(
          get: { level },
          set: { store.setTelemetryLevel($0, context: modelContext, engine: ckEngine) }
        )) {
          ForEach(TelemetryClient.TelemetryLevel.allCases, id: \.self) { lvl in
            Text(lvl.title).tag(lvl)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } header: {
        Text(telemetrySection?.header ?? "")
      } footer: {
        Text([level.summary, telemetrySection?.footer].compactMap { $0 }.joined(separator: " "))
      }
    }
    .formStyle(.grouped)
    .navigationTitle(RegistrySettings.pageById[RegistrySettings.PageID.privacy]?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

// MARK: - About (Depth 1)

/// Renders the `about` page of `registry/settings.json`: section order,
/// headers, labels, icons and copy come from the registry. Swift keeps only
/// the native behavior behind each surface (Sparkle, mail, open URL).
private struct SeptaskAboutPane: View {
  @Environment(\.openURL) private var openURL
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(NavigationState.self) private var nav

  private static let page = RegistrySettings.pageById[RegistrySettings.PageID.about]

  private var platform: String {
    #if os(macOS)
    "macos"
    #else
    "ios"
    #endif
  }

  var body: some View {
    Form {
      ForEach((Self.page?.sections ?? []).filter { $0.applies(to: platform) }) { section in
        Section {
          ForEach(section.items.filter { $0.applies(to: platform) }) { item in
            row(item)
          }
        } header: {
          if let header = section.header { Text(header) }
        } footer: {
          if let footer = section.footer { Text(footer) }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(Self.page?.title ?? "")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  @ViewBuilder
  private func label(_ item: RegistrySettingsItem) -> some View {
    let title = item.label ?? ""
    if let symbol = item.sfSymbol {
      Label(title, systemImage: symbol)
    } else {
      Text(title)
    }
  }

  @ViewBuilder
  private func row(_ item: RegistrySettingsItem) -> some View {
    switch item.kind {
    case "pageLink":
      if let page = item.page {
        NavigationLink(value: page) { label(item) }
      }
    case "customSurface":
      surface(item)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func surface(_ item: RegistrySettingsItem) -> some View {
    switch item.surface {
    case "about_header":
      VStack(spacing: 6) {
        SeptenaDiscTile(size: 72)
          .padding(.bottom, 6)
        Text(AppDisplayName.current)
          .font(.title2.weight(.semibold))
        if let tagline = item.label {
          Text(tagline)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Text(RegistrySettings.aboutHeaderDetail(version: SeptaskAbout.versionString))
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .listRowBackground(Color.clear)
    case "check_updates":
      #if os(macOS)
      Button {
        Task { @MainActor in SeptaskUpdater.shared.checkForUpdates() }
      } label: {
        label(item)
      }
      #if DEBUG
      .disabled(true)
      #else
      .disabled(!SeptaskUpdater.isConfigured)
      #endif
      #else
      EmptyView()
      #endif
    case "reset_get_started":
      Button { TaskNotices.resetGetStarted() } label: { label(item) }
    case "reset_first_run":
      // This device only: the synced `onboardedAt` stays, so other devices
      // are not asked again (`SettingsStore.resetWelcomeForTesting`).
      Button {
        settingsStore.resetWelcomeForTesting()
        #if os(macOS)
        SeptaskKitFirstRunWindow.present()
        #else
        nav.showSettings = false
        #endif
      } label: {
        label(item)
      }
    case "send_feedback":
      Link(destination: URL(string: "mailto:mz@envisioning.com?subject=Septena%20feedback")!) {
        label(item)
      }
    case "septena_life_link":
      if let detail = item.detail {
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Button {
        openURL(URL(string: "septena://")!) { accepted in
          if !accepted {
            openURL(URL(string: "https://www.septena.app")!)
          }
        }
      } label: {
        label(item)
      }
    default:
      EmptyView()
    }
  }
}

enum SeptaskAbout {
  static var versionString: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "\(short) (\(build))"
  }
}

// MARK: - Smart Lists (Depth 1)

private struct SeptaskSmartListsPane: View {
  @State private var prefs = SmartListPreferences.shared

  var body: some View {
    List {
      sectionBlock(.top,
                   header: "Above Areas & Projects",
                   footer: "Working lists shown at the top of the sidebar.")
      sectionBlock(.bottom,
                   header: "Below Areas & Projects",
                   footer: "Archive and utility lists shown below your areas and projects. Drag to reorder within a section, or use the arrow button to move a list above or below. Changes sync across all your devices.")

      if prefs.isCustomized {
        Section {
          Button("Reset to Defaults") {
            prefs.resetToDefaults()
          }
        }
      }
    }
    #if os(iOS)
    .environment(\.editMode, .constant(.active))
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .navigationTitle("Smart Lists")
  }

  @ViewBuilder
  private func sectionBlock(_ section: SmartListSection,
                            header: String,
                            footer: String) -> some View {
    let items = prefs.orderedDestinations(in: section)
    Section {
      if items.isEmpty {
        Text("No smart lists in this section")
          .foregroundStyle(.secondary)
      } else {
        ForEach(items) { dest in
          smartListRow(dest, in: section)
        }
        .onMove { source, destination in
          prefs.moveInSection(section, fromOffsets: source, toOffset: destination)
        }
      }
    } header: {
      Text(header)
    } footer: {
      Text(footer)
    }
  }

  private func smartListRow(_ dest: RegistryDestination,
                            in section: SmartListSection) -> some View {
    HStack(spacing: 12) {
      Image(systemName: dest.sfSymbol)
        .font(.body.weight(.semibold))
        .foregroundStyle(dest.id == "today" ? AppearancePreferences.shared.accentSwiftUIColor : .secondary)
        .frame(width: 24, alignment: .center)
      VStack(alignment: .leading, spacing: 2) {
        Text(dest.title)
        if !dest.canHide {
          Text("Always shown")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if dest.visibility == "whenNonEmpty" {
          Text("Shown when non-empty")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if dest.canMoveSection {
        let target: SmartListSection = section == .top ? .bottom : .top
        Button {
          prefs.setSection(target, for: dest.id)
        } label: {
          Image(systemName: target == .bottom ? "arrow.down.to.line" : "arrow.up.to.line")
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(target == .bottom ? "Move below Areas & Projects" : "Move above Areas & Projects")
        .accessibilityLabel(target == .bottom
                            ? "Move \(dest.title) below Areas & Projects"
                            : "Move \(dest.title) above Areas & Projects")
      }
      Toggle(dest.title, isOn: Binding(
        get: { !prefs.isHidden(dest.id) },
        set: { prefs.setHidden(!$0, for: dest.id) }
      ))
      .labelsHidden()
      .disabled(!dest.canHide)
    }
  }
}

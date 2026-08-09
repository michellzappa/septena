import Foundation

/// A deliberately small, opt-in weekly snapshot for product diagnostics.
///
/// This is separate from `TelemetryClient`: it never contains task content,
/// counts, or account identifiers. It carries a random local installation
/// token only so the worker can de-duplicate one weekly report per install.
public struct SeptaskDiagnosticsBatch: Codable, Equatable, Sendable {
    public struct App: Codable, Equatable, Sendable {
        public let version: String
        public let build: String
        public let platform: String
        public let osMajor: Int
        public let architecture: String
    }

    public struct Features: Codable, Equatable, Sendable {
        public let claudeConnected: Bool
        public let calendarAccess: Bool
        public let remindersAccess: Bool
        public let remindersAutoImport: Bool

        enum CodingKeys: String, CodingKey {
            case claudeConnected = "claude_connected"
            case calendarAccess = "calendar_access"
            case remindersAccess = "reminders_access"
            case remindersAutoImport = "reminders_auto_import"
        }
    }

    public let schema: Int
    public let installID: String
    public let batchID: String
    public let period: String
    public let app: App
    public let features: Features

    enum CodingKeys: String, CodingKey {
        case schema
        case installID = "install_id"
        case batchID = "batch_id"
        case period
        case app
        case features
    }

    public static let dataCatalog = [
        "App version, build, platform, OS major version, and CPU architecture",
        "Whether Claude, Calendar, or Reminders integrations are enabled",
        "Whether Reminders automatic import is enabled",
        "A random anonymous installation token used only to avoid duplicate reports",
        "A coarse calendar week, with one report per installation per week",
    ]

    public static let neverCollected = [
        "Task titles, notes, task counts, projects, labels, or calendar event text",
        "Names, email addresses, account IDs, iCloud identity, or a device identifier",
        "Telemetry from this feature when the setting is turned off",
    ]
}

public struct SeptaskDiagnosticsPulse: Decodable, Sendable {
    public struct WeeklyActive: Decodable, Sendable, Identifiable {
        public let period: String
        public let reportingInstalls: Int

        public var id: String { period }

        enum CodingKeys: String, CodingKey {
            case period
            case reportingInstalls = "reporting_installs"
        }
    }

    public struct Version: Decodable, Sendable, Identifiable {
        public let name: String
        public let installs: Int

        public var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name
            case installs
        }
    }

    public struct Feature: Decodable, Sendable, Identifiable {
        public let name: String
        public let adoptionPercent: Int

        public var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name
            case adoptionPercent = "adoption_percent"
        }
    }

    public struct Latest: Decodable, Sendable {
        public let period: String
        public let reportingInstalls: Int
        public let versions: [Version]
        public let features: [Feature]

        enum CodingKeys: String, CodingKey {
            case period
            case reportingInstalls = "reporting_installs"
            case versions
            case features
        }
    }

    public let minimumGroupSize: Int
    public let weeklyActive: [WeeklyActive]
    public let latest: Latest?

    enum CodingKeys: String, CodingKey {
        case minimumGroupSize = "minimum_group_size"
        case weeklyActive = "weekly_active"
        case latest
    }
}

/// Coordinates the optional weekly diagnostics report used by Septask.
@MainActor
public final class SeptaskDiagnosticsCoordinator {
    public static let shared = SeptaskDiagnosticsCoordinator()
    public static let enabledKey = "septask.diagnostics.enabled"

    private static let lastSubmittedPeriodKey = "septask.diagnostics.lastSubmittedPeriod"
    private static let installIDKey = "septask.diagnostics.installID"
    private static let pendingFilename = "pending-weekly-diagnostics.json"
    private static let schema = 1

    private var task: Task<Void, Never>?

    private init() {}

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)

        if enabled {
            shared.start()
        } else {
            shared.stop()
            deletePendingBatch()
            UserDefaults.standard.removeObject(forKey: lastSubmittedPeriodKey)
            UserDefaults.standard.removeObject(forKey: installIDKey)
        }
    }

    public func start() {
        guard Self.isEnabled, task == nil else { return }

        task = Task { [weak self] in
            guard let self else { return }
            await self.submitIfDue()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
                guard !Task.isCancelled else { return }
                await self.submitIfDue()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func preview() -> SeptaskDiagnosticsBatch {
        makeBatch(period: Self.currentPeriod())
    }

    public func loadPulse() async -> SeptaskDiagnosticsPulse? {
        #if DEBUG
        return nil
        #else
        let url = CommunityEndpoint.baseURL.appendingPathComponent("api/public/telemetry")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Septask/\(appVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(SeptaskDiagnosticsPulse.self, from: data)
        } catch {
            return nil
        }
        #endif
    }

    private func submitIfDue() async {
        guard Self.isEnabled else { return }

        if let pending = loadPendingBatch() {
            if await send(pending) {
                Self.deletePendingBatch()
                UserDefaults.standard.set(pending.period, forKey: Self.lastSubmittedPeriodKey)
            }
            return
        }

        let period = Self.currentPeriod()
        guard UserDefaults.standard.string(forKey: Self.lastSubmittedPeriodKey) != period else {
            return
        }

        let batch = makeBatch(period: period)
        if await send(batch) {
            UserDefaults.standard.set(period, forKey: Self.lastSubmittedPeriodKey)
        } else {
            savePendingBatch(batch)
        }
    }

    private func send(_ batch: SeptaskDiagnosticsBatch) async -> Bool {
        #if DEBUG
        return false
        #else
        let url = CommunityEndpoint.baseURL.appendingPathComponent("api/telemetry/weekly")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(batch)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Septask/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("\(Self.schema)", forHTTPHeaderField: "X-Septask-Diagnostics-Schema")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
        #endif
    }

    private func makeBatch(period: String) -> SeptaskDiagnosticsBatch {
        SeptaskDiagnosticsBatch(
            schema: Self.schema,
            installID: Self.installID(),
            batchID: UUID().uuidString.lowercased(),
            period: period,
            app: .init(
                version: appVersion,
                build: appBuild,
                platform: platform,
                osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                architecture: architecture
            ),
            features: .init(
                claudeConnected: ClaudeGatewayProvider.shared.isEnabled,
                calendarAccess: calendarAccessGranted,
                remindersAccess: remindersAccessGranted,
                remindersAutoImport: RemindersBridge.shared.autoImport
            )
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private var platform: String {
        #if os(macOS)
        return "macos"
        #elseif os(iOS)
        return "ios"
        #else
        return "unknown"
        #endif
    }

    private var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private var calendarAccessGranted: Bool {
        if case .granted = CalendarBridge.shared.access { return true }
        return false
    }

    private var remindersAccessGranted: Bool {
        if case .granted = RemindersBridge.shared.access { return true }
        return false
    }

    private static func currentPeriod(date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let week = calendar.component(.weekOfYear, from: date)
        let year = calendar.component(.yearForWeekOfYear, from: date)
        return String(format: "%04d-W%02d", year, week)
    }

    private static func installID() -> String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: installIDKey)
        return created
    }

    private static var pendingURL: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return root.appendingPathComponent("Septask", isDirectory: true).appendingPathComponent(pendingFilename)
    }

    private func loadPendingBatch() -> SeptaskDiagnosticsBatch? {
        guard let url = Self.pendingURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SeptaskDiagnosticsBatch.self, from: data)
    }

    private func savePendingBatch(_ batch: SeptaskDiagnosticsBatch) {
        guard let url = Self.pendingURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(batch)
            try data.write(to: url, options: .atomic)
        } catch {
            // Diagnostics must never affect app startup or normal task use.
        }
    }

    private static func deletePendingBatch() {
        guard let url = pendingURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

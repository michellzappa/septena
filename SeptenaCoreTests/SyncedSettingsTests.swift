import Foundation
import Testing

/// The synced-settings blob must keep every key the registry syncs (#434):
/// a field without a `CodingKeys` case compiles and is dropped on encode.
@Suite struct SyncedSettingsTests {

  private static let samples: [String: BackendJSON] = [
    "welcomeName": .string("Sam"),
    "telemetryLevel": .string("minimal"),
    "calendarHiddenTitles": .array([.string("Work")]),
    "rolledInDismissedOn": .string("2026-11-25"),
    "homeTimezone": .string("Europe/Amsterdam"),
    "agentsPaused": .bool(true),
    "tasksShowAging": .bool(false),
    "fadeSweptAt": .string("2026-11-22T09:00:00Z"),
    "fadeSweepDismissedOn": .string("2026-11-22"),
    "getStartedDismissed": .bool(true),
    "getStartedSteps": .array([.string("connectAI")]),
    "upsellsSeen": .array([.string("second_device")]),
    "onboardedAt": .string("2026-11-25T06:00:00Z"),
    "accentColor": .string("persimmon"),
    "canvasTexture": .string("topography"),
    "textureIntensity": .int(60),
    "textureMotion": .string("still"),
    "smartListOrder": .array([.string("today"), .string("upcoming")]),
    "smartListHidden": .array([.string("logbook")]),
    "smartListPlacement": .object(["logbook": .string("top")]),
    "listSort": .object(["today": .string("when")]),
  ]

  @Test(arguments: RegistrySettings.syncedKeys)
  func everySyncedKeySurvivesTheBlob(key: String) throws {
    let sample = try #require(Self.samples[key], "add a sample for \(key)")
    var settings = SeptaskSyncedSettings.empty
    #expect(SeptaskSyncedSettings.apply(key, sample, to: &settings))
    let blob = SeptaskSyncedSettings.encode(settings)
    let back = try JSONDecoder().decode(AppSettings.self, from: blob)
    #expect(SeptaskSyncedSettings.value(key, in: back).canonical == sample.canonical)
  }
}

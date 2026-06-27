import Foundation
import CloudKit
import SwiftData

// CoachVoiceRecord — CoachVoiceEntity ↔ CKRecord mapping.
// One record per coach; recordName "coachVoice:{coachKey}" so the coach key
// is the natural id. All dial values are strings (the app maps them to its
// voice enums), so the schema is five strings + reserved slots — additive,
// CK auto-managed in Development.

enum CoachVoiceCloudKitSchema {
  static let recordType = "CoachVoice"

  static func recordName(for id: String) -> String { "coachVoice:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("coachVoice:") ? String(recordName.dropFirst("coachVoice:".count)) : recordName
  }

  enum Field {
    static let warmth = "warmth"
    static let brevity = "brevity"
    static let challenge = "challenge"
    static let formality = "formality"
    static let note = "note"

    // Reserved for foreseeable additions (e.g. a custom name, a spoken-voice
    // id) without bumping the record type.
    static let reservedString1 = "reservedString1"
    static let reservedString2 = "reservedString2"
  }
}

// MARK: - Encode

extension CoachVoiceEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: CoachVoiceCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: CoachVoiceCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[CoachVoiceCloudKitSchema.Field.warmth] = warmth
    record[CoachVoiceCloudKitSchema.Field.brevity] = brevity
    record[CoachVoiceCloudKitSchema.Field.challenge] = challenge
    record[CoachVoiceCloudKitSchema.Field.formality] = formality
    record[CoachVoiceCloudKitSchema.Field.note] = note
    return record
  }
}

// MARK: - Decode

extension CoachVoiceEntity {
  func apply(_ record: CKRecord) {
    if let v = record[CoachVoiceCloudKitSchema.Field.warmth] as? String { warmth = v }
    if let v = record[CoachVoiceCloudKitSchema.Field.brevity] as? String { brevity = v }
    if let v = record[CoachVoiceCloudKitSchema.Field.challenge] as? String { challenge = v }
    if let v = record[CoachVoiceCloudKitSchema.Field.formality] as? String { formality = v }
    note = record[CoachVoiceCloudKitSchema.Field.note] as? String ?? ""
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: CoachVoiceCloudKitSchema.entityID(from: record.recordID.recordName),
              warmth: "", brevity: "", challenge: "", formality: "")
    apply(record)
  }
}

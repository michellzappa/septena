import Foundation
import Testing

/// Covers conversation review derivation for #87 (`needs_verify` -> awaiting
/// human review, not pending agent reasoning; `hasStarted` includes terminal
/// / artifact / handoff states even when no chat turns exist).
@Suite struct ConvoReviewTests {
  @Test func needsVerifyAwaitsHumanReviewWithCustomNote() {
    var convo = TaskConvo()
    convo.assignee = .claude
    convo.endState = .needsVerify
    convo.endStateNote = "Check the diff and confirm the wording"

    let derived = deriveConvo(convo)
    #expect(derived.stage == .awaitingHuman)
    #expect(derived.badge == .needsYou)
    #expect(derived.nextAction == "Check the diff and confirm the wording")
    #expect(derived.pendingReasoning == false)
    #expect(convo.hasStarted == true)
  }

  @Test func needsVerifyFallsBackToDefaultReviewNote() {
    var convo = TaskConvo()
    convo.assignee = .claude
    convo.endState = .needsVerify

    let derived = deriveConvo(convo)
    #expect(derived.stage == .awaitingHuman)
    #expect(derived.badge == .needsYou)
    #expect(derived.nextAction == "Needs review")
    #expect(derived.pendingReasoning == false)
  }

  @Test func openClaudeConvoAfterSendBackIsPendingReasoning() {
    var convo = TaskConvo()
    convo.assignee = .claude
    convo.endState = .open
    convo.thread = [
      ConvoTurn(seq: 1, role: .user, step: .work, note: "Try again with shorter copy", ts: Date())
    ]

    let derived = deriveConvo(convo)
    #expect(derived.pendingReasoning == true)
    #expect(convo.hasStarted == true)
  }

  @Test func artifactOrHandoffMarksConversationStarted() {
    var withArtifact = TaskConvo()
    withArtifact.artifact = ConvoArtifact(kind: "draft-email", title: "Reply", body: "Hello", refs: [])
    #expect(withArtifact.hasStarted == true)

    var withHandoff = TaskConvo()
    withHandoff.handoff = ConvoHandoff(instruction: "Send the email", actionType: .compose, payload: nil)
    #expect(withHandoff.hasStarted == true)
  }
}

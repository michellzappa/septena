# 0035. Make companion voice push-to-talk, unstored and confirmed

- Status: proposed
- Date: 2026-11-24
- Deciders: mz
- Depends on: [ADR 0009](0009-trustable-private-ai.md) (proposed),
  [ADR 0034](0034-companion-devices-get-a-limited-session.md) (proposed)

## Context

A companion device such as the desk orb has microphones. Speaking a task is
faster than picking up a phone. A microphone on a desk is also the thing that
people trust least.

The orb's chip (ESP32-S3) can detect a wake word and a fixed set of commands.
It cannot transcribe free speech. So free speech leaves the orb, and something
else turns it into text. Issue #211 (Ramble mode) sets a default for phones:
audio does not leave the device. That default cannot hold on a device that has
no transcription. The options:

| Where | For | Against |
|---|---|---|
| The user's Mac or phone, on-device | Audio stays with the user's own devices | Needs an awake device and a path to it; fails when neither is near |
| Workers AI, next to the task data | Works always; no new company; self-hosters run it on their own account (ADR 0011) | Septena handles audio; costs money per use; needs ADR 0009 |
| A speech provider | Best quality | A new company hears the user |

## Decision

1. **Push to talk only.** The microphone takes samples only while the user
   holds. No wake word, no listening in the background.
2. **Visible.** While the microphone is on, the whole screen says so.
3. **Never stored.** Audio exists in memory for one transcription, then it is
   gone. It is not in logs, in R2 or in the task.
4. **Confirmed.** The device shows the text. Nothing is written until the user
   accepts it. Silence cancels.
5. **One task per utterance first.** No AI splits or rewrites the words in the
   first version. Title parsing follows `docs/INLINE_CAPTURE_PARSING_SPEC.md`
   when it ships.
6. **Where:** Workers AI *(default)*. The user's own Mac is a later option.
   This needs ADR 0009 accepted, and its "no retention" guarantee checked
   against the provider's terms before any audio is sent.
7. **Off by default** *(default)*. The user turns voice on in the Septena app.

## Consequences

- Voice on a companion waits for ADR 0009. Everything before it does not.
- The privacy page, privacy labels and AI settings copy change before release.
- No hands-free use. We give that up on purpose.
- Transcription has a cost, so it needs a plan limit and an upload size limit.
- #211 keeps its on-device default on phones and the Mac. The two share the
  confirm step.

## Links

`docs/COMPANION_DEVICES_SPEC.md`, #211, ADR 0011

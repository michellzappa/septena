# 0009. Run AI on tasks with checkable privacy guarantees

- Status: proposed
- Date: 2026-11-20
- Deciders: mz

## Context

The current promise is "Septena never runs AI on your tasks and never reads
them." The app enforces it in code and says it in copy:

- `SeptenaCore/AIPolicy.swift` admits only on-device Apple models, Apple
  Private Cloud Compute (PCC) and the user's own Claude. It has deliberately no
  Septena-hosted provider. The rule is zero inference cost to Septena.
- The AI settings pane, the conversation card and `Localizable.xcstrings`
  state the promise. `docs/AI_TASKS_EXPLAINER.md` is its source.

Facts that changed:

- ADR 0002 moves task data to Septena's own backend on Cloudflare. The promise
  "your data lives only in your iCloud" is already gone.
- On-device Foundation Models run only where Apple Intelligence is available.
  Android and web clients (ADR 0002) have no on-device model. PCC needs an
  entitlement we do not have.
- The user's Claude answers asynchronously, through the `pending_reasoning`
  queue. It cannot serve a typing surface.
- Features we want need inference that runs in the background and reaches
  every client. The first one: a suggested title in a project's composer,
  computed when the project's tasks change and shown when the user focuses
  the input.
- Users in all markets ask the same question about AI: who sees my data, and
  is it kept or trained on. A "no AI" promise answers it by refusing the
  feature. Checkable guarantees answer it and keep the feature.

## Decision

Septena may run AI on the user's tasks, including on its own backend, when
every one of these guarantees holds. The product promise becomes
"trustable, private AI", not "no AI".

1. **No training.** No model learns from user data, ours or a provider's.
2. **No retention.** The inference provider keeps no prompts and no outputs.
   We pick providers that state this in their contract, not only in a policy
   page.
3. **No new party where we can avoid it.** Inference runs on the device or
   next to the data. A provider outside the data's processor needs a named
   reason in a spec.
4. **Visible.** Each AI result can show the context it used.
5. **Off is a full app.** One setting turns AI off. Every feature works
   without it, with less help.
6. **Suggest, never act.** AI proposes; the user taps. This rule from
   ADR 0005 and ADR 0006 does not change.

The router tries providers most-private-first: on-device, then PCC, then
Septena-hosted inference, then the user's Claude for steps that need it.
`AIProviderKind` gains a Septena-hosted case. The guarantees are written in
copy that a user can hold us to, the same in every market. We do not frame
them around one region's law.

Open before this ADR is accepted:

- **Hosted provider.** Workers AI (same company as the data store, open-weight
  models) or Anthropic with zero data retention (stronger models, one more
  party).
- **Default.** Hosted AI on by default, or opt-in.
- **Pricing.** Hosted AI only in paid sync (`docs/SYNC_SUBSCRIPTION_SPEC.md`),
  or for every user.

## Consequences

- Background AI becomes possible: the backend can recompute a result when data
  changes and store it with the record, so every client shows it at once.
- AI reaches Android, web and devices without Apple Intelligence.
- We pay for inference per user. This ties AI cost to the subscription.
- We give up "Septena never runs AI on your tasks." The copy in the AI settings
  pane, the conversation card, `Localizable.xcstrings` and
  `docs/AI_TASKS_EXPLAINER.md` must change before a hosted feature ships.
  Privacy labels and the site must change too.
- `AIPolicy` and its "zero inference cost to Septena" comment change. The
  router's admissible list gains the hosted provider in `.auto` mode.
- A provider change becomes a product event: if a provider changes its
  retention or training terms, the guarantees break, and we must switch
  provider or turn hosted AI off.
- The guarantees need enforcement in code, not only in copy: the backend logs
  which context each call sent, and the off switch must stop every hosted call.

## Links

- ADR 0002, ADR 0005, ADR 0006, ADR 0007
- `docs/AI_TASKS_EXPLAINER.md`, `docs/CORE_AI_iOS27_PREP.md`,
  `docs/SYNC_SUBSCRIPTION_SPEC.md`
- `SeptenaCore/AIPolicy.swift`, `SeptenaCore/ReasoningProvider.swift`

import SwiftUI
import SwiftData
import EventKit
import CloudKit
import CoreLocation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

struct AboutSettingsPane: View {
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }
  private var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }

  var body: some View {
    Form {
      Section {
        VStack(alignment: .center, spacing: 14) {
          AppIconPreview(option: .default, size: 72)
            .padding(.top, 4)
          VStack(spacing: 4) {
            Text("Septena")
              .font(.septenaWordmark)
            Text("One app for every corner of your life")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          Text("Version \(version) (\(build))")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
      }

      Section {
        Text("Septena keeps the everyday things you track in one place: tasks, habits, what you eat, how you sleep. It syncs across your devices over iCloud and stays yours alone — and it's open source, so you can read exactly how it handles your data.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("Links") {
        outboundLink("Website", destination: "https://septena.app", icon: "globe")
        outboundLink("Telegram", destination: "https://t.me/septena_app", icon: "paperplane")
        NavigationLink(value: SettingsView.SettingsDestination.support) {
          Label("Support", systemImage: "lifepreserver")
        }
        outboundLink("Source code", destination: "https://github.com/septena/septena", icon: "chevron.left.forwardslash.chevron.right")
        outboundLink("License", destination: "https://opensource.org/licenses/MIT", icon: "doc.text")
      }

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.whatsNew) {
          Label("What's New", systemImage: "megaphone")
        }
        infoRow("Platform", platformLabel)
      }

      Section {
        NavigationLink(value: SettingsView.SettingsDestination.advanced) {
          Label("Advanced", systemImage: "wrench.and.screwdriver")
        }
      } footer: {
        Text("Developer and recovery tools. Safe to ignore in normal use.")
      }
    }
    .formStyle(.grouped)
  }

  private var platformLabel: String {
    #if os(macOS)
    return "macOS"
    #else
    return "iOS · iPadOS"
    #endif
  }

  private func outboundLink(_ title: String, destination: String, icon: String) -> some View {
    Link(destination: URL(string: destination)!) {
      HStack {
        Label(title, systemImage: icon)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private func infoRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .font(.callout.monospacedDigit())
    }
  }
}

// MARK: - Advanced (developer + diagnostics)

/// The one quiet door, reached from About, for surfaces that aren't part of the
/// everyday consumer flow: the motion test bench, data recovery tools, and the
/// macOS reasoning-provider override. Keeps the main panes App-Store clean
/// without deleting tools the developer (and the occasional power user) needs.
struct AdvancedSettingsPane: View {
  @Environment(SettingsStore.self) private var store
  #if os(macOS)
  @AppStorage(AIPolicy.devForceProviderKey) private var devForce = ""
  #endif
  @State private var welcomeReset = false

  var body: some View {
    Form {
      Section {
        NavigationLink(value: SettingsView.SettingsDestination.motionGallery) {
          Label("Motion Gallery", systemImage: "wand.and.rays")
        }
        NavigationLink(value: SettingsView.SettingsDestination.dataTools) {
          Label("Data Tools", systemImage: "stethoscope")
        }
        #if DEBUG
        NavigationLink(value: SettingsView.SettingsDestination.milestonePreview) {
          Label("Milestones (preview)", systemImage: "flag.checkered")
        }
        #endif
      } header: {
        Text("Diagnostics")
      } footer: {
        Text("Motion Gallery tunes the logging flourishes. Data Tools re-pulls records from CloudKit and generates LLM import prompts.")
      }

      Section {
        Button {
          store.resetWelcomeForTesting()
          welcomeReset = true
        } label: {
          Label("Reset first-run welcome", systemImage: "arrow.counterclockwise")
        }
      } header: {
        Text("Onboarding")
      } footer: {
        Text(welcomeReset
             ? "The welcome will appear over the app now, and on relaunch until you complete it. Only this device is affected."
             : "Re-shows the first-run welcome (section picker + section intros) on this device, for testing. Doesn't change your data or your other devices.")
      }

      #if os(macOS)
      Section {
        Picker("Force provider", selection: $devForce) {
          Text("Off (use the AI mode)").tag("")
          ForEach(AIProviderKind.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
        }
      } header: {
        Text("AI provider override")
      } footer: {
        Text("Pins every reasoning step to one provider — for testing only. Leave Off in normal use.")
      }
      #endif
    }
    .formStyle(.grouped)
  }
}

// MARK: - Milestone preview bench
//
// Fires each milestone celebration on demand through the SAME tiering a real
// crossing uses (`MilestonePresenter.style(for:)`), rendered in a local
// overlay so it's visible inside Settings. No store writes, no detection —
// pure "what does this celebration look like." The synthetic milestones are
// constructed in-memory and never inserted into a ModelContext.
struct MilestonePreviewPane: View {
  @Environment(SectionTheme.self) private var theme
  @State private var style: LogCommitStyle?
  @State private var trigger = 0

  /// One row per distinct celebration the presenter can produce. Values
  /// mirror what the detectors write so the labels read realistically.
  private struct Sample: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let make: () -> GoalMilestoneEntity
  }

  private static func milestone(scope: String, kind: String, rungKey: String,
                                label: String, value: Double) -> GoalMilestoneEntity {
    GoalMilestoneEntity(id: "preview|\(rungKey)", goalID: nil, scope: scope,
                        kind: kind, rungKey: rungKey, label: label,
                        value: value, occurredAt: .now, celebrated: true)
  }

  private let samples: [Sample] = [
    .init(id: "streak", title: "Streak rung",
          subtitle: "Habit hits a 30-day streak → Ignition",
          make: { milestone(scope: "habit:demo", kind: "streak",
                            rungKey: "streak:30", label: "Meditate: 30-day streak",
                            value: 30) }),
    .init(id: "pr", title: "Training PR",
          subtitle: "Heaviest-ever set → milestone card",
          make: { milestone(scope: "exercise:bench-press", kind: "pr",
                            rungKey: "pr:100", label: "Bench Press PR: 100 kg",
                            value: 100) }),
    .init(id: "target", title: "Goal target reached",
          subtitle: "Smoothed value crosses the target → milestone card",
          make: { milestone(scope: "goal:demo", kind: "rung",
                            rungKey: "target", label: "Target reached: 74 kg",
                            value: 74) }),
    .init(id: "held30", title: "Held 30 days",
          subtitle: "Maintenance — stayed on target a month → milestone card",
          make: { milestone(scope: "goal:demo", kind: "rung",
                            rungKey: "held30", label: "Held 74 kg for 30 days",
                            value: 74) }),
    .init(id: "rung", title: "Intermediate rung",
          subtitle: "Per-kg grid rung → quiet burst",
          make: { milestone(scope: "goal:demo", kind: "rung",
                            rungKey: "lvl:78", label: "Trailing average crossed 78 kg",
                            value: 78) }),
    .init(id: "xp", title: "Volume XP",
          subtitle: "Lifetime-tonnage rung → quiet burst",
          make: { milestone(scope: "training.volume", kind: "xp",
                            rungKey: "xp:50t", label: "Lifetime volume: 50 tonnes",
                            value: 50000) }),
  ]

  var body: some View {
    Form {
      Section {
        ForEach(samples) { sample in
          Button { fire(sample) } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(sample.title).foregroundStyle(.primary)
              Text(sample.subtitle).font(.caption).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("Tap to play")
      } footer: {
        Text("Each fires the real MilestonePresenter tiering — streaks and goal target/held get the full card, intermediate rungs and XP get the quiet burst. Under Reduce Motion the visual is suppressed by design.")
      }
    }
    .formStyle(.grouped)
    .overlay {
      if let style {
        LogCommitStyleView(style: style, trigger: trigger)
          .allowsHitTesting(false)
      }
    }
  }

  private func fire(_ sample: Sample) {
    style = MilestonePresenter.style(for: sample.make(), theme: theme)
    trigger &+= 1
    Haptics.success()
  }
}

// MARK: - Shared pane helpers

private func row(_ label: String, _ value: String) -> some View {
  HStack {
    Text(label)
    Spacer()
    Text(value)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.trailing)
  }
}

// MARK: - Import & Export
//
// One pane for getting data in and out of Septena. Export produces a
// stable JSON envelope per section (and an "Everything" bundle); import
// parses the same envelope, validates it against the local schema, and
// previews per-table counts before any writes land. The JSON format is
// designed to round-trip — anything exported here is a valid import.
//
// Envelope shape (stable, versioned):
//   {
//     "septena_export_version": 1,
//     "section": "<section key>" | "all",
//     "exported_at": "<ISO-8601>",
//     "app_version": "<CFBundleShortVersionString> (<CFBundleVersion>)",
//     "tables": {
//        "<table_name>": [ { ...record... }, ... ],
//        ...
//     }
//   }
//
// Sections that aren't backed by exportable local entities (e.g.
// `activity`, `sleep`) are skipped — Import/Export only lists what it
// can actually produce.

import UniformTypeIdentifiers

// MARK: - Skills

/// Top-level Skills page. Lists every section that has an MCP skill brief,
/// plus a "Connection" row at top showing the universal preamble. Each row
/// navigates to a `SectionSkillView`.
///
/// Skills are static content (defined in `SectionSkill.all`); this pane
/// just renders them. To add a section, edit `SectionSkill.swift`.
struct SkillsSettingsPane: View {
  @Environment(SettingsStore.self) private var store

  /// Show section skills in the user's actual sidebar order when possible,
  /// falling back to the catalog order in `SectionSkill.all`. Skills for
  /// sections the user doesn't have installed are still shown — they're
  /// informational, and someone evaluating which sections to enable
  /// benefits from previewing the skill content.
  private var orderedKeys: [String] {
    let order = store.serverSettings?.sectionOrder ?? []
    let known = SectionSkill.allKnownKeys
    let head  = order.filter { known.contains($0) }
    let rest  = known.subtracting(head).sorted()
    return head + rest
  }

  var body: some View {
    Form {
      Section {
        NavigationLink {
          SkillPreambleView()
        } label: {
          Label("Connection & conventions", systemImage: "antenna.radiowaves.left.and.right")
        }
      } header: {
        Text("MCP")
      } footer: {
        Text("Connect Claude or another MCP client to mcp.septena.app to read and write your Septena data. The brief below is what the model needs to know to use the connection well.")
      }

      Section {
        ForEach(orderedKeys, id: \.self) { key in
          if let skill = SectionSkill.resolve(key) {
            NavigationLink {
              SectionSkillView(sectionKey: key)
            } label: {
              skillRowLabel(for: key, skill: skill)
            }
          }
        }
      } header: {
        Text("Section skills")
      } footer: {
        Text("Each brief teaches a model how to use one section through the MCP — tools available, conventions, examples.")
      }

      Section {
        Button {
          SkillCopy.copy(SectionRegistry.fullSkillMarkdown())
          showCopiedToast = true
        } label: {
          Label("Copy MCP gateway brief", systemImage: "doc.on.doc")
        }
      } header: {
        Text("Gateway sync")
      } footer: {
        Text("Copies the preamble + every section's brief as one Markdown document. Paste into septena-mcp-gateway/skill.md so the LLM-facing catalog can't drift from the plugin definitions in this app.")
      }
    }
    .formStyle(.grouped)
    .overlay(alignment: .bottom) {
      if showCopiedToast {
        Text("Copied")
          .font(.callout)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(.thinMaterial, in: Capsule())
          .padding(.bottom, 24)
          .transition(.opacity)
          .task {
            try? await Task.sleep(for: .seconds(1.4))
            showCopiedToast = false
          }
      }
    }
    .animation(.snappy, value: showCopiedToast)
  }

  @State private var showCopiedToast = false

  @ViewBuilder
  private func skillRowLabel(for key: String, skill: SectionSkill) -> some View {
    let entry = store.sections.first(where: { $0.key == key })
    let label = SectionManifest.displayLabel(key: key, stored: entry?.label ?? "")
    let color = parseHexColor(entry?.color ?? "")
    HStack(spacing: 12) {
      ColoredGlyph(icon: skillSectionIcon(key: key), color: color, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(label).foregroundStyle(.primary)
        Text(skill.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func skillSectionIcon(key: String) -> String {
    return SectionManifest.byKey[key]?.iconSymbol ?? "circle.fill"
  }
}

/// Per-section skill detail. Reused by both the Skills top-level pane
/// (via SkillsSettingsPane) and the bottom of each section's settings
/// page (via SectionDetailPane.skillAndDataSection).
struct SectionSkillView: View {
  @Environment(SettingsStore.self) private var store
  let sectionKey: String

  private var skill: SectionSkill? { SectionSkill.resolve(sectionKey) }
  private var label: String {
    SectionManifest.displayLabel(
      key: sectionKey,
      stored: store.sections.first(where: { $0.key == sectionKey })?.label ?? "")
  }

  var body: some View {
    Form {
      if let skill {
        Section {
          Text(skill.summary)
            .font(.callout)
            .foregroundStyle(.primary)
        } header: {
          Text("\(label) skill")
        }

        Section("Tools") {
          ForEach(skill.tools, id: \.name) { tool in
            VStack(alignment: .leading, spacing: 3) {
              Text(tool.name)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
              Text(tool.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
              if let inputs = tool.inputs {
                Text(inputs)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .padding(.vertical, 3)
          }
        }

        Section("Conventions & examples") {
          Text(.init(skill.body))
            .font(.callout)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
        }

        Section {
          Button {
            SkillCopy.copy(skill.fullMarkdown)
          } label: {
            Label("Copy full skill", systemImage: "doc.on.doc")
          }
          ShareLink(item: skill.fullMarkdown) {
            Label("Share…", systemImage: "square.and.arrow.up")
          }
        } footer: {
          Text("The copied text includes the connection preamble + this section's brief — paste it into an MCP client's system prompt or a Claude conversation to teach it how to use the section.")
        }
      } else {
        Section {
          Label("No skill yet", systemImage: "questionmark.circle")
            .foregroundStyle(.secondary)
        } footer: {
          Text("This section doesn't yet have MCP tools. A skill will appear here when it does.")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("\(label) skill")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// Connection preamble shown above all section skills. Static content
/// pulled from `SectionSkill.preamble`.
struct SkillPreambleView: View {
  var body: some View {
    Form {
      Section {
        MCPConnectionDiagram()
      } footer: {
        Text("Your data stays in your private iCloud. Connecting an AI just opens a door into it — one you control and can revoke.")
      }
      Section {
        Text(.init(SectionSkill.preamble))
          .font(.callout)
          .textSelection(.enabled)
      }
      Section {
        Button {
          SkillCopy.copy(SectionSkill.preamble)
        } label: {
          Label("Copy preamble", systemImage: "doc.on.doc")
        }
        ShareLink(item: SectionSkill.preamble) {
          Label("Share…", systemImage: "square.and.arrow.up")
        }
      } footer: {
        Text("Universal conventions every section relies on. Each section skill below extends this.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Connection & conventions")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

/// Tiny cross-platform pasteboard wrapper. Lives at file scope so all
/// skill views (and the per-section detail pane footer) share one impl.
enum SkillCopy {
  static func copy(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
  }
}

import SwiftUI

struct DiscoveryStepPills: View {
  let current: Int
  let total: Int
  let accent: Color

  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<total, id: \.self) { index in
        Capsule()
          .fill(index <= current ? accent : Color.secondary.opacity(0.22))
          .frame(width: index == current ? 28 : 7, height: 7)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    #if os(iOS)
    .glassEffect(.regular, in: .capsule)
    #else
    .background(.thinMaterial, in: Capsule())
    #endif
    .accessibilityLabel("Step \(current + 1) of \(total)")
  }
}

struct DiscoveryPrimaryAction: View {
  let title: String
  let systemImage: String
  let accent: Color
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.headline.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    // Light accents (lime/yellow/amber) fail WCAG with white ink — pick ink from
    // the fill. System glass can wash a lime toward `#d6f249`; dark ink stays
    // readable there, white does not.
    .foregroundStyle(disabled ? Color.secondary : AdaptiveColor.inkOnSolidFill(accent))
    .background(disabled ? Color.secondary.opacity(0.16) : accent, in: Capsule())
    #if os(iOS)
    .glassEffect(.regular.tint(disabled ? Color.clear : accent.opacity(0.42)).interactive(), in: .capsule)
    #else
    .shadow(color: disabled ? .clear : accent.opacity(0.22), radius: 14, y: 8)
    #endif
    .disabled(disabled)
  }
}

struct DiscoverySecondaryAction: View {
  let title: String
  let systemImage: String
  let accent: Color
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .foregroundStyle(disabled ? Color.secondary : accent)
    .background(Color.secondary.opacity(0.09), in: Capsule())
    #if os(iOS)
    .glassEffect(.regular.interactive(), in: .capsule)
    #else
    .background(.thinMaterial, in: Capsule())
    #endif
    .disabled(disabled)
  }
}

struct DiscoveryBottomBar: View {
  let accent: Color
  let primaryTitle: String?
  let primarySystemImage: String
  var primaryDisabled = false
  var backDisabled = false
  let onBack: () -> Void
  let onPrimary: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: onBack) {
        Image(systemName: "chevron.left")
          .font(.headline.weight(.semibold))
          .frame(width: 48, height: 48)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(backDisabled ? Color.secondary : Color.primary)
      .background(Color.secondary.opacity(0.10), in: Circle())
      #if os(iOS)
      .glassEffect(.regular.interactive(), in: .circle)
      #else
      .background(.thinMaterial, in: Circle())
      #endif
      .disabled(backDisabled)
      .accessibilityLabel("Back")

      if let primaryTitle {
        DiscoveryPrimaryAction(
          title: primaryTitle,
          systemImage: primarySystemImage,
          accent: accent,
          disabled: primaryDisabled,
          action: onPrimary
        )
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .background {
      LinearGradient(
        colors: [
          Theme.groupedBackground.opacity(0),
          Theme.groupedBackground.opacity(0.86),
          Theme.groupedBackground,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    }
  }
}

struct DiscoverySelectedPills: View {
  let title: String
  let items: [String]
  let accent: Color
  let onRemove: (String) -> Void

  var body: some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)

        FlowLayout(spacing: 8) {
          ForEach(items, id: \.self) { item in
            Button {
              onRemove(item)
              Haptics.tick()
            } label: {
              HStack(spacing: 6) {
                Text(item)
                  .font(.callout.weight(.semibold))
                  .lineLimit(1)
                Image(systemName: "xmark.circle.fill")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(accent.opacity(0.72))
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .foregroundStyle(accent)
              .background(accent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
          }
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }
}

struct DiscoveryPillTextInput: View {
  let placeholder: String
  @Binding var text: String
  let accent: Color
  let onSubmit: () -> Void

  private var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "plus")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(accent)

      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .submitLabel(.done)
        .onSubmit(onSubmit)

      Button(action: onSubmit) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title3.weight(.semibold))
          .foregroundStyle(isEmpty ? Color.secondary.opacity(0.55) : accent)
      }
      .buttonStyle(.plain)
      .disabled(isEmpty)
      .accessibilityLabel("Add")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color.secondary.opacity(0.10), in: Capsule())
    #if os(iOS)
    .glassEffect(.regular.interactive(), in: .capsule)
    #else
    .background(.thinMaterial, in: Capsule())
    #endif
  }
}

struct DiscoveryResultView: View {
  let title: String
  let subtitle: String
  let drafts: [DraftGoal]
  let accent: Color
  let onReview: () -> Void
  let onRegenerate: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Label(title, systemImage: "checkmark.seal.fill")
            .font(.title2.weight(.semibold))
            .foregroundStyle(accent)
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        VStack(spacing: 12) {
          ForEach(drafts) { draft in
            VStack(alignment: .leading, spacing: 8) {
              Label(draft.kind == .purpose ? "North-star" : "Commitment",
                    systemImage: draft.kind == .purpose ? "flame.fill" : "checkmark.seal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
              Text(draft.text)
                .font(draft.kind == .purpose ? .headline : .subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
        }

        DiscoveryPrimaryAction(title: "Review & Save",
                               systemImage: "square.and.arrow.down",
                               accent: accent,
                               action: onReview)

        DiscoverySecondaryAction(title: "Regenerate",
                                 systemImage: "arrow.clockwise",
                                 accent: accent,
                                 action: onRegenerate)
      }
      .padding()
    }
  }
}

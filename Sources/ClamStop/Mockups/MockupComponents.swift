import SwiftUI

/// Small gray tag such as "Recommended".
struct TagBadge: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// Large selectable choice of the first-run screens: icon, title, one line of explanation,
/// optional badge and an information line shown once selected. Selection is shown by a check mark and a border, not color alone.
struct ChoiceCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var recommended = false
    var info: LocalizedStringKey?
    /// Shown once selected, for a choice with a real risk (orange, with a warning sign).
    var warning: LocalizedStringKey?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                        if recommended { TagBadge("Recommended") }
                    }
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isSelected, let info {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            Text(info)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                        .padding(.top, 2)
                    }
                    if isSelected, let warning {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .accessibilityLabel("Warning")
                            Text(warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Marks a setting that ClamStop advises to keep on.
struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .fixedSize()
    }
}

/// A switch's title followed by the badge, one element for VoiceOver.
struct RecommendedTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            RecommendedBadge()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A settings row: title and a one-line note on the left, the control on the right.
struct OptionRow<Control: View>: View {
    let title: LocalizedStringKey
    var note: LocalizedStringKey?
    var recommended = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if recommended { RecommendedBadge() }
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            control()
        }
    }
}

/// Switch row; the switch carries the title as its VoiceOver label.
struct ToggleRow: View {
    let title: LocalizedStringKey
    var note: LocalizedStringKey?
    var recommended = false
    @Binding var isOn: Bool

    var body: some View {
        OptionRow(title: title, note: note, recommended: recommended) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

import SwiftUI

/// Small "Pro" tag next to a locked feature. Text, not color alone; VoiceOver reads "Pro feature".
struct ProBadge: View {
    var body: some View {
        Text("Pro")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .accessibilityLabel("Pro feature")
    }
}

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
/// optional badge and warning. Selection is shown by a check mark and a border, not color alone.
struct ChoiceCard: View {
    enum Badge {
        case recommended
        case pro
    }

    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var badge: Badge?
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
                        switch badge {
                        case .recommended: TagBadge("Recommended")
                        case .pro: ProBadge()
                        case nil: EmptyView()
                        }
                    }
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isSelected, let warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
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

/// A settings row: title (with an optional Pro badge) and a one-line note on the left, the
/// control on the right. Locked Pro controls stay readable but disabled.
struct OptionRow<Control: View>: View {
    let title: LocalizedStringKey
    var note: LocalizedStringKey?
    var pro = false
    var locked = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if pro { ProBadge() }
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
                .disabled(locked)
        }
    }
}

/// Switch row; the switch carries the title as its VoiceOver label.
struct ToggleRow: View {
    let title: LocalizedStringKey
    var note: LocalizedStringKey?
    var pro = false
    var locked = false
    @Binding var isOn: Bool

    var body: some View {
        OptionRow(title: title, note: note, pro: pro, locked: locked) {
            // A locked Pro switch shows off: the feature is not active without Pro.
            Toggle(title, isOn: locked ? .constant(false) : $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// Section header with a symbol, as in System Settings.
struct SectionHeader: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
    }
}

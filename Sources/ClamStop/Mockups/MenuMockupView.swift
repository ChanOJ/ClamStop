import SwiftUI

/// Drawing of the menu bar menu (spec section 5 "Menu bar menu") with the Stay Awake submenu
/// open. Only a mockup: a real NSMenu cannot be rendered to an image, so this SwiftUI view
/// imitates one. The real menu stays a `MenuBarExtra` menu built from the same items.
struct MenuMockupView: View {
    @ObservedObject var model: MockupModel
    @Environment(\.colorScheme) private var colorScheme

    private var showsSubmenu: Bool { model.menuState == .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            menuBar
            HStack(alignment: .top, spacing: 2) {
                mainMenu
                if showsSubmenu {
                    stayAwakeSubmenu
                        .padding(.top, 52)
                }
            }
            .padding(.leading, 150)
        }
        .padding(.bottom, 24)
        .frame(width: 800, alignment: .topLeading)
        .background(LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.10, green: 0.13, blue: 0.22), Color(red: 0.20, green: 0.12, blue: 0.24)]
                : [Color(red: 0.62, green: 0.75, blue: 0.92), Color(red: 0.86, green: 0.78, blue: 0.90)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    // MARK: Menu bar strip

    private var menuBar: some View {
        HStack(spacing: 14) {
            Spacer()
            HStack(spacing: 4) {
                Image(nsImage: ClamGlyph.image)
                    .renderingMode(.template)
                if model.menuState == .session && model.isPro {
                    Text(verbatim: "1h42")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.18)))
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(verbatim: "Thu 26 Nov  21:40")
                .font(.system(size: 13))
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .foregroundStyle(.primary)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.25))
    }

    // MARK: Menus

    private var mainMenu: some View {
        MenuPanel(width: 330) {
            switch model.menuState {
            case .idle:
                MenuStatus(title: "Sleeps when you close the lid",
                           detail: model.edition.hasBackgroundService ? "Stops using the battery after 1 hour asleep" : nil)
                MenuSeparator()
                MenuItem(title: "Stay Awake", icon: .symbol("cup.and.saucer"), hasSubmenu: true, highlighted: true)
            case .session:
                // Free: the lid-closed part of a session needs power (spec C2).
                MenuStatus(title: "Staying awake: 1 h 42 min left",
                           detail: model.isPro ? "Even if you close the lid" : "Even if you close the lid, while charging")
                MenuSeparator()
                MenuItem(title: "Stop Staying Awake", icon: .symbol("cup.and.saucer.fill"))
                MenuItem(title: "Stay Awake", icon: .symbol("cup.and.saucer"), hasSubmenu: true)
            }
            MenuItem(title: "Sleep Now", icon: .symbol("moon"))
            if model.edition.hasBackgroundService {
                MenuItem(title: "Hibernate Now", icon: .symbol("snowflake"),
                         pro: !model.isPro, disabled: !model.isPro)
            }
            MenuSeparator()
            MenuItem(title: "Settings…", icon: .symbol("gearshape"), shortcut: "⌘,")
            MenuItem(title: "Quit ClamStop", icon: .symbol("door.left.hand.open"), shortcut: "⌘Q")
        }
    }

    private var stayAwakeSubmenu: some View {
        let locked = !model.isPro
        return MenuPanel(width: 230) {
            MenuItem(title: "Until I Turn It Off")
            MenuSeparator()
            MenuItem(title: "5 Minutes")
            MenuItem(title: "10 Minutes")
            MenuItem(title: "15 Minutes")
            MenuItem(title: "30 Minutes")
            MenuItem(title: "1 Hour")
            MenuItem(title: "2 Hours")
            MenuItem(title: "5 Hours")
            MenuItem(title: "8 Hours")
            MenuSeparator()
            MenuItem(title: "Until…", pro: locked, disabled: locked)
            MenuItem(title: "While an App Runs…", pro: locked, disabled: locked)
        }
    }
}

/// Rounded menu background with the system menu's look (solid, since vibrancy does not render
/// in snapshots).
private struct MenuPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(5)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.95)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

private struct MenuStatus: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            MenuIcon(icon: .clam)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.semibold)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}

/// Leading icon of a menu item: an SF Symbol, or the ClamStop clam.
private enum MenuIconKind {
    case symbol(String)
    case clam
}

private struct MenuIcon: View {
    let icon: MenuIconKind

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name): Image(systemName: name)
            case .clam: Image(nsImage: ClamGlyph.image).renderingMode(.template)
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

private struct MenuItem: View {
    let title: LocalizedStringKey
    var icon: MenuIconKind?
    var shortcut: String?
    var hasSubmenu = false
    var highlighted = false
    var pro = false
    var disabled = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon { MenuIcon(icon: icon) }
            Text(title)
            if pro { ProBadge() }
            Spacer(minLength: 16)
            if let shortcut {
                Text(verbatim: shortcut)
                    .foregroundStyle(highlighted ? Color.white : Color.secondary)
            }
            if hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(highlighted ? Color.white : disabled ? Color.secondary : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.accentColor : Color.clear))
    }
}

private struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }
}

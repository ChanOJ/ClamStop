import AppKit
import SwiftUI

/// About window. Full edition: website, source code and a discreet "Buy me a coffee" link
/// (spec J6). Store edition: only a neutral Help link, no donation link and nothing pointing to
/// the full edition (App Store guideline 3.1.1, spec section 6).
struct AboutView: View {
    @ObservedObject var model: MockupModel

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(verbatim: "ClamStop")
                .font(.title.bold())
            Text("Version \("1.0 (42)")")
                .foregroundStyle(.secondary)
            Text("Puts your MacBook to sleep when you close the lid, even with a screen plugged in, or keeps it awake when you choose.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 16) {
                if model.edition == .full {
                    Link("Website", destination: Links.website)
                    Link("Source code", destination: URL(string: "https://github.com/ChanOJ/ClamStop")!)
                } else {
                    Link("Help", destination: Links.help)
                }
            }
            .padding(.top, 4)
            if model.edition == .full {
                VStack(spacing: 4) {
                    Text("ClamStop is free and open source. You can help pay for the developer account, and the time spent building it.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Buy me a coffee", destination: Links.donation)
                }
                .font(.footnote)
                .padding(.top, 4)
            }
            Text(verbatim: "© 2026 ChanOJ · MIT License")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 340)
    }
}

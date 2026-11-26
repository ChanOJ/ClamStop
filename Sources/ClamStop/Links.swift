import Foundation

/// Web links shown in the app.
enum Links {
    /// "Buy me a coffee" (full edition only: the Store edition has no donation link, App Store
    /// guideline 3.1.1). Placeholder: the GitHub Sponsors account does not exist yet.
    static let donation = URL(string: "https://github.com/sponsors/ChanOJ")!
    static let website = URL(string: "https://chanoj.github.io/ClamStop/")!
    static let sourceCode = URL(string: "https://github.com/ChanOJ/ClamStop")!
    /// Neutral help page, the only web link of the Store edition (spec section 6).
    static let help = URL(string: "https://chanoj.github.io/ClamStop/help/")!
}

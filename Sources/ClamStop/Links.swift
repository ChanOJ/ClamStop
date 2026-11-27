import Foundation

/// Web links shown in the app.
enum Links {
    /// "Buy me a coffee" (full edition only: the Store edition has no donation link, App Store
    /// guideline 3.1.1). A Stripe Payment Link in the name of the developer's company, where the
    /// donor chooses the amount. Placeholder: the link does not exist yet.
    static let donation = URL(string: "https://buy.stripe.com/placeholder")!
    static let website = URL(string: "https://chanoj.github.io/ClamStop/")!
    static let sourceCode = URL(string: "https://github.com/ChanOJ/ClamStop")!
    /// Neutral help page, the only web link of the Store edition (spec section 6).
    static let help = URL(string: "https://chanoj.github.io/ClamStop/help/")!
}

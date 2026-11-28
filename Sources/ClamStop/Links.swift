import Foundation

/// Web links shown in the app.
enum Links {
    /// "Buy me a coffee" (full edition only: the Store edition has no donation link, App Store
    /// guideline 3.1.1). A Stripe Payment Link in the name of the developer's company, where the
    /// donor chooses the amount.
    static let donation = URL(string: "https://buy.stripe.com/9B600j1BrbSu2p9bCL6J200")!
    static let website = URL(string: "https://chanoj.github.io/ClamStop/")!
    static let sourceCode = URL(string: "https://github.com/ChanOJ/ClamStop")!
    /// "Vote for features" (full edition only): the feature ideas, most upvoted first.
    static let featureVote = URL(string: "https://github.com/ChanOJ/ClamStop/discussions/categories/ideas?discussions_q=is%3Aopen+sort%3Atop")!
    /// "Report by Email…": an alias for ClamStop alone, so that it can be turned off if spammed.
    static let reportEmail = "clamstop.bmm1z@passmail.net"
    /// Neutral help page, the only web link of the Store edition (spec section 6).
    static let help = URL(string: "https://chanoj.github.io/ClamStop/help/")!
}

/// Website build (Developer ID, background service) or Mac App Store build (sandbox,
/// docs/app-store-edition.md).
enum Edition {
    case full
    case store

    /// This build. Only the full edition exists so far; the Mac App Store build will be `.store`
    /// (no background service, no donation link: spec section 6).
    static let current = Edition.full

    var hasBackgroundService: Bool { self == .full }
}

extension Edition {
    /// This build. Only the full edition exists so far; the Mac App Store build will be `.store`
    /// (no background service, no donation link: spec section 6).
    static let current = Edition.full
}

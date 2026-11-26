import Testing
@testable import ClamStopShared

@Test func daemonPlistMatchesLabel() {
    #expect(ClamStopID.daemonPlistName == ClamStopID.daemonLabel + ".plist")
}

import Testing
@testable import WhatCableDarwinBackend

/// `fetchMacModel` is a thin wrapper around the `hw.model` sysctl. There's
/// no fake sysctl to swap in, so this just checks it returns something
/// sane on the real hardware running the test, mirroring how other Reading/
/// tests (e.g. SMCPowerReaderTests) treat live IOKit/sysctl reads.
struct DarwinSystemInfoTests {
    @Test("fetchMacModel returns a non-empty model string")
    func fetchMacModelReturnsNonEmptyString() {
        let model = DarwinSystemInfo.fetchMacModel()
        #expect(!model.isEmpty)
        // "unknown" is only the fallback for a failed sysctl call; on any
        // real Mac running this test, the call succeeds.
        #expect(model != "unknown")
    }
}

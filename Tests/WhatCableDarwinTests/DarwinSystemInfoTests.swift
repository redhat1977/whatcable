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

    // MARK: - isIntelHardware

    /// The rows that matter. Only the last one is Intel; everything else is an
    /// Apple Silicon Mac that must NOT see the unsupported-hardware notice.
    ///
    /// The Rosetta row is the reason this function exists at all: a plain
    /// `#if arch(x86_64)` check reports true there, on a Mac where WhatCable
    /// works perfectly. Verified live on an M5: running the x86_64 slice reads
    /// procTranslated=1, arm64Optional=1.
    @Test("isIntelHardware truth table", arguments: [
        // (procTranslated, arm64Optional, isIntel, description)
        (.value(0), .value(1), false, "native Apple Silicon"),
        (.value(1), .value(1), false, "Apple Silicon, x86_64 slice under Rosetta"),
        (.value(1), .absent, false, "Rosetta hiding hw.optional.arm64"),
        (.value(1), .failed, false, "Rosetta, arm64 read failed: still Rosetta, still not Intel"),
        (.absent, .absent, true, "real Intel Mac: neither sysctl exists"),
        (.failed, .absent, true, "Intel, proc_translated read failed: arm64 absent still says Intel"),
        (.absent, .value(0), true, "arm64 sysctl present but 0: not an arm64 Mac"),
        // The conservative rows. We know nothing, so we say nothing: a false
        // "your Mac is unsupported" on a working Mac is the worse failure.
        (.absent, .failed, false, "arm64 read failed: unknown, don't claim Intel"),
        (.failed, .failed, false, "both reads failed: unknown, don't claim Intel"),
    ] as [(DarwinSystemInfo.SysctlRead, DarwinSystemInfo.SysctlRead, Bool, String)])
    func isIntelHardwareTruthTable(
        procTranslated: DarwinSystemInfo.SysctlRead,
        arm64Optional: DarwinSystemInfo.SysctlRead,
        expected: Bool,
        what: String
    ) {
        #expect(
            DarwinSystemInfo.isIntelHardware(procTranslated: procTranslated, arm64Optional: arm64Optional) == expected,
            "\(what)"
        )
    }

    /// Guards the absent-vs-failed distinction the Intel row depends on. A real
    /// Intel Mac is identified by these sysctls being ENOENT, so if an absent
    /// key ever came back as `.failed` the detection would silently stop
    /// working (and, by design, fail quiet rather than loud).
    @Test("sysctlFlag reports a non-existent sysctl as absent, not failed")
    func sysctlFlagAbsentIsAbsent() {
        #expect(DarwinSystemInfo.sysctlFlag("whatcable.no.such.sysctl") == .absent)
    }

    /// A sysctl that exists but isn't Int32-shaped must not be half-read into a
    /// bogus value. hw.memsize is 8 bytes.
    @Test("sysctlFlag rejects a wrong-width sysctl rather than truncating")
    func sysctlFlagWrongWidthIsFailed() {
        #expect(DarwinSystemInfo.sysctlFlag("hw.memsize") == .failed)
    }

    // The live read on the machine running the tests. Guarded to arm64 because
    // this asserts an Apple-Silicon-specific answer: on a real Intel Mac the
    // correct result is the opposite, and an unguarded test would fail there,
    // on the exact hardware this feature is for.
    //
    // Unlike `#if arch(x86_64)` (which is wrong for detection, because Rosetta
    // runs the x86_64 slice on Apple Silicon), `#if arch(arm64)` really does
    // imply Apple Silicon: nothing translates arm64 onto an Intel Mac.
    //
    // This proves the real sysctl names are still spelled right. It would pass
    // even with the decision broken shut, which is what the truth table is for.
    #if arch(arm64)
    @Test("isIntelHardware is false on the Apple Silicon running these tests")
    func isIntelHardwareFalseOnThisMac() {
        #expect(DarwinSystemInfo.sysctlFlag("hw.optional.arm64") == .value(1), "test host is not Apple Silicon?")
        #expect(DarwinSystemInfo.isIntelHardware() == false)
    }
    #endif
}

import Foundation
import Darwin

/// Reads the Mac model identifier (e.g. "Mac15,3") via `sysctlbyname`.
///
/// This used to live in `WhatCableCore`, but Core has to stay free of
/// Darwin-only APIs so it can eventually build for a non-Darwin (e.g. Linux)
/// backend. The lookup moved back here, to the Darwin-specific layer, which
/// is its original home before an earlier refactor moved it into Core.
public enum DarwinSystemInfo {
    /// Returns the `hw.model` sysctl string, or "unknown" if the sysctl call
    /// fails for any reason (e.g. running somewhere that doesn't have it).
    public static func fetchMacModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    /// True when this process is running on genuinely Intel hardware, which
    /// WhatCable can't read cables on: Intel's Titan Ridge / JHL9580
    /// controllers don't publish the IOKit port-controller data.
    ///
    /// The tempting test is `#if arch(x86_64)`, but that describes the binary
    /// SLICE, not the Mac. Rosetta translates x86_64 -> arm64, so our Intel
    /// slice runs quite happily on Apple Silicon (a Terminal opened with "Open
    /// using Rosetta" is enough to trigger it), where everything actually
    /// works. A slice check alone therefore false-positives on Apple Silicon.
    ///
    /// Two sysctls settle it:
    ///   1. `sysctl.proc_translated` == 1 means we're running under Rosetta.
    ///      Rosetta only exists on Apple Silicon, so the hardware is not Intel.
    ///   2. `hw.optional.arm64` == 1 means Apple Silicon.
    ///
    /// Measured on macOS 26 (M5), the translated case reports proc_translated=1
    /// AND hw.optional.arm64=1, so rule 2 would be enough on its own today.
    /// Rule 1 stays because that's an implementation detail of how much of the
    /// arm64 world Rosetta chooses to expose, not a documented guarantee, and
    /// it's one cheap sysctl to not depend on it.
    ///
    /// On a real Intel Mac neither sysctl exists (`.absent`), which is what we
    /// key "this is Intel" off. An *unexpectedly failed* read is deliberately
    /// NOT treated as Intel: see `isIntelHardware(procTranslated:arm64Optional:)`.
    public static func isIntelHardware() -> Bool {
        isIntelHardware(
            procTranslated: sysctlFlag("sysctl.proc_translated"),
            arm64Optional: sysctlFlag("hw.optional.arm64")
        )
    }

    /// The outcome of one sysctl read. `.absent` (the key doesn't exist) and
    /// `.failed` (it exists but the read went wrong) mean very different things
    /// here, so they mustn't collapse into a single `nil`.
    enum SysctlRead: Equatable {
        case value(Int32)
        /// ENOENT: no such sysctl. On Intel, that's the normal answer for both
        /// of the keys below, and it's the signal we rely on.
        case absent
        /// The read failed for some other reason (permissions, unexpected size).
        /// We know nothing, so we must not guess.
        case failed
    }

    /// The decision, split out from the sysctl reads so the whole truth table
    /// can be tested on any Mac. Testing it through the live reads would only
    /// ever exercise the Apple Silicon row, which is the one row that must
    /// return false, so a broken-shut check would pass such a test.
    ///
    /// Note which way this fails. Only a positive `.absent` says Intel; an
    /// unexpected `.failed` returns false (= supported, stay quiet). Telling
    /// someone with a working Mac that their hardware is unsupported is a much
    /// worse failure than saying nothing on an Intel Mac we couldn't identify.
    static func isIntelHardware(procTranslated: SysctlRead, arm64Optional: SysctlRead) -> Bool {
        // Under Rosetta, so Apple Silicon: Rosetta doesn't exist on Intel.
        if procTranslated == .value(1) { return false }

        switch arm64Optional {
        case .value(1): return false  // Apple Silicon
        case .value: return true      // present but not 1: not an arm64 Mac
        case .absent: return true     // no such sysctl: a real Intel Mac
        case .failed: return false    // no idea, so don't claim anything
        }
    }

    /// Reads an integer sysctl. Distinguishes "no such key" (`.absent`, normal
    /// and expected on Intel) from any other failure (`.failed`), because the
    /// caller treats those as opposite answers.
    static func sysctlFlag(_ name: String) -> SysctlRead {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return errno == ENOENT ? .absent : .failed
        }
        // A short read would leave `value` partly uninitialised; treat any
        // unexpected width as unknown rather than trusting the bytes.
        guard size == MemoryLayout<Int32>.size else { return .failed }
        return .value(value)
    }
}

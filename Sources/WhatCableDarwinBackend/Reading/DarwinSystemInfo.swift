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
}

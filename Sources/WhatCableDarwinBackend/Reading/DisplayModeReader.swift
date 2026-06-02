import CoreGraphics
import Foundation
import WhatCableCore

/// Reads the live display mode for each attached display from CoreGraphics and
/// matches it to its DisplayPort node by EDID identity, so the display
/// diagnostic can report the true on-screen resolution (issue #249) and confirm
/// a display is at full quality even when it reaches its top mode via
/// compression (issue #246).
///
/// CoreGraphics is the right source here: it exposes the current mode through a
/// public, stable API and gives the live refresh directly, where the IOKit
/// framebuffer nodes carry no port join key and no readable mode handle on
/// Apple Silicon. See `planning/display-current-mode-coregraphics.md`.
///
/// The only platform-specific step is reading from CoreGraphics. The match
/// logic is a pure function (`match(ports:displays:)`) so it can be unit-tested
/// without hardware.
public enum DisplayModeReader {

    /// One online display as CoreGraphics sees it: its identity (for matching to
    /// a DisplayPort node) and its live mode.
    public struct ResolvedDisplay: Equatable {
        /// `CGDisplayVendorNumber`: the packed 16-bit EDID manufacturer id
        /// (same encoding as the EDID's 3-letter PNP code), or nil if absent.
        public let vendorNumber: UInt32?
        /// `CGDisplayModelNumber`: equals the EDID product id on real hardware.
        public let modelNumber: UInt32?
        /// `CGDisplaySerialNumber`: often 0 on Apple Silicon, so used only as a
        /// tiebreaker, never as a primary match key.
        public let serialNumber: UInt32?
        public let mode: DisplayCurrentMode

        public init(vendorNumber: UInt32?, modelNumber: UInt32?, serialNumber: UInt32?, mode: DisplayCurrentMode) {
            self.vendorNumber = vendorNumber
            self.modelNumber = modelNumber
            self.serialNumber = serialNumber
            self.mode = mode
        }
    }

    /// Public entry point: enrich each DisplayPort node with its live mode where
    /// an unambiguous match exists. Reads CoreGraphics, then defers to the pure
    /// matcher. Returns the ports unchanged on any read failure.
    public static func enrich(_ ports: [IOPortTransportStateDisplayPort]) -> [IOPortTransportStateDisplayPort] {
        let displays = readOnlineDisplays()
        guard !displays.isEmpty else { return ports }
        return match(ports: ports, displays: displays)
    }

    /// Pure match: attach a `currentMode` to a node only when **exactly one**
    /// online display matches its EDID identity. Fail-closed by design, an
    /// ambiguous or missing match leaves `currentMode` nil so the diagnostic
    /// falls back to its existing verdict and never cross-wires a mode onto the
    /// wrong port.
    ///
    /// Match key: product id (`CGDisplayModelNumber` == EDID product id) plus
    /// vendor (`CGDisplayVendorNumber` decoded to the same 3-letter PNP code the
    /// EDID carries). Serial breaks a tie between two otherwise-identical
    /// displays. A node with no usable identity, or that matches zero or
    /// several displays, is returned untouched.
    public static func match(
        ports: [IOPortTransportStateDisplayPort],
        displays: [ResolvedDisplay]
    ) -> [IOPortTransportStateDisplayPort] {
        ports.map { port in
            guard port.currentMode == nil, let monitor = port.monitor else { return port }

            let candidates = displays.filter { display in
                identityMatches(monitor: monitor, display: display)
            }

            // Exactly one candidate: attach. Otherwise fail closed.
            guard candidates.count == 1 else {
                guard candidates.count > 1, let monitorSerial = monitor.serialNumber else { return port }
                // Tiebreak two identical displays by serial, if the node has one.
                let bySerial = candidates.filter { $0.serialNumber == UInt32(truncatingIfNeeded: monitorSerial) }
                guard bySerial.count == 1 else { return port }
                return attach(bySerial[0].mode, to: port)
            }
            return attach(candidates[0].mode, to: port)
        }
    }

    /// True when a CoreGraphics display is the same physical panel as a
    /// DisplayPort node's EDID identity. Requires a positive product-id match
    /// and, when both sides report a vendor, a vendor match too.
    static func identityMatches(monitor: MonitorInfo, display: ResolvedDisplay) -> Bool {
        guard let productId = monitor.productId,
              let modelNumber = display.modelNumber,
              Int(modelNumber) == productId else { return false }

        // Vendor confirmation when both sides carry it. EDID stores the
        // manufacturer as a 3-letter PNP code; CoreGraphics returns the same
        // value packed as a number, so decode CG's number and compare strings.
        // Fail closed: if both sides report a vendor but CG's number won't
        // decode (junk), don't fall back to a product-id-only match.
        if let name = monitor.manufacturerName, let vendorNumber = display.vendorNumber {
            guard let decoded = pnpCode(fromPackedVendor: vendorNumber) else { return false }
            return decoded == name
        }
        // One side lacks a vendor: product id alone is the match.
        return true
    }

    /// Attach a live mode to a node, but only when the refresh is usable.
    /// CoreGraphics has returned 0 Hz for some modes; with no trustworthy
    /// refresh there is no current-mode data to carry, so leave the node as-is.
    private static func attach(_ mode: DisplayCurrentMode, to port: IOPortTransportStateDisplayPort) -> IOPortTransportStateDisplayPort {
        guard mode.refreshHz > 0 else { return port }
        return port.with(currentMode: mode)
    }

    /// Decode `CGDisplayVendorNumber` (a packed EDID manufacturer id) into its
    /// 3-letter PNP code, e.g. 0x1C54 -> "GBT". Each letter is 5 bits, A=1, in
    /// the low 15 bits of the 16-bit value. Returns nil if any field is out of
    /// the A-Z range, so a junk vendor number never produces a false match.
    static func pnpCode(fromPackedVendor packed: UInt32) -> String? {
        let value = UInt16(truncatingIfNeeded: packed)
        let letters = [
            (value >> 10) & 0x1F,
            (value >> 5) & 0x1F,
            value & 0x1F,
        ]
        var out = ""
        for code in letters {
            guard (1...26).contains(code) else { return nil }
            out.append(Character(UnicodeScalar(UInt8(code) + 0x40))) // 1 -> 'A'
        }
        return out
    }

    /// Read every online display from CoreGraphics. The one platform-specific
    /// step; everything downstream is pure.
    private static func readOnlineDisplays() -> [ResolvedDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.compactMap { id -> ResolvedDisplay? in
            guard let cgMode = CGDisplayCopyDisplayMode(id) else { return nil }
            // Physical pixels, NOT points: a Retina 5K display is 5120 x 2880
            // here but only 2560 x 1440 via the point-based getters. Using the
            // point variants would re-create issue #249 under a new code path.
            let mode = DisplayCurrentMode(
                width: cgMode.pixelWidth,
                height: cgMode.pixelHeight,
                refreshHz: cgMode.refreshRate
            )
            return ResolvedDisplay(
                vendorNumber: CGDisplayVendorNumber(id),
                modelNumber: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id),
                mode: mode
            )
        }
    }
}

extension IOPortTransportStateDisplayPort {
    /// Copy this node with a `currentMode` attached. Kept local to the backend
    /// because only the CoreGraphics matcher sets it.
    fileprivate func with(currentMode: DisplayCurrentMode) -> IOPortTransportStateDisplayPort {
        IOPortTransportStateDisplayPort(
            link: link, monitor: monitor, dfpType: dfpType,
            branchDeviceId: branchDeviceId, branchDeviceOUI: branchDeviceOUI,
            sinkCount: sinkCount, role: role, roleDescription: roleDescription,
            driverStatus: driverStatus, driverStatusDescription: driverStatusDescription,
            transportType: transportType, transportTypeDescription: transportTypeDescription,
            transportDescription: transportDescription,
            authorizationRequired: authorizationRequired, authorizationStatus: authorizationStatus,
            authorizationStatusDescription: authorizationStatusDescription,
            authenticationRequired: authenticationRequired, authenticationStatus: authenticationStatus,
            authenticationStatusDescription: authenticationStatusDescription,
            hashStatus: hashStatus, hashStatusDescription: hashStatusDescription,
            trmTransportSupervised: trmTransportSupervised,
            parentPortType: parentPortType, parentPortTypeDescription: parentPortTypeDescription,
            parentPortNumber: parentPortNumber, parentPortBuiltIn: parentPortBuiltIn,
            parentBuiltInPortType: parentBuiltInPortType,
            parentBuiltInPortTypeDescription: parentBuiltInPortTypeDescription,
            parentBuiltInPortNumber: parentBuiltInPortNumber,
            edidChanged: edidChanged, nominalSignalingFrequenciesHz: nominalSignalingFrequenciesHz,
            index: index, currentMode: currentMode
        )
    }
}

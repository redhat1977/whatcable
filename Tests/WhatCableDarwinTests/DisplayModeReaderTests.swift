import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

/// Tests the pure match logic of `DisplayModeReader`. The CoreGraphics read
/// itself needs hardware, but the matching, identity reconciliation, and
/// fail-closed rules are all unit-testable with injected data.
struct DisplayModeReaderTests {

    private func dpNode(productId: Int?, vendor: String?, serial: Int? = nil) -> IOPortTransportStateDisplayPort {
        IOPortTransportStateDisplayPort(
            link: DisplayPortLink(active: true, laneCount: 4, maxLaneCount: 4, linkRate: 4, tunneled: false, hpdState: 1),
            monitor: MonitorInfo(
                manufacturerName: vendor, productName: nil, productId: productId,
                serialNumber: serial, yearOfManufacture: nil, edid: nil
            )
        )
    }

    private func resolved(vendor: UInt32?, model: UInt32?, serial: UInt32? = nil, w: Int = 3840, h: Int = 2160, hz: Double = 240) -> DisplayModeReader.ResolvedDisplay {
        DisplayModeReader.ResolvedDisplay(
            vendorNumber: vendor, modelNumber: model, serialNumber: serial,
            mode: DisplayCurrentMode(width: w, height: h, refreshHz: hz)
        )
    }

    @Test("Packed EDID vendor 0x1C54 decodes to GBT (Gigabyte)")
    func pnpDecode() {
        #expect(DisplayModeReader.pnpCode(fromPackedVendor: 0x1C54) == "GBT")
        // Apple is 0x0610 -> "APP".
        #expect(DisplayModeReader.pnpCode(fromPackedVendor: 0x0610) == "APP")
        // Junk (a field out of A-Z range) returns nil, never a false letter.
        #expect(DisplayModeReader.pnpCode(fromPackedVendor: 0xFFFF) == nil)
    }

    @Test("A clean single match attaches the live mode")
    func cleanMatch() {
        let ports = [dpNode(productId: 12821, vendor: "GBT")]
        let displays = [resolved(vendor: 0x1C54, model: 12821)]
        let out = DisplayModeReader.match(ports: ports, displays: displays)
        #expect(out[0].currentMode == DisplayCurrentMode(width: 3840, height: 2160, refreshHz: 240))
    }

    @Test("Wrong product id does not match, leaves currentMode nil")
    func noMatchOnProductId() {
        let ports = [dpNode(productId: 12821, vendor: "GBT")]
        let displays = [resolved(vendor: 0x1C54, model: 9999)]
        let out = DisplayModeReader.match(ports: ports, displays: displays)
        #expect(out[0].currentMode == nil)
    }

    @Test("Two identical displays with no serial are ambiguous: no attach (fail closed)")
    func ambiguousNoAttach() {
        let ports = [dpNode(productId: 12821, vendor: "GBT")]
        let displays = [resolved(vendor: 0x1C54, model: 12821), resolved(vendor: 0x1C54, model: 12821)]
        let out = DisplayModeReader.match(ports: ports, displays: displays)
        #expect(out[0].currentMode == nil)
    }

    @Test("Two identical displays disambiguate by serial when the node has one")
    func ambiguousSerialTiebreak() {
        let ports = [dpNode(productId: 12821, vendor: "GBT", serial: 42)]
        let displays = [
            resolved(vendor: 0x1C54, model: 12821, serial: 7, hz: 60),
            resolved(vendor: 0x1C54, model: 12821, serial: 42, hz: 240),
        ]
        let out = DisplayModeReader.match(ports: ports, displays: displays)
        #expect(out[0].currentMode?.refreshHz == 240)
    }

    @Test("A 0 Hz live mode is not trustworthy: no attach")
    func zeroRefreshNoAttach() {
        let ports = [dpNode(productId: 12821, vendor: "GBT")]
        let displays = [resolved(vendor: 0x1C54, model: 12821, hz: 0)]
        let out = DisplayModeReader.match(ports: ports, displays: displays)
        #expect(out[0].currentMode == nil)
    }

    @Test("A mismatched vendor with the same product id does not match")
    func vendorMustAgree() {
        let ports = [dpNode(productId: 12821, vendor: "GBT")]
        let displays = [resolved(vendor: 0x0610, model: 12821)] // APP, not GBT
        let out = DisplayModeReader.match(ports: ports, displays: displays)
        #expect(out[0].currentMode == nil)
    }

    @Test("Both sides carry a vendor but CG's number is junk: fail closed, no attach")
    func undecodableVendorFailsClosed() {
        // Product id agrees, but 0xFFFF doesn't decode to a PNP code. With both
        // sides claiming a vendor, an undecodable one must not fall back to a
        // product-id-only match.
        let ports = [dpNode(productId: 12821, vendor: "GBT")]
        let displays = [resolved(vendor: 0xFFFF, model: 12821)]
        let out = DisplayModeReader.match(ports: ports, displays: displays)
        #expect(out[0].currentMode == nil)
    }

    @Test("Product id alone matches when one side lacks a vendor")
    func vendorAbsentFallsBackToProductId() {
        let ports = [dpNode(productId: 12821, vendor: nil)]
        let displays = [resolved(vendor: 0x1C54, model: 12821)]
        let out = DisplayModeReader.match(ports: ports, displays: displays)
        #expect(out[0].currentMode?.width == 3840)
    }
}

import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

@Suite("Registry parsing")
struct RegistryParsingTests {
    @Test("AppleHPMInterfaceWatcher scans M4 Mini front port class")
    func appleHPMInterfaceWatcherScansM4MiniFrontPortClass() {
        #expect(AppleHPMInterfaceWatcher.candidateClasses.contains("IOPort"))
    }

    @Test("AppleHPMInterfaceWatcher extracts busIndex across controller name shapes")
    func appleHPMInterfaceWatcherExtractsBusIndexAcrossControllerNameShapes() {
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "hpm4@3") == 4)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "atc1") == 1)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "usb-drd2@2280000") == 2)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "hpm@3") == nil)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromRegistryName: "AppleT6000USBXHCI") == nil)
    }

    @Test("AppleHPMInterfaceWatcher extracts location fallback as hex")
    func appleHPMInterfaceWatcherExtractsLocationFallbackAsHex() {
        #expect(AppleHPMInterfaceWatcher.busIndex(fromLocation: "1") == 1)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromLocation: "0A") == 10)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromLocation: "") == nil)
        #expect(AppleHPMInterfaceWatcher.busIndex(fromLocation: "Port-USB-C") == nil)
    }

    @Test("USBWatcher parses usbIOPort string and Data")
    func usbWatcherParsesUsbIOPortStringAndData() {
        let path = "AppleARMIO/Port-USB-C@1"
        #expect(USBWatcher.usbIOPortPath(from: path) == path)

        let data = Data("AppleARMIO/Port-USB-C@2\u{0}".utf8)
        #expect(USBWatcher.usbIOPortPath(from: data) == "AppleARMIO/Port-USB-C@2")
    }

    @Test("USBWatcher extracts port name and bus index")
    func usbWatcherExtractsPortNameAndBusIndex() {
        #expect(
            USBWatcher.portName(fromUSBIOPortPath: "AppleARMIO/Port-USB-C@1") ==
            "Port-USB-C@1"
        )
        #expect(USBWatcher.portName(fromUSBIOPortPath: "AppleARMIO/AppleUSBHostPort@1") == nil)
        #expect(USBWatcher.busIndex(fromLocationID: 0x0300_0000) == 3)
    }

    @Test("Front-port gate: only native + not-tunnelled + no-port-name qualifies (issue #348)")
    func behindInternalHubStructuralGate() {
        // The one true case: a device that reached a native controller, is not
        // tunnelled, and matched no Port-USB-C@N node. This is a desktop
        // front-panel device.
        #expect(
            USBWatcher.classifyBehindInternalHub(
                reachedNativeController: true, tunnelled: false, portName: nil
            ) == true
        )

        // Back-port device: has a UsbIOPort ancestor, so portName is set.
        #expect(
            USBWatcher.classifyBehindInternalHub(
                reachedNativeController: true, tunnelled: false, portName: "Port-USB-C@2"
            ) == false
        )

        // Thunderbolt-tunnelled device: reached AppleUSBXHCITR, never a native
        // controller. Both the tunnelled flag and the missing native controller
        // independently disqualify it, so the two device sets can't overlap.
        #expect(
            USBWatcher.classifyBehindInternalHub(
                reachedNativeController: false, tunnelled: true, portName: nil
            ) == false
        )
        // Defensive: even if a future walk somehow set both, tunnelled wins.
        #expect(
            USBWatcher.classifyBehindInternalHub(
                reachedNativeController: true, tunnelled: true, portName: nil
            ) == false
        )

        // Walk never reached any controller (e.g. the 20-hop bound was hit):
        // fail safe, do not classify as front-port.
        #expect(
            USBWatcher.classifyBehindInternalHub(
                reachedNativeController: false, tunnelled: false, portName: nil
            ) == false
        )
    }

    @Test("PowerSourceWatcher handles built-in parent fields and priority fallback")
    func powerSourceWatcherHandlesBuiltInParentFieldsAndPriorityFallback() {
        let builtIn: [String: Any] = [
            "ParentBuiltInPortType": NSNumber(value: 0x11),
            "ParentBuiltInPortNumber": NSNumber(value: 2),
            "ParentPortType": NSNumber(value: 2),
            "ParentPortNumber": NSNumber(value: 1)
        ]
        let builtInParent = PowerSourceWatcher.parentPortIdentity(read: { builtIn[$0] })
        #expect(builtInParent.type == 0x11)
        #expect(builtInParent.number == 2)

        let priority: [String: Any] = [
            "ParentPortType": NSNumber(value: 0x11),
            "Priority": NSNumber(value: 0x0201)
        ]
        let priorityParent = PowerSourceWatcher.parentPortIdentity(read: { priority[$0] })
        #expect(priorityParent.type == 0x11)
        #expect(priorityParent.number == 1)
    }

    @Test("USBPDSOP watcher handles MagSafe CC and SOP1 metadata")
    func usbPDSOPWatcherHandlesMagSafeCCAndSOP1Metadata() {
        let dict: [String: Any] = [
            "TransportTypeDescription": "CC",
            "ParentBuiltInPortType": NSNumber(value: 0x11),
            "ParentBuiltInPortNumber": NSNumber(value: 1),
            "Metadata": [
                "Vendor ID (SOP1)": NSNumber(value: 0x05AC),
                "Product ID (SOP1)": NSNumber(value: 0x1234),
                "bcdDevice": NSNumber(value: 0x0100)
            ]
        ]
        let metadata = USBPDSOPWatcher.metadataDictionary(read: { dict[$0] })
        let parent = USBPDSOPWatcher.parentPortIdentity(read: { dict[$0] })

        #expect(USBPDSOPWatcher.endpoint(read: { dict[$0] }) == .sopPrime)
        #expect(parent.type == 0x11)
        #expect(parent.number == 1)
        #expect(USBPDSOPWatcher.vendorID(read: { dict[$0] }, metadata: metadata) == 0x05AC)
        #expect(USBPDSOPWatcher.productID(read: { dict[$0] }, metadata: metadata) == 0x1234)
        #expect(USBPDSOPWatcher.bcdDevice(from: metadata) == 0x0100)
    }

    @Test("USBPDSOPWatcher handles built-in parent fields and priority fallback")
    func usbPDSOPWatcherHandlesBuiltInParentFieldsAndPriorityFallback() {
        // When both key variants are present with different values, the
        // BuiltIn variant must win so PD identity and power data resolve to
        // the same portKey (matches PowerSourceWatcher's order).
        let builtIn: [String: Any] = [
            "ParentBuiltInPortType": NSNumber(value: 0x11),
            "ParentBuiltInPortNumber": NSNumber(value: 2),
            "ParentPortType": NSNumber(value: 2),
            "ParentPortNumber": NSNumber(value: 1)
        ]
        let builtInParent = USBPDSOPWatcher.parentPortIdentity(read: { builtIn[$0] })
        #expect(builtInParent.type == 0x11)
        #expect(builtInParent.number == 2)

        let priority: [String: Any] = [
            "ParentPortType": NSNumber(value: 0x11),
            "Priority": NSNumber(value: 0x0201)
        ]
        let priorityParent = USBPDSOPWatcher.parentPortIdentity(read: { priority[$0] })
        #expect(priorityParent.type == 0x11)
        #expect(priorityParent.number == 1)
    }

    // MARK: - HPMPortUUIDMap.from(ports:) (DAR-29)

    /// `from(ports:)` must build the same UUID -> portKey map that `current()`
    /// builds from IOKit, just from already-captured ports instead of a second
    /// IOKit sweep. The test covers the normal case (UUID present) and confirms
    /// the normalisation (dashes stripped, lowercase) used to match SMC DxUI.
    @Test("HPMPortUUIDMap.from(ports:) builds map from captured port UUIDs")
    func hpmPortUUIDMapFromPorts() {
        // Two ports with distinct UUIDs (the M3+ dashed form the watcher reads).
        let uuid1 = "7C30AF2D-D913-3441-0CD9-000000000001"
        let uuid2 = "6230AF2D-D913-3441-0CD9-000000000002"

        let port1 = AppleHPMInterface(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleHPMInterfaceType10",
            portDescription: "Port-USB-C@1", portTypeDescription: "USB-C",
            portNumber: 1, connectionActive: false,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO"],
            transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            hpmControllerUUID: uuid1,
            rawProperties: ["PortType": "2"]
        )
        let port2 = AppleHPMInterface(
            id: 2, serviceName: "Port-MagSafe 3@1", className: "AppleHPMInterfaceType11",
            portDescription: "Port-MagSafe 3@1", portTypeDescription: "MagSafe 3",
            portNumber: 1, connectionActive: true,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: [], transportsActive: ["CC"], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            hpmControllerUUID: uuid2,
            rawProperties: [:]
        )

        let map = HPMPortUUIDMap.from(ports: [port1, port2])

        // UUIDs are normalised (dashes stripped, lowercase) as keys.
        let normalised1 = HPMPortUUIDMap.normalise(uuid1)
        let normalised2 = HPMPortUUIDMap.normalise(uuid2)
        #expect(map[normalised1] == "2/1",  "USB-C@1 must map to portKey 2/1")
        #expect(map[normalised2] == "17/1", "MagSafe@1 must map to portKey 17/1")
        #expect(map.count == 2)
    }

    /// Ports with no UUID (M1/M2 fallback or defensive nil) are skipped.
    /// The map must be empty rather than guessing positional mappings.
    @Test("HPMPortUUIDMap.from(ports:) is empty when no UUIDs present")
    func hpmPortUUIDMapFromPortsEmptyWithoutUUIDs() {
        let port = AppleHPMInterface(
            id: 1, serviceName: "Port-USB-C@1", className: "AppleTCControllerType10",
            portDescription: "Port-USB-C@1", portTypeDescription: "USB-C",
            portNumber: 1, connectionActive: false,
            activeCable: nil, opticalCable: nil, usbActive: nil,
            superSpeedActive: nil, usbModeType: nil, usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3"],
            transportsActive: [], transportsProvisioned: [],
            plugOrientation: nil, plugEventCount: nil, connectionCount: nil,
            overcurrentCount: nil, pinConfiguration: [:], powerCurrentLimits: [],
            firmwareVersion: nil, bootFlagsHex: nil,
            hpmControllerUUID: nil,    // M1/M2: no UUID
            rawProperties: ["PortType": "2"]
        )

        let map = HPMPortUUIDMap.from(ports: [port])
        #expect(map.isEmpty, "No positional guessing: empty map when UUIDs absent")
    }
}

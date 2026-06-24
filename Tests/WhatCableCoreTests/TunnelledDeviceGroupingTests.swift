import Testing
@testable import WhatCableCore

/// Tests the decision in `TunnelledDeviceGrouping`: collect Thunderbolt-tunnelled
/// USB devices, and nest them under a port only when exactly one Thunderbolt
/// device is connected (issue #274). The IOKit detection of the tunnel flag is
/// not unit-testable (no registry in tests); these cover the pure grouping.
struct TunnelledDeviceGroupingTests {
    // MARK: Fixtures

    private func device(
        id: UInt64,
        name: String,
        tunnelled: Bool,
        behindInternalHub: Bool = false,
        deviceClass: UInt8? = nil
    ) -> USBDevice {
        USBDevice(
            id: id,
            locationID: UInt32(truncatingIfNeeded: id),
            vendorID: 0x05AC,
            productID: 0x1234,
            vendorName: "Apple",
            productName: name,
            serialNumber: nil,
            usbVersion: nil,
            speedRaw: 2,
            busPowerMA: nil,
            currentMA: nil,
            isThunderboltTunnelled: tunnelled,
            isBehindInternalHub: behindInternalHub,
            deviceClass: deviceClass,
            rawProperties: [:]
        )
    }

    private func port(socketID: String) -> AppleHPMInterface {
        AppleHPMInterface(
            id: UInt64(socketID) ?? 1,
            serviceName: "Port-USB-C@\(socketID)",
            className: "AppleHPMInterfaceType10",
            portDescription: nil,
            portTypeDescription: "USB-C",
            portNumber: Int(socketID) ?? 1,
            connectionActive: true,
            activeCable: nil,
            opticalCable: nil,
            usbActive: nil,
            superSpeedActive: nil,
            usbModeType: nil,
            usbConnectString: nil,
            transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
            transportsActive: ["CC", "CIO"],
            transportsProvisioned: [],
            plugOrientation: nil,
            plugEventCount: nil,
            connectionCount: nil,
            overcurrentCount: nil,
            pinConfiguration: [:],
            powerCurrentLimits: [],
            firmwareVersion: nil,
            bootFlagsHex: nil,
            rawProperties: [:]
        )
    }

    private func hostSwitch(id: Int64, socketID: String) -> IOThunderboltSwitch {
        let lane = IOThunderboltPort(
            portNumber: 1,
            socketID: socketID,
            adapterType: .lane,
            currentSpeed: .usb4Tb4,
            currentWidth: LinkWidth(rawValue: 0x2),
            targetWidth: nil,
            rawTargetSpeed: nil,
            linkBandwidthRaw: nil
        )
        return IOThunderboltSwitch(
            id: id,
            className: "IOThunderboltSwitchType7",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Mac",
            routerID: 0,
            depth: 0,
            routeString: 0,
            upstreamPortNumber: 7,
            maxPortNumber: 8,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [lane],
            parentSwitchUID: nil
        )
    }

    /// A downstream device switch (the dock/display) hanging off a host root.
    private func deviceSwitch(id: Int64, parent: Int64) -> IOThunderboltSwitch {
        IOThunderboltSwitch(
            id: id,
            className: "IOThunderboltSwitchType3",
            vendorID: 1452,
            vendorName: "Apple Inc.",
            modelName: "Studio Display",
            routerID: 0,
            depth: 1,
            routeString: 1,
            upstreamPortNumber: 1,
            maxPortNumber: 13,
            supportedSpeed: SupportedSpeedMask(rawValue: 0xE),
            ports: [],
            parentSwitchUID: parent
        )
    }

    // MARK: Tests

    @Test("No tunnelled devices yields an empty result")
    func noTunnelled() {
        let result = TunnelledDeviceGrouping.group(
            devices: [device(id: 1, name: "Mouse", tunnelled: false)],
            ports: [port(socketID: "1")],
            thunderboltSwitches: []
        )
        #expect(result.devices.isEmpty)
        #expect(result.hostPortServiceName == nil)
    }

    @Test("Only tunnelled devices are returned; native ones are excluded")
    func filtersToTunnelled() {
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "Native Mouse", tunnelled: false),
                device(id: 2, name: "TB Keyboard", tunnelled: true)
            ],
            ports: [port(socketID: "2")],
            thunderboltSwitches: []
        )
        #expect(result.devices.map(\.productName) == ["TB Keyboard"])
    }

    @Test("Internal USB hubs (class 0x09) are filtered out; real devices kept")
    func filtersHubs() {
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "USB2 Hub", tunnelled: true, deviceClass: 0x09),
                device(id: 2, name: "USB3 Gen2 Hub", tunnelled: true, deviceClass: 0x09),
                device(id: 3, name: "Studio Display", tunnelled: true, deviceClass: 0xEF),
                device(id: 4, name: "Magic Keyboard", tunnelled: true, deviceClass: 0x00)
            ],
            ports: [port(socketID: "2")],
            thunderboltSwitches: []
        )
        #expect(result.devices.map(\.productName) == ["Studio Display", "Magic Keyboard"])
    }

    @Test("One connected Thunderbolt device nests tunnelled devices under that port")
    func singleDeviceNests() {
        let host = hostSwitch(id: 100, socketID: "2")
        let display = deviceSwitch(id: 200, parent: 100)
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "Mouse", tunnelled: true),
                device(id: 2, name: "Keyboard", tunnelled: true)
            ],
            ports: [port(socketID: "1"), port(socketID: "2")],
            thunderboltSwitches: [host, display]
        )
        #expect(result.devices.count == 2)
        #expect(result.hostPortServiceName == "Port-USB-C@2")
    }

    @Test("Two connected Thunderbolt devices fall back to a flat list (no host port)")
    func twoDevicesFlat() {
        let host1 = hostSwitch(id: 100, socketID: "1")
        let dev1 = deviceSwitch(id: 200, parent: 100)
        let host2 = hostSwitch(id: 101, socketID: "2")
        let dev2 = deviceSwitch(id: 201, parent: 101)
        let result = TunnelledDeviceGrouping.group(
            devices: [device(id: 1, name: "Mouse", tunnelled: true)],
            ports: [port(socketID: "1"), port(socketID: "2")],
            thunderboltSwitches: [host1, dev1, host2, dev2]
        )
        #expect(result.devices.count == 1)
        #expect(result.hostPortServiceName == nil)
    }

    @Test("Tunnelled devices but no connected Thunderbolt device falls back to flat")
    func noTBDeviceFlat() {
        let host = hostSwitch(id: 100, socketID: "2")   // host root, nothing downstream
        let result = TunnelledDeviceGrouping.group(
            devices: [device(id: 1, name: "Mouse", tunnelled: true)],
            ports: [port(socketID: "2")],
            thunderboltSwitches: [host]
        )
        #expect(result.devices.count == 1)
        #expect(result.hostPortServiceName == nil)
    }

    // MARK: Internal-hub / front-port (issue #348)

    @Test("Internal-hub devices appear in internalHubDevices, separate from tunnelled")
    func internalHubFlat() {
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "Front USB drive", tunnelled: false, behindInternalHub: true),
                device(id: 2, name: "Native mouse", tunnelled: false)
            ],
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(result.devices.isEmpty)
        #expect(result.hostPortServiceName == nil)
        #expect(result.internalHubDevices.map(\.productName) == ["Front USB drive"])
    }

    @Test("Internal-hub devices are gated off on a laptop (desktop-only policy)")
    func internalHubGatedOffOnLaptop() {
        let devices = [
            device(id: 1, name: "Front USB drive", tunnelled: false, behindInternalHub: true),
            device(id: 2, name: "TB mouse", tunnelled: true)
        ]
        // isDesktopMac defaults to false: the structural flag is set but the
        // front-port set is empty. The tunnelled set is unaffected by the gate.
        let laptop = TunnelledDeviceGrouping.group(
            devices: devices,
            ports: [port(socketID: "1")],
            thunderboltSwitches: []
        )
        #expect(laptop.internalHubDevices.isEmpty)
        #expect(laptop.devices.map(\.productName) == ["TB mouse"])

        // Same input on a desktop surfaces the front-port device.
        let desktop = TunnelledDeviceGrouping.group(
            devices: devices,
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(desktop.internalHubDevices.map(\.productName) == ["Front USB drive"])
    }

    @Test("The internal hub itself (deviceClass 0x09) is filtered out")
    func internalHubFiltersHubs() {
        // The internal hub also satisfies the behind-internal-hub gate (it
        // reaches a native controller with no UsbIOPort ancestor), so the
        // fixtures carry behindInternalHub: true. That makes the deviceClass
        // 0x09 check the load-bearing filter here, not the flag.
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "USB2 Hub", tunnelled: false, behindInternalHub: true, deviceClass: 0x09),
                device(id: 2, name: "USB3 Gen2 Hub", tunnelled: false, behindInternalHub: true, deviceClass: 0x09),
                device(id: 3, name: "Front drive", tunnelled: false, behindInternalHub: true)
            ],
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(result.internalHubDevices.map(\.productName) == ["Front drive"])
    }

    @Test("Hubs behind the internal hub are also filtered out of the front list")
    func internalHubFiltersChildHubs() {
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "Daisy-chained hub", tunnelled: false, behindInternalHub: true, deviceClass: 0x09),
                device(id: 2, name: "Front drive", tunnelled: false, behindInternalHub: true)
            ],
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(result.internalHubDevices.map(\.productName) == ["Front drive"])
    }

    @Test("Tunnelled-and-nested coexists with a front-port section")
    func tunnelledNestedPlusInternalHub() {
        let host = hostSwitch(id: 100, socketID: "2")
        let display = deviceSwitch(id: 200, parent: 100)
        let result = TunnelledDeviceGrouping.group(
            devices: [
                device(id: 1, name: "TB mouse", tunnelled: true),
                device(id: 2, name: "Front drive", tunnelled: false, behindInternalHub: true)
            ],
            ports: [port(socketID: "1"), port(socketID: "2")],
            thunderboltSwitches: [host, display],
            isDesktopMac: true
        )
        #expect(result.devices.map(\.productName) == ["TB mouse"])
        #expect(result.hostPortServiceName == "Port-USB-C@2")
        #expect(result.internalHubDevices.map(\.productName) == ["Front drive"])
    }

    @Test("A device flagged both tunnelled and internal-hub goes only to the tunnelled set")
    func bothFlagsTunnelledWins() {
        let result = TunnelledDeviceGrouping.group(
            devices: [device(id: 1, name: "Odd device", tunnelled: true, behindInternalHub: true)],
            ports: [port(socketID: "1")],
            thunderboltSwitches: [],
            isDesktopMac: true
        )
        #expect(result.devices.map(\.productName) == ["Odd device"])
        #expect(result.internalHubDevices.isEmpty)
    }
}

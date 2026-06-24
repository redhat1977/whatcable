import Foundation

/// Decides how to present USB devices that match no physical USB-C port and
/// would otherwise be silently dropped. Two cases:
///
/// 1. Devices reached over a Thunderbolt tunnel (issue #274), behind a TB dock
///    or display. The helper nests them under the host port when exactly one
///    Thunderbolt device is connected, else renders flat.
/// 2. Devices behind an internal Apple USB hub (issue #348), the front USB-C
///    and USB-A ports on Mac mini / Studio / Pro. These never nest under a
///    port: front ports have no port-controller silicon to attribute to.
///
/// Safety rule for the TB-tunnelled nesting: only attribute to a port when
/// **exactly one** Thunderbolt device is connected. With one connection there
/// is no ambiguity about what the tunnelled devices are behind, so the
/// attribution is certain without the per-port tunnel join (the
/// `apciec`/`acio` correlation that is not yet confirmed on multi-port
/// hardware). With two or more Thunderbolt devices the helper returns no
/// host port and the caller renders a flat "Other USB devices" section
/// instead of guessing.
///
/// Pure logic, no IOKit. Shared by the menu bar app, the CLI text output, and
/// the JSON output so all three group identically.
public enum TunnelledDeviceGrouping {
    public struct Result: Equatable {
        /// The Thunderbolt-tunnelled devices, in input order. Empty when there
        /// are none, in which case the caller shows no extra section.
        public let devices: [USBDevice]
        /// The `serviceName` of the one connected Thunderbolt port these devices
        /// nest under (e.g. "Port-USB-C@2"), or `nil` to render them flat. Only
        /// set when exactly one Thunderbolt device is connected.
        public let hostPortServiceName: String?
        /// Devices on a desktop Mac's plain-USB front ports (issue #348).
        /// Always rendered flat: front ports have no port-controller silicon so
        /// there is nothing to attribute them to. This is the single place the
        /// desktop-only policy is applied: it is empty unless `group` was called
        /// with `isDesktopMac: true`, so every consumer of this array is
        /// laptop-safe without its own check. Also empty when there is no
        /// front-port activity.
        public let internalHubDevices: [USBDevice]

        public init(
            devices: [USBDevice],
            hostPortServiceName: String?,
            internalHubDevices: [USBDevice] = []
        ) {
            self.devices = devices
            self.hostPortServiceName = hostPortServiceName
            self.internalHubDevices = internalHubDevices
        }
    }

    /// USB Hub device class (`bDeviceClass`). The internal hubs inside a
    /// Thunderbolt dock or display, and the Apple-VID front-panel hubs on
    /// desktop Macs, are plumbing rather than devices the user plugged in,
    /// so both kinds are filtered out. Spec-mandated, so this is robust (no
    /// name matching). The dock/display's own functions (e.g. a display's
    /// camera/audio) are left in: they are real USB devices.
    private static let usbHubClass: UInt8 = 0x09

    /// - Parameter isDesktopMac: gates the `internalHubDevices` result. The
    ///   front-panel hub ports only exist on Mac mini / Studio / Pro, so on a
    ///   laptop the internal-hub set is forced empty here regardless of the
    ///   per-device structural flag. Defaults to `false` (fail closed): a caller
    ///   that does not opt in gets no front-port devices, never a laptop false
    ///   positive. The `isBehindInternalHub` flag itself stays pure structural
    ///   truth; this is the one place the desktop product policy is applied.
    public static func group(
        devices: [USBDevice],
        ports: [AppleHPMInterface],
        thunderboltSwitches: [IOThunderboltSwitch],
        isDesktopMac: Bool = false
    ) -> Result {
        let tunnelled = devices.filter {
            $0.isThunderboltTunnelled && $0.deviceClass != usbHubClass
        }
        // Front-port / internal-hub devices: those the parent walk flagged as
        // behind the Mac's internal hub, minus the hub itself (class 0x09).
        // Desktop-only: empty on laptops (see isDesktopMac). The tunnelled
        // exclusion is defensive; isBehindInternalHub already implies !tunnelled.
        let internalHub = isDesktopMac
            ? devices.filter {
                $0.isBehindInternalHub
                    && !$0.isThunderboltTunnelled
                    && $0.deviceClass != usbHubClass
            }
            : []

        guard !tunnelled.isEmpty else {
            return Result(
                devices: [],
                hostPortServiceName: nil,
                internalHubDevices: internalHub
            )
        }

        // Ports that currently have a Thunderbolt device downstream (a dock or
        // display). A single dock fanning out to two displays is still one
        // connection (one port), so this counts physical Thunderbolt links.
        let portsWithDevice = ports.filter { port in
            guard let socketID = ThunderboltTopology.socketID(for: port),
                  let root = ThunderboltTopology.hostRoot(forSocketID: socketID, in: thunderboltSwitches)
            else { return false }
            return !ThunderboltTopology.tree(from: root, in: thunderboltSwitches).isEmpty
        }

        let hostPortServiceName = portsWithDevice.count == 1
            ? portsWithDevice.first?.serviceName
            : nil
        return Result(
            devices: tunnelled,
            hostPortServiceName: hostPortServiceName,
            internalHubDevices: internalHub
        )
    }
}

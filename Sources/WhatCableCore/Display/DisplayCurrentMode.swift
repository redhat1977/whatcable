import Foundation

/// The live display mode that macOS is actually driving right now: the real
/// on-screen resolution and refresh rate, read from CoreGraphics by the Darwin
/// backend and attached to the matching DisplayPort node.
///
/// Why this exists, in plain terms: a monitor's EDID (the spec sheet it sends
/// down the cable) can fail to describe its own best mode. Apple 5K/6K displays
/// declare their native mode in a part of the EDID our parser doesn't read, so
/// from EDID alone WhatCable sees a 4K-or-smaller mode and mislabels them
/// (issue #249). And when a display reaches its top mode via compression (DSC),
/// the link rate alone can't confirm it's at full quality (issue #246).
/// macOS already knows the true mode, so we read it straight from CoreGraphics.
///
/// `width` / `height` are **physical pixels** (a Retina 5K display is 5120 x
/// 2880 here, not its 2560-point logical size). Pure value type, no platform
/// imports, so it compiles on every target; the Windows backend leaves it nil.
public struct DisplayCurrentMode: Codable, Sendable, Equatable, Hashable {
    /// Active horizontal pixels of the current mode (physical, not points).
    public let width: Int
    /// Active vertical pixels of the current mode (physical, not points).
    public let height: Int
    /// Live refresh rate in Hz. Only trustworthy when > 0; CoreGraphics has
    /// historically returned 0 for some modes, which the backend treats as
    /// "no usable current mode" and declines to attach.
    public let refreshHz: Double

    public init(width: Int, height: Int, refreshHz: Double) {
        self.width = width
        self.height = height
        self.refreshHz = refreshHz
    }

    /// Active-pixel throughput (pixels per second): width x height x refresh.
    /// Deliberately excludes blanking so it compares like-for-like against the
    /// monitor's preferred resolution x max refresh, never against the EDID
    /// pixel clock (which includes blanking and would skew the comparison).
    public var pixelThroughput: Double {
        Double(width) * Double(height) * refreshHz
    }

    /// "5120 x 2880 @ 240Hz", for the Pro screen and JSON.
    public var label: String {
        "\(width) x \(height) @ \(Int(refreshHz.rounded()))Hz"
    }
}

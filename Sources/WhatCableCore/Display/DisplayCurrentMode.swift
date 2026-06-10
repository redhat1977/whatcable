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
/// 2880 here, not its 2560-point logical size). Pure value type with no platform
/// imports; the Darwin backend populates it from CoreGraphics, and it is left
/// nil in tests and whenever there's no live mode to read.
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

    /// Compact label for the desktop widget, e.g. "5K 60Hz", "4K 120Hz",
    /// "1440p 144Hz". Falls back to raw "WIDTHxHEIGHT NHz" for resolutions we
    /// don't have a friendly name for, so it never shows nothing. Common Mac
    /// and external-monitor modes are named; the rest read as raw pixels.
    public var shortLabel: String {
        let hz = Int(refreshHz.rounded())
        let res: String
        switch (width, height) {
        case (7680, 4320): res = "8K"
        case (6016, 3384), (6144, 3456): res = "6K"
        case (5120, 2880): res = "5K"
        case (3840, 2160), (4096, 2160): res = "4K"
        case (5120, 1440): res = "DUW 1440p"  // 49" super-ultrawide
        case (3840, 1600), (3440, 1440): res = "UW 1440p"  // ultrawide
        case (2560, 1440): res = "1440p"
        case (2560, 1600): res = "1600p"
        case (2560, 1080): res = "UW 1080p"  // 34" ultrawide
        case (1920, 1200): res = "1200p"
        case (1920, 1080): res = "1080p"
        default: res = "\(width)x\(height)"
        }
        return "\(res) \(hz)Hz"
    }
}

import Foundation
import Testing
@testable import WhatCableCore
@testable import WhatCableDarwinBackend

// MARK: - Corpus sweep tests for HPM, PD identity, and liquid-detection watchers (DAR-77)
//
// Each suite replays the real IOKit property data captured in the customer-probe
// corpus (research/customer-probes/) through the parse-logic extracted from the
// corresponding watcher's `makeIdentity` / `makeUpdate` path. The IOKit I/O is
// replaced by a simple `read: (String) -> Any?` closure backed by a parsed dict,
// which is exactly the seam the `parseIdentity` / `parseUpdate` static functions
// expose. No IOKit framework calls happen at test time.
//
// Data sources:
//   01_walk_pd_tree.json  - git-tracked; present for all committed corpus folders.
//                           Contains SOP/SOP'/SOP'' PD identity blocks.
//   17_deep_property_dump.json - on-disk only (not committed; re-fetch from KV
//                           on a fresh clone). Contains HPM interface and LDCM
//                           blocks. Tests skip folders where this file is absent
//                           so a fresh clone always passes trivially.

// MARK: - Shared helpers

private let probeRoot: URL = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhatCableDarwinTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("research/customer-probes")
}()

private func allProbeFolders() -> [String] {
    (try? FileManager.default
        .contentsOfDirectory(atPath: probeRoot.path)
        .filter { entry in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(
                atPath: probeRoot.appendingPathComponent(entry).path,
                isDirectory: &isDir
            )
            return isDir.boolValue
        }
        .sorted()
    ) ?? []
}

// MARK: - Probe-17 parser
//
// Parses `17_deep_property_dump.json` into a list of named blocks.
// Each block carries its outer class name (from `--- ClassName[N] ---`),
// its inner class name (from `=== ClassName ===`), and a `read` closure
// backed by the properties parsed out of the block body.

private struct Probe17Block {
    /// The outer header class, e.g. "AppleHPMInterfaceType10"
    let outerClass: String
    /// The inner === class, e.g. "AppleHPMInterfaceType18" (may differ from outer on A-series)
    let innerClass: String
    /// Block body text (the raw lines between this header and the next)
    let body: String
    /// Property-read closure backed by parsed key-value pairs.
    /// Supports: String (quoted), Bool (true/false), Int (N (0xHEX)), [String], nested blocks.
    let read: (String) -> Any?
}

// Parse N (0xHEX) style integers
private func parseIntLine(_ text: String) -> NSNumber? {
    let t = text.trimmingCharacters(in: .whitespaces)
    // "N (0xHEX)" or "N"
    let digits = t.prefix { $0.isNumber }
    if !digits.isEmpty, let n = Int(digits) { return NSNumber(value: n) }
    return nil
}

// Parse a quoted string like: "value"
private func parseQuotedString(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard t.hasPrefix("\""), let endQ = t.dropFirst().firstIndex(of: "\"") else { return nil }
    return String(t.dropFirst()[..<endQ])
}

// Parse a transport/string array: lines of `    [N] "value"` until "]"
private func parseStringArray(in blockLines: [Substring], startingAt lineIdx: Int) -> [String] {
    var result: [String] = []
    var i = lineIdx + 1
    while i < blockLines.count {
        let line = blockLines[i]
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "]" { break }
        // Match `[N] "value"`
        if let q1 = t.firstIndex(of: "\""),
           let q2 = t.lastIndex(of: "\""), q1 != q2 {
            result.append(String(t[t.index(after: q1)..<q2]))
        }
        i += 1
    }
    return result
}

// Parse a Metadata block `{ ... }` into a [String: Any] dict.
// Handles: quoted strings, N (0xHEX) integers, bool.
// Handles the VDOs array inside metadata.
private func parseMetadata(in blockLines: [Substring], startingAt lineIdx: Int) -> [String: Any] {
    var dict: [String: Any] = [:]
    var i = lineIdx + 1
    var depth = 0
    while i < blockLines.count {
        let line = blockLines[i]
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "{" { depth += 1; i += 1; continue }
        if t == "}" { if depth == 0 { break } else { depth -= 1 } }

        // VDOs array
        if t.hasPrefix("VDOs =") || t.hasPrefix("VDOs:") {
            // Collect `[N] <data 4 bytes: HH HH HH HH>` lines
            var vdos: [Data] = []
            i += 1
            while i < blockLines.count {
                let vl = blockLines[i].trimmingCharacters(in: .whitespaces)
                if vl == "]" { break }
                // Match: [N] <data 4 bytes: HH HH HH HH>
                if let r = try? NSRegularExpression(pattern: #"\[(\d+)\] <data 4 bytes: ([0-9a-fA-F ]+)>"#),
                   let m = r.firstMatch(in: vl, range: NSRange(vl.startIndex..., in: vl)),
                   m.numberOfRanges > 2,
                   let byteRange = Range(m.range(at: 2), in: vl) {
                    let parts = String(vl[byteRange]).split(separator: " ").compactMap { UInt8($0, radix: 16) }
                    if parts.count == 4 { vdos.append(Data(parts)) }
                }
                i += 1
            }
            dict["VDOs"] = vdos as [Any]
            i += 1
            continue
        }

        // KEY = VALUE or KEY: VALUE
        if let sepRange = t.range(of: " = ") ?? t.range(of: ": ") {
            let key = String(t[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let val = String(t[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if val == "true" { dict[key] = NSNumber(value: true) }
            else if val == "false" { dict[key] = NSNumber(value: false) }
            else if let s = parseQuotedString(val) { dict[key] = s }
            else if let n = parseIntLine(val) { dict[key] = n }
        }
        i += 1
    }
    return dict
}

/// Parse a single probe-17 block body into a read closure.
private func makeReadClosure(from body: String) -> (String) -> Any? {
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    var dict: [String: Any] = [:]

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let t = line.trimmingCharacters(in: .whitespaces)
        // Skip empty and comment-like lines
        if t.isEmpty || t.hasPrefix("===") || t.hasPrefix("---") { i += 1; continue }

        // KEY: [ or KEY = [ -> string array
        if let sepRange = (t.range(of: ": [") ?? t.range(of: " = [")) {
            let key = String(t[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let arr = parseStringArray(in: lines, startingAt: i)
            dict[key] = arr as [Any]
            i += 1
            continue
        }
        // Metadata = { or Metadata: {
        if t.hasPrefix("Metadata =") || t.hasPrefix("Metadata:") {
            let meta = parseMetadata(in: lines, startingAt: i)
            dict["Metadata"] = meta as Any
            i += 1
            continue
        }
        // KEY: VALUE or KEY = VALUE
        if let sepRange = t.range(of: ": ") ?? t.range(of: " = ") {
            let key = String(t[..<sepRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let val = String(t[sepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if val == "true" { dict[key] = NSNumber(value: true) }
            else if val == "false" { dict[key] = NSNumber(value: false) }
            else if let s = parseQuotedString(val) { dict[key] = s }
            else if let n = parseIntLine(val) { dict[key] = n }
        }
        i += 1
    }

    return { dict[$0] }
}

/// Split the probe-17 output text into named top-level blocks.
/// Handles both `--- ClassName[N] ---` (top-level) and nested `=== ClassName ===` sub-blocks.
/// Only top-level blocks are returned here; the nested `===` blocks are included in the body text
/// of the enclosing top-level block.
private func parseProbe17Blocks(text: String, outerClassPrefix: String) -> [Probe17Block] {
    // Split on outer block headers  `--- ClassName[N] ---`
    let pattern = #"--- (\w+)\[(\d+)\] ---"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))

    var results: [Probe17Block] = []
    for (idx, m) in matches.enumerated() {
        guard let classRange = Range(m.range(at: 1), in: text) else { continue }
        let outerClass = String(text[classRange])
        guard outerClass.hasPrefix(outerClassPrefix) else { continue }

        guard let blockStart = Range(m.range, in: text).map({ $0.upperBound }) else { continue }
        let blockEnd: String.Index
        if idx + 1 < matches.count, let nextRange = Range(matches[idx + 1].range, in: text) {
            blockEnd = nextRange.lowerBound
        } else {
            blockEnd = text.endIndex
        }
        let body = String(text[blockStart..<blockEnd])

        // Extract the inner === class name
        var innerClass = outerClass
        if let innerRe = try? NSRegularExpression(pattern: #"=== (\w+) ==="#),
           let im = innerRe.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let ir = Range(im.range(at: 1), in: body) {
            innerClass = String(body[ir])
        }

        let readClosure = makeReadClosure(from: body)
        results.append(Probe17Block(
            outerClass: outerClass,
            innerClass: innerClass,
            body: body,
            read: readClosure
        ))
    }
    return results
}

/// Load probe-17 blocks for the named outer class prefix from a probe folder.
/// Returns empty when the probe file is missing (fresh clone).
private func loadProbe17Blocks(probe: String, outerClassPrefix: String) -> [Probe17Block] {
    let url = probeRoot
        .appendingPathComponent(probe)
        .appendingPathComponent("17_deep_property_dump.json")
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = root["output"] as? String
    else { return [] }
    return parseProbe17Blocks(text: text, outerClassPrefix: outerClassPrefix)
}

// MARK: - Probe-17 LDCM sub-block parser
//
// The AppleHPMLDCMType2 service is exposed in probe 17 as nested `=== AppleHPMLDCMType2 ===`
// sub-blocks inside the top-level HPM interface block. Extract them independently of the
// HPM interface parse so we can test LiquidDetectionWatcher.parseUpdate against the same data.

private struct LDCMBlock {
    let portIndex: Int
    let portType: String
    let body: String
    let read: (String) -> Any?
}

private func loadLDCMBlocks(probe: String) -> [LDCMBlock] {
    let url = probeRoot
        .appendingPathComponent(probe)
        .appendingPathComponent("17_deep_property_dump.json")
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = root["output"] as? String
    else { return [] }

    // Find all `=== AppleHPMLDCMType2 ===` occurrences and extract their body
    var results: [LDCMBlock] = []
    var searchStart = text.startIndex
    while let blockStart = text.range(of: "=== AppleHPMLDCMType2 ===", range: searchStart..<text.endIndex) {
        // Body runs until the next `===` or `---` block header or end of text
        let bodyStart = blockStart.upperBound
        var bodyEnd = text.endIndex
        // Look for the next `===` or `---` block header after the body starts
        if let next = text.range(of: "\n===", range: bodyStart..<text.endIndex) {
            bodyEnd = next.lowerBound
        } else if let next2 = text.range(of: "\n---", range: bodyStart..<text.endIndex) {
            bodyEnd = next2.lowerBound
        }
        let body = String(text[bodyStart..<bodyEnd])
        let readFn = makeReadClosure(from: body)

        // Extract portIndex and portType from body
        let portIndex: Int
        if let n = readFn("ParentBuiltInPortNumber") as? NSNumber {
            portIndex = n.intValue
        } else if let n = readFn("ParentPortNumber") as? NSNumber {
            portIndex = n.intValue
        } else {
            portIndex = 0
        }
        let portType = readFn("ParentPortTypeDescription") as? String ?? "USB-C"

        results.append(LDCMBlock(portIndex: portIndex, portType: portType, body: body, read: readFn))
        searchStart = bodyEnd < text.endIndex ? text.index(after: bodyEnd) : text.endIndex
    }
    return results
}

// MARK: - Probe-01 PD identity parser
//
// Mirrors the approach in CableTrustProbeSweepTests: split on `=== ` headers,
// keep only CCUSBPDSOP* blocks, parse properties into a dict, build a read closure.

private struct SOPBlock {
    let className: String      // e.g. "IOPortTransportComponentCCUSBPDSOP"
    let portNumber: Int        // from Description = "Port-USB-C@N/..."
    let read: (String) -> Any? // backed by parsed properties + Metadata
    /// Count of VDO entries inside the Metadata VDOs array
    let vdoCount: Int
}

private func loadSOPBlocks(probe: String) -> [SOPBlock] {
    let url = probeRoot
        .appendingPathComponent(probe)
        .appendingPathComponent("01_walk_pd_tree.json")
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = root["output"] as? String
    else { return [] }

    let blocks = text.components(separatedBy: "=== ").dropFirst()
    var results: [SOPBlock] = []

    for block in blocks {
        guard block.contains("CCUSBPDSOP") else { continue }

        // Extract the class name from the first line (ends with "[N] ===")
        // e.g. "IOPortTransportComponentCCUSBPDSOP[0] ===" -> "IOPortTransportComponentCCUSBPDSOP"
        let firstLine = String(block.prefix(while: { $0 != "\n" }))
        let withoutIndex = firstLine.replacingOccurrences(
            of: #"\[\d+\].*$"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        let rawClass = withoutIndex
        guard rawClass.hasPrefix("IOPortTransportComponentCCUSBPDSOP") else { continue }

        // Port number from Description = "Port-USB-C@N/CC/..."
        var portNumber = 0
        if let re = try? NSRegularExpression(pattern: #"Description = "Port-USB-C@(\d+)/CC"#),
           let m = re.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
           let r = Range(m.range(at: 1), in: block),
           let n = Int(block[r]) {
            portNumber = n
        }

        // Build dict from Properties block
        var dict: [String: Any] = [:]
        // Top-level key-value lines (4-space indent)
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        var vdoCount = 0

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            // Metadata block: parse into a nested dict
            if t.hasPrefix("Metadata =") || t.hasPrefix("Metadata:") {
                let bodyLines = Array(lines[(i+1)...])
                var metaDict: [String: Any] = [:]
                var j = 0
                var vdos: [Data] = []
                var inVDOs = false
                while j < bodyLines.count {
                    let ml = bodyLines[j].trimmingCharacters(in: .whitespaces)
                    if ml == "}" { break }
                    if ml.hasPrefix("VDOs") { inVDOs = true; j += 1; continue }
                    if inVDOs {
                        if ml == "]" { inVDOs = false; j += 1; continue }
                        // [N] <data 4 bytes: HH HH HH HH>
                        if let re = try? NSRegularExpression(pattern: #"<data 4 bytes: ([0-9a-fA-F ]+)>"#),
                           let m = re.firstMatch(in: ml, range: NSRange(ml.startIndex..., in: ml)),
                           let r = Range(m.range(at: 1), in: ml) {
                            let parts = String(ml[r]).split(separator: " ").compactMap { UInt8($0, radix: 16) }
                            if parts.count == 4 { vdos.append(Data(parts)) }
                        }
                        j += 1; continue
                    }
                    // KEY = VALUE
                    if let sep = ml.range(of: " = ") {
                        let key = String(ml[..<sep.lowerBound])
                        let val = String(ml[sep.upperBound...])
                        if val == "true" { metaDict[key] = NSNumber(value: true) }
                        else if val == "false" { metaDict[key] = NSNumber(value: false) }
                        else if let s = parseQuotedString(val) { metaDict[key] = s }
                        else if let n = parseIntLine(val) { metaDict[key] = n }
                    }
                    j += 1
                }
                if !vdos.isEmpty { metaDict["VDOs"] = vdos as [Any] }
                vdoCount = vdos.count
                dict["Metadata"] = metaDict as Any
                i += 1
                continue
            }

            // Top-level KEY = VALUE (4-space indent)
            if line.hasPrefix("    "), let sep = t.range(of: " = ") {
                let key = String(t[..<sep.lowerBound])
                let val = String(t[sep.upperBound...])
                if val == "true" { dict[key] = NSNumber(value: true) }
                else if val == "false" { dict[key] = NSNumber(value: false) }
                else if let s = parseQuotedString(val) { dict[key] = s }
                else if let n = parseIntLine(val) { dict[key] = n }
            }
            i += 1
        }

        let readFn: (String) -> Any? = { dict[$0] }
        results.append(SOPBlock(className: rawClass, portNumber: portNumber, read: readFn, vdoCount: vdoCount))
    }
    return results
}

// MARK: - HPM Interface sweep

@Suite("Watcher corpus sweep (DAR-77) - HPM Interface")
struct HPMInterfaceProbeSweepTests {

    @Test("Every AppleHPMInterface block in probe-17 yields a model with correct fields")
    func everyHPMBlockYieldsModel() throws {
        let probes = allProbeFolders()

        var foldersScanned = 0
        var blocksTotal = 0
        var modelsProduced = 0
        var failures: [String] = []

        for probe in probes {
            let blocks = loadProbe17Blocks(probe: probe, outerClassPrefix: "AppleHPMInterfaceType")
            if blocks.isEmpty { continue }
            foldersScanned += 1

            for (blockIdx, block) in blocks.enumerated() {
                blocksTotal += 1
                let read = block.read
                let innerClass = block.innerClass

                // serviceName comes from `Description:`
                let serviceName = (read("Description") as? String) ?? ""
                let portType = (read("PortTypeDescription") as? String) ?? ""

                // AppleHPMInterface.from requires a real port (PortTypeDescription = USB-C or MagSafe,
                // serviceName starting with Port-). Skip blocks that don't represent a real port
                // (e.g. child sub-entries exposed under the same outer class header).
                guard (portType == "USB-C" || portType.hasPrefix("MagSafe"))
                        && serviceName.hasPrefix("Port-")
                else { continue }

                let model = AppleHPMInterface.from(
                    entryID: UInt64(blockIdx + 1),
                    serviceName: serviceName,
                    className: innerClass,
                    read: read
                )

                guard let model else {
                    failures.append("\(probe)[\(blockIdx)]: nil from factory (serviceName=\(serviceName), class=\(innerClass))")
                    continue
                }
                modelsProduced += 1

                // portTypeDescription must round-trip
                #expect(
                    model.portTypeDescription == portType,
                    "\(probe)[\(blockIdx)]: portTypeDescription mismatch: got \(model.portTypeDescription ?? "nil"), expected \(portType)"
                )

                // portNumber must be present and positive for real physical ports
                if let pn = model.portNumber {
                    #expect(pn >= 1, "\(probe)[\(blockIdx)]: portNumber \(pn) < 1")
                }

                // transportsSupported must be non-empty for USB-C ports
                if portType == "USB-C" {
                    #expect(
                        !model.transportsSupported.isEmpty,
                        "\(probe)[\(blockIdx)]: USB-C port has empty transportsSupported"
                    )
                }

                // serviceName must round-trip
                #expect(
                    model.serviceName == serviceName,
                    "\(probe)[\(blockIdx)]: serviceName mismatch"
                )
            }
        }

        for f in failures {
            Issue.record("Factory returned nil: \(f)")
        }

        // Guard: the corpus is non-trivial. When probe-17 files are absent
        // (fresh clone), foldersScanned == 0 and we skip silently. When files
        // are present, require a meaningful yield.
        if foldersScanned > 0 {
            // Each folder contributes roughly 2-4 HPM blocks; 100 models from
            // 50+ folders is a reasonable floor. Calibrated against the 460-block
            // corpus total with ~80-85% being real physical ports.
            #expect(
                modelsProduced >= 100,
                "HPM sweep: only \(modelsProduced) models from \(blocksTotal) blocks across \(foldersScanned) folders; expected at least 100"
            )
        }
    }
}

// MARK: - PD identity (SOP / SOP' / SOP'') sweep

@Suite("Watcher corpus sweep (DAR-77) - PD SOP identity")
struct PDSOPIdentitySweepTests {

    @Test("Every SOP/SOP' block in probe-01 yields an identity with correct endpoint and VDO bytes")
    func everySOPBlockYieldsIdentity() throws {
        let probes = allProbeFolders()

        var blocksTotal = 0
        var modelsProduced = 0
        var endpointMismatch = 0

        for probe in probes {
            let blocks = loadSOPBlocks(probe: probe)

            for (idx, block) in blocks.enumerated() {
                blocksTotal += 1

                // Derive the expected endpoint from the class name
                let expectedEndpoint: USBPDSOP.Endpoint
                switch block.className {
                case "IOPortTransportComponentCCUSBPDSOP":    expectedEndpoint = .sop
                case "IOPortTransportComponentCCUSBPDSOPp":   expectedEndpoint = .sopPrime
                case "IOPortTransportComponentCCUSBPDSOPpp":  expectedEndpoint = .sopDoublePrime
                default:                                       expectedEndpoint = .unknown
                }

                let identity = USBPDSOPWatcher.parseIdentity(
                    entryID: UInt64(idx + 1),
                    read: block.read,
                    className: block.className,
                    hpmControllerUUID: nil
                )

                guard let identity else {
                    // parseIdentity does not return nil for valid inputs; it always
                    // produces a USBPDSOP regardless of whether metadata is populated.
                    Issue.record("\(probe)[\(idx)]: parseIdentity returned nil for class \(block.className)")
                    continue
                }
                modelsProduced += 1

                // Endpoint must match the IOKit class name
                if identity.endpoint != expectedEndpoint {
                    endpointMismatch += 1
                    Issue.record("\(probe)[\(idx)]: endpoint \(identity.endpoint) != expected \(expectedEndpoint)")
                }
                #expect(
                    identity.endpoint == expectedEndpoint,
                    "\(probe)[\(idx)]: endpoint mismatch"
                )

                // parentPortNumber must match the port number extracted from Description
                #expect(
                    identity.parentPortNumber == block.portNumber,
                    "\(probe)[\(idx)]: parentPortNumber \(identity.parentPortNumber) != \(block.portNumber)"
                )

                // VDO count must match the parsed VDO count
                #expect(
                    identity.vdos.count == block.vdoCount,
                    "\(probe)[\(idx)]: vdo count \(identity.vdos.count) != parsed \(block.vdoCount)"
                )

                // VDO bytes must reassemble to the same UInt32 values CableTrustProbeSweepTests computes.
                // Little-endian: bytes [b0, b1, b2, b3] -> b3<<24 | b2<<16 | b1<<8 | b0
                let metadata = USBPDSOPWatcher.metadataDictionary(read: block.read)
                let rawVDOs = (metadata["VDOs"] as? [Any]) ?? []
                for (vdoIdx, raw) in rawVDOs.enumerated() {
                    guard let d = raw as? Data, d.count == 4 else { continue }
                    let expected = UInt32(d[0]) | (UInt32(d[1]) << 8) | (UInt32(d[2]) << 16) | (UInt32(d[3]) << 24)
                    #expect(
                        identity.vdos[vdoIdx] == expected,
                        "\(probe)[\(idx)] VDO[\(vdoIdx)]: \(identity.vdos[vdoIdx]) != \(expected)"
                    )
                }
            }
        }

        // Guard: all probe-01 files are git-tracked, so the corpus always has blocks.
        // Calibrated against 298 SOP + 184 SOP' = 482 total blocks across 248 folders.
        #expect(
            blocksTotal >= 100,
            "PD sweep: only \(blocksTotal) blocks found; expected at least 100 (are the probe files present?)"
        )
        #expect(
            modelsProduced >= blocksTotal - 5,
            "PD sweep: only \(modelsProduced)/\(blocksTotal) identities produced; unexpected nil returns"
        )
        #expect(endpointMismatch == 0, "PD sweep: \(endpointMismatch) endpoint mismatches")
    }

    @Test("SOP endpoint classification matches IOKit class name across full corpus")
    func sopEndpointClassificationIsCorrect() throws {
        // Targeted check: verify the three class-to-endpoint mappings independently.
        let probes = allProbeFolders()
        var sopCount = 0
        var sopPrimeCount = 0
        var sopDPrimeCount = 0

        for probe in probes {
            for block in loadSOPBlocks(probe: probe) {
                let identity = USBPDSOPWatcher.parseIdentity(
                    entryID: 1,
                    read: block.read,
                    className: block.className,
                    hpmControllerUUID: nil
                )
                guard let identity else { continue }

                switch block.className {
                case "IOPortTransportComponentCCUSBPDSOP":
                    sopCount += 1
                    #expect(identity.endpoint == .sop, "\(probe): SOP class must map to .sop endpoint")
                case "IOPortTransportComponentCCUSBPDSOPp":
                    sopPrimeCount += 1
                    #expect(identity.endpoint == .sopPrime, "\(probe): SOPp class must map to .sopPrime endpoint")
                case "IOPortTransportComponentCCUSBPDSOPpp":
                    sopDPrimeCount += 1
                    #expect(identity.endpoint == .sopDoublePrime, "\(probe): SOPpp class must map to .sopDoublePrime endpoint")
                default:
                    break
                }
            }
        }

        // Every folder has at least one SOP block (gate for connected accessories);
        // SOPp only appears when a cable e-marker is present.
        #expect(sopCount >= 100, "Expected at least 100 SOP blocks; found \(sopCount)")
    }
}

// MARK: - VDM identity (Pro watcher) sweep

@Suite("Watcher corpus sweep (DAR-77) - VDM identity")
struct VDMIdentitySweepTests {

    @Test("VDMIdentityWatcher.parseUpdate produces matching identity from probe-01 SOP blocks")
    func vdmUpdateMatchesSOP() throws {
        let probes = allProbeFolders()
        var blocksTotal = 0
        var updatesProduced = 0

        for probe in probes {
            for (idx, block) in loadSOPBlocks(probe: probe).enumerated() {
                blocksTotal += 1

                // Map IOKit class name to VDMIdentityWatcher.Endpoint
                let endpoint: VDMIdentityWatcher.Endpoint
                switch block.className {
                case "IOPortTransportComponentCCUSBPDSOP":  endpoint = .sop
                case "IOPortTransportComponentCCUSBPDSOPp": endpoint = .sopPrime
                default: continue  // SOPpp is not watched by VDMIdentityWatcher; skip
                }

                let update = VDMIdentityWatcher.parseUpdate(
                    read: block.read,
                    className: block.className,
                    endpoint: endpoint,
                    portIndex: block.portNumber,
                    portType: "USB-C"
                )

                guard let update else {
                    // parseUpdate always returns an update (never nil for valid inputs)
                    Issue.record("\(probe)[\(idx)]: VDMIdentityWatcher.parseUpdate returned nil")
                    continue
                }
                updatesProduced += 1

                // portIndex must match the port number parsed from Description
                #expect(
                    update.portIndex == block.portNumber,
                    "\(probe)[\(idx)]: portIndex \(update.portIndex) != \(block.portNumber)"
                )

                // endpoint must round-trip
                #expect(
                    update.endpoint == endpoint,
                    "\(probe)[\(idx)]: endpoint mismatch"
                )

                // VDO count must match
                let metadata = USBPDSOPWatcher.metadataDictionary(read: block.read)
                let rawVDOs = (metadata["VDOs"] as? [Any]) ?? []
                #expect(
                    update.identity.vdos.count == rawVDOs.count,
                    "\(probe)[\(idx)]: vdo count \(update.identity.vdos.count) != \(rawVDOs.count)"
                )
            }
        }

        // Subtract SOPpp blocks (not swept here) - still expect a large yield
        #expect(
            blocksTotal >= 100,
            "VDM sweep: only \(blocksTotal) SOP/SOPp blocks; expected at least 100"
        )
        #expect(
            updatesProduced >= blocksTotal - 5,
            "VDM sweep: only \(updatesProduced)/\(blocksTotal) updates produced"
        )
    }
}

// MARK: - Liquid detection sweep

@Suite("Watcher corpus sweep (DAR-77) - Liquid detection")
struct LiquidDetectionSweepTests {

    @Test("Every AppleHPMLDCMType2 sub-block in probe-17 yields a LiquidDetectionUpdate with matching fields")
    func everyLDCMBlockYieldsUpdate() throws {
        let probes = allProbeFolders()

        var foldersScanned = 0
        var blocksTotal = 0
        var updatesProduced = 0

        for probe in probes {
            let blocks = loadLDCMBlocks(probe: probe)
            if blocks.isEmpty { continue }
            foldersScanned += 1
            blocksTotal += blocks.count

            for (idx, block) in blocks.enumerated() {
                let update = LiquidDetectionWatcher.parseUpdate(
                    read: block.read,
                    portIndex: block.portIndex,
                    portType: block.portType
                )

                guard let update else {
                    Issue.record("\(probe)[\(idx)]: LiquidDetectionWatcher.parseUpdate returned nil")
                    continue
                }
                updatesProduced += 1

                // portIndex must match
                #expect(
                    update.portIndex == block.portIndex,
                    "\(probe)[\(idx)]: portIndex mismatch: \(update.portIndex) != \(block.portIndex)"
                )

                // liquidDetected must round-trip
                let rawLD = block.read("LiquidDetected")
                let expectedLD = (rawLD as? NSNumber)?.boolValue ?? false
                #expect(
                    update.status.liquidDetected == expectedLD,
                    "\(probe)[\(idx)]: liquidDetected mismatch"
                )

                // state must be non-empty
                #expect(
                    !update.status.state.isEmpty,
                    "\(probe)[\(idx)]: state is empty"
                )

                // stateDescription round-trip when present
                if let sd = block.read("StateDescription") as? String {
                    #expect(
                        update.status.state == sd,
                        "\(probe)[\(idx)]: state \(update.status.state) != StateDescription \(sd)"
                    )
                }

                // measurementStatus must be non-negative
                #expect(
                    update.status.measurementStatus >= 0,
                    "\(probe)[\(idx)]: measurementStatus \(update.status.measurementStatus) < 0"
                )
            }
        }

        if foldersScanned > 0 {
            // Corpus has 252 nested AppleHPMLDCMType2 blocks across 94 folders.
            // Require a meaningful yield when probe-17 files are present.
            #expect(
                blocksTotal >= 50,
                "LDCM sweep: only \(blocksTotal) blocks from \(foldersScanned) folders; expected at least 50"
            )
            #expect(
                updatesProduced == blocksTotal,
                "LDCM sweep: \(updatesProduced)/\(blocksTotal) updates produced; unexpected nil returns"
            )
        }
    }
}

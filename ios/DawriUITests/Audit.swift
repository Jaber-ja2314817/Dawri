import UIKit
import XCTest

/// One audit finding the app accepts on purpose, written beside its reason. It matches an issue
/// by its type and the identifier or label of the element it names, or, for a system view the
/// audit names no element for, by the class its description gives. Never by a whole screen,
/// with one kind of exception: `rows` limits a finding to named review rows, and by itself it
/// matches only there, for a presentation whose every text follows one written rule, such as
/// the Live Activity's capped text size.
struct AuditExclusion {
    let type: XCUIAccessibilityAuditType
    var identifier: String?
    /// Any of these labels.
    var labels: [String]?
    /// Elements whose top edge is above this line, in points from the top of the screen.
    var above: CGFloat?
    /// Text the issue's detailed description holds, such as a system class name.
    var detail: String?
    /// Only on these ScreenTable rows.
    var rows: [String]?
    let reason: String

    func matches(
        _ type: XCUIAccessibilityAuditType, identifier: String, label: String, frame: CGRect, detail issueDetail: String,
        row: String
    ) -> Bool {
        guard self.type == type else { return false }
        if let rows, !rows.contains(row) { return false }
        if let wanted = self.identifier, wanted != identifier { return false }
        if let wanted = labels, !wanted.contains(label) { return false }
        if let above, frame.minY >= above { return false }
        if let detail, !issueDetail.contains(detail) { return false }
        return self.identifier != nil || labels != nil || above != nil || detail != nil || rows != nil
    }
}

/// The five audits the brief names.
let auditTypes: XCUIAccessibilityAuditType = [.dynamicType, .contrast, .hitRegion, .textClipped, .elementDetection]

/// The audits in three calls, so each check sees the screen as it rests. Contrast, element
/// detection and hit regions only read the screen, so they go first, together. Clipped text
/// changes the text size to look for clipping and can leave the layout moved: on chat-summary,
/// run alone on a freshly booted Dawri Build, it left the tree changed and about 130,000 pixels
/// different, while each of the other three left 0. In one call with contrast it let contrast
/// measure Yes and Change under the composer, which is not the screen at rest. Dynamic type
/// steps through every size category, so it goes last.
let auditOrder: [XCUIAccessibilityAuditType] = [
    auditTypes.subtracting([.textClipped, .dynamicType]), .textClipped, .dynamicType,
]

extension XCUIAccessibilityAuditType {
    var name: String {
        switch self {
        case .dynamicType: "dynamicType"
        case .contrast: "contrast"
        case .hitRegion: "hitRegion"
        case .textClipped: "textClipped"
        case .elementDetection: "elementDetection"
        default: "other(\(rawValue))"
        }
    }
}

extension XCUIApplication {
    /// Runs the audit and returns every finding no exclusion covers, one line each, naming the
    /// element, so a failure says where to look. The checks run in `auditOrder`, so the ones that
    /// only read the screen see it as it rests, before the ones that change the text size.
    @MainActor
    func auditFindings(excluding exclusions: [AuditExclusion], row: String) throws -> [String] {
        var findings: [String] = []
        for types in auditOrder {
            try performAccessibilityAudit(for: types) { issue in
                let identifier = issue.element?.identifier ?? ""
                let label = issue.element?.label ?? ""
                let frame = issue.element?.frame ?? .zero
                if exclusions.contains(where: {
                    $0.matches(
                        issue.auditType, identifier: identifier, label: label, frame: frame,
                        detail: issue.detailedDescription, row: row)
                }) {
                    return true
                }
                let element = issue.element.map {
                    "\($0.elementType.rawValue) id='\(identifier)' label='\(label)' frame=\(frame)"
                } ?? "no element: \(issue.detailedDescription)"
                findings.append("\(issue.auditType.name): \(issue.compactDescription) [\(element)]")
                return true
            }
        }
        return findings
    }
}

/// How a screen came to rest before its audit, for the log beside the findings.
struct Settling: CustomStringConvertible {
    let settled: Bool
    let seconds: Double
    let reads: Int
    /// What changed between each pair of reads: `tree` when an element moved or changed text,
    /// and the count of changed pixels.
    let changes: [String]

    var description: String {
        let trail = changes.joined(separator: ", ")
        return settled
            ? String(format: "settled after %.1f s, %d reads [%@]", seconds, reads, trail)
            : String(format: "still moving after %.1f s, %d reads, audited as it was [%@]", seconds, reads, trail)
    }
}

extension XCUIApplication {
    /// Waits until nothing on screen is moving, so the audit measures the screen at rest and not
    /// a frame of a scroll or a fade. A fixed sleep cannot know that, least of all at the start
    /// of a fresh run, when the simulator is busiest and animations run late.
    ///
    /// The screen counts as settled when two reads `interval` apart agree on both:
    /// - every element's frame, label and value in the tree, which covers the chat's last
    ///   element and anything still scrolling or moving in, and
    /// - the pixels below the status bar, which covers an opacity fade or a spring that the
    ///   tree cannot see. A caret's blink changes too few pixels to count.
    ///
    /// It waits `minimum` first, so a state the launch stages on a short timer has started.
    @MainActor
    func waitUntilSettled(minimum: TimeInterval = 2, interval: TimeInterval = 0.6, timeout: TimeInterval = 15)
        -> Settling
    {
        let start = Date()
        Thread.sleep(forTimeInterval: minimum)
        var previous = ScreenRead(of: self)
        var reads = 1
        var changes: [String] = []
        while Date().timeIntervalSince(start) < minimum + timeout {
            Thread.sleep(forTimeInterval: interval)
            let next = ScreenRead(of: self)
            reads += 1
            guard let before = previous, let after = next else {
                changes.append("no read")
                previous = next
                continue
            }
            let change = after.change(from: before)
            changes.append((change.tree ? "tree+" : "") + "\(change.pixels)px")
            if !change.tree && change.pixels <= ScreenRead.pixelAllowance {
                return Settling(
                    settled: true, seconds: Date().timeIntervalSince(start), reads: reads, changes: changes)
            }
            previous = next
        }
        return Settling(settled: false, seconds: Date().timeIntervalSince(start), reads: reads, changes: changes)
    }
}

/// One read of the screen: the element tree's geometry and text, and a point-scale copy of the
/// screenshot's pixels.
private struct ScreenRead {
    let tree: [String]
    let pixels: [UInt8]
    let width: Int
    let height: Int
    /// Rows from the top that hold the status bar, whose clock may tick between reads.
    let statusRows: Int

    /// Pixels, at point scale, allowed to differ between two reads. Measured on Dawri Build: a
    /// blinking caret changed 73, a button's spinning ProgressView 20 to 121 (it never rests,
    /// and it was audited spinning before this wait too), and the keyboard sliding in 113,722.
    /// A bubble fading in or any scroll changes thousands.
    static let pixelAllowance = 150
    /// Per channel, so resampling noise is not change.
    private static let channelTolerance = 12

    @MainActor
    init?(of app: XCUIApplication) {
        guard let snapshot = try? app.snapshot() else { return nil }
        var tree: [String] = []
        Self.flatten(snapshot, into: &tree)
        self.tree = tree

        let image = XCUIScreen.main.screenshot().image
        guard let cg = image.cgImage else { return nil }
        let scale = max(image.scale, 1)
        let width = Int(CGFloat(cg.width) / scale)
        let height = Int(CGFloat(cg.height) / scale)
        self.width = width
        self.height = height
        statusRows = 70
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
    }

    @MainActor
    private static func flatten(_ element: any XCUIElementSnapshot, into tree: inout [String]) {
        let frame = element.frame
        let value = element.value.map { "\($0)" } ?? ""
        tree.append(
            "\(element.elementType.rawValue)|\(element.identifier)|\(element.label)|\(value)|"
                + "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)")
        for child in element.children {
            flatten(child, into: &tree)
        }
    }

    /// Whether the tree differs, and how many pixels below the status bar differ.
    func change(from other: ScreenRead) -> (tree: Bool, pixels: Int) {
        guard width == other.width, height == other.height else { return (true, width * height) }
        // The bitmap holds the image's top row first, so the status bar is the first rows.
        let skip = statusRows * width * 4
        var changed = 0
        pixels.withUnsafeBufferPointer { mine in
            other.pixels.withUnsafeBufferPointer { theirs in
                var index = skip
                while index < mine.count {
                    if abs(Int(mine[index]) - Int(theirs[index])) > Self.channelTolerance
                        || abs(Int(mine[index + 1]) - Int(theirs[index + 1])) > Self.channelTolerance
                        || abs(Int(mine[index + 2]) - Int(theirs[index + 2])) > Self.channelTolerance
                    {
                        changed += 1
                    }
                    index += 4
                }
            }
        }
        return (tree != other.tree, changed)
    }
}

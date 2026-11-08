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
    /// element, so a failure says where to look. Dynamic type runs on its own, last, because it
    /// steps the text size through every category and the other checks must see the screen as
    /// it rests.
    @MainActor
    func auditFindings(excluding exclusions: [AuditExclusion], row: String) throws -> [String] {
        var findings: [String] = []
        for types in [auditTypes.subtracting(.dynamicType), .dynamicType] as [XCUIAccessibilityAuditType] {
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

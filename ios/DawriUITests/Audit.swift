import XCTest

/// One audit finding the app accepts on purpose, written beside its reason. It matches an issue
/// by its type and the identifier or label of the element it names, never by a whole screen.
struct AuditExclusion {
    let type: XCUIAccessibilityAuditType
    var identifier: String?
    /// Any of these labels.
    var labels: [String]?
    /// Elements whose top edge is above this line, in points from the top of the screen.
    var above: CGFloat?
    let reason: String

    func matches(_ type: XCUIAccessibilityAuditType, identifier: String, label: String, frame: CGRect) -> Bool {
        guard self.type == type else { return false }
        if let wanted = self.identifier, wanted != identifier { return false }
        if let wanted = labels, !wanted.contains(label) { return false }
        if let above, frame.minY >= above { return false }
        return self.identifier != nil || labels != nil || above != nil
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
    func auditFindings(excluding exclusions: [AuditExclusion]) throws -> [String] {
        var findings: [String] = []
        for types in [auditTypes.subtracting(.dynamicType), .dynamicType] as [XCUIAccessibilityAuditType] {
            try performAccessibilityAudit(for: types) { issue in
                let identifier = issue.element?.identifier ?? ""
                let label = issue.element?.label ?? ""
                let frame = issue.element?.frame ?? .zero
                if exclusions.contains(where: {
                    $0.matches(issue.auditType, identifier: identifier, label: label, frame: frame)
                }) {
                    return true
                }
                let element = issue.element.map {
                    "\($0.elementType.rawValue) id='\(identifier)' label='\(label)' frame=\(frame)"
                } ?? "no element"
                findings.append("\(issue.auditType.name): \(issue.compactDescription) [\(element)]")
                return true
            }
        }
        return findings
    }
}

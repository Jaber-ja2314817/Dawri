/// The port of frontend/src/lib/stages.ts.
public enum Screen: String, Sendable, Codable, Hashable, CaseIterable {
    case chat
    case emergency
    case refill
    case centre
    case reserved
    case ticket
    case complete
    case home
}

/// The screens a visit may show, canonical one first. This is the whole of the rule that a
/// chat box never appears once chat is over: chat is listed for an open intake and nothing else.
public func screensFor(stage: VisitStage, confirmedByPatient: Bool) -> [Screen] {
    switch stage {
    case .emergency: [.emergency]
    case .refill: [.refill]
    case .completed: [.complete]
    case .reserved: [.reserved]
    case .expired: [.reserved, .centre]
    case .triage, .doctor, .pharmacy: [.ticket]
    case .cancelled: [.home]
    case .intake: confirmedByPatient ? [.centre] : [.chat]
    }
}

/// The redirect rule of frontend/src/components/VisitGate.tsx: the requested screen if the
/// visit lists it, otherwise the canonical one. A nil request is the gate with no screen,
/// which only sends the visit to its canonical screen. This keeps Back from reaching chat
/// after an emergency, and a chat box off a completed visit.
public func gatedScreen(
    stage: VisitStage, confirmedByPatient: Bool, requested: Screen?
) -> Screen {
    let screens = screensFor(stage: stage, confirmedByPatient: confirmedByPatient)
    if let requested, screens.contains(requested) { return requested }
    guard let canonical = screens.first else {
        preconditionFailure("screensFor lists at least one screen for every stage")
    }
    return canonical
}

public func gatedScreen(for visit: Visit, requested: Screen?) -> Screen {
    gatedScreen(
        stage: visit.stage, confirmedByPatient: visit.confirmedByPatient, requested: requested)
}

public enum Lang: String, Sendable, Codable, Hashable, CaseIterable {
    case ar
    case en

    public var dir: Dir { dirOf(self) }
}

/// The layout direction a language reads in. The app maps this to SwiftUI's own value.
public enum Dir: String, Sendable, Hashable {
    case rtl
    case ltr
}

public func dirOf(_ lang: Lang) -> Dir {
    lang == .ar ? .rtl : .ltr
}

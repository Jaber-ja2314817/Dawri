/// Server-sent events, read byte by byte as the HTML standard's "event stream interpretation"
/// says, so nothing depends on how the bytes were split into chunks or how a line reader treats
/// blank lines.
///
/// - Lines end in CRLF, LF or CR. A CRLF split across two chunks is still one line end.
/// - A line starting with `:` is a comment, such as the backend's `: connected` and
///   `: heartbeat`. It gives nothing.
/// - `data` fields gather, joined by LF. A blank line dispatches the event if it had at least one
///   `data` field. Other fields are read and ignored.
/// - What is left unfinished when the stream ends is dropped, never dispatched.
///
/// The app does not trust what an event says: any event only means "read the visit again".
struct EventStreamParser {
    private var line: [UInt8] = []
    private var data: [UInt8] = []
    private var hasData = false
    private var afterCR = false
    private var started = false
    private var bomSeen = 0

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Reads one byte. Returns the event's data when this byte ended one.
    mutating func push(_ byte: UInt8) -> String? {
        if !started {
            // A leading byte order mark is skipped, once.
            if byte == Self.bom[bomSeen] {
                bomSeen += 1
                if bomSeen == Self.bom.count { started = true }
                return nil
            }
            started = true
            if bomSeen > 0 {
                let partial = Self.bom.prefix(bomSeen)
                bomSeen = 0
                for earlier in partial { _ = take(earlier) }
            }
        }
        return take(byte)
    }

    /// Reads a chunk. Returns the data of every event it ended, in order.
    mutating func push(contentsOf bytes: some Sequence<UInt8>) -> [String] {
        var events: [String] = []
        for byte in bytes {
            if let event = push(byte) { events.append(event) }
        }
        return events
    }

    private mutating func take(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0A where afterCR:
            afterCR = false
            return nil
        case 0x0A, 0x0D:
            afterCR = byte == 0x0D
            return endLine()
        default:
            afterCR = false
            line.append(byte)
            return nil
        }
    }

    private mutating func endLine() -> String? {
        defer { line.removeAll(keepingCapacity: true) }
        guard let first = line.first else { return dispatch() }
        if first == UInt8(ascii: ":") { return nil }
        let field: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let colon = line.firstIndex(of: UInt8(ascii: ":")) {
            field = line[..<colon]
            value = line[(colon + 1)...]
            if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = []
        }
        if field.elementsEqual("data".utf8) {
            data.append(contentsOf: value)
            data.append(0x0A)
            hasData = true
        }
        return nil
    }

    private mutating func dispatch() -> String? {
        defer {
            data.removeAll(keepingCapacity: true)
            hasData = false
        }
        guard hasData else { return nil }
        return String(decoding: data.dropLast(), as: UTF8.self)
    }
}

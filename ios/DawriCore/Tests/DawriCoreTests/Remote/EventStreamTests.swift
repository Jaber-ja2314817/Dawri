import Foundation
import Testing
@testable import DawriCore

@Suite("Remote: the event stream parser")
struct EventStreamParserTests {
    private func events(_ chunks: [String]) -> [String] {
        var parser = EventStreamParser()
        return chunks.flatMap { parser.push(contentsOf: Array($0.utf8)) }
    }

    @Test func `the backend's own stream`() {
        // sse_stream in backend/events.py: a comment, heartbeats, then data events.
        let text = ": connected\n\n: heartbeat\n\n" + #"data: {"type":"ticket.reserved"}"# + "\n\n"
            + #"data: {"type":"demo.reset"}"# + "\n\n"
        #expect(events([text]) == [#"{"type":"ticket.reserved"}"#, #"{"type":"demo.reset"}"#])
    }

    @Test func `comments give nothing`() {
        #expect(events([": connected\n\n", ":\n\n", ": heartbeat\r\n\r\n"]).isEmpty)
    }

    @Test func `multi-line data joins with a line feed`() {
        #expect(events(["data: one\ndata: two\ndata:three\n\n"]) == ["one\ntwo\nthree"])
    }

    @Test func `an empty data field still dispatches`() {
        #expect(events(["data\n\n", "data:\n\n"]) == ["", ""])
    }

    @Test func `only data fields count`() {
        #expect(events(["event: ping\nid: 4\nretry: 10\n\n"]).isEmpty)
        #expect(events(["event: ping\ndata: x\nid: 4\n\n"]) == ["x"])
        #expect(events(["database: x\n\n", "Data: x\n\n"]).isEmpty)
    }

    @Test func `CRLF, CR and LF all end a line`() {
        #expect(events(["data: a\r\n\r\ndata: b\r\rdata: c\n\n"]) == ["a", "b", "c"])
    }

    @Test func `a CRLF split across chunks is one line end`() {
        #expect(events(["data: a\r", "\n\r", "\ndata: b\r", "\r"]) == ["a", "b"])
    }

    @Test func `an event split at every byte`() {
        let text = ": connected\r\n\r\ndata: {\"type\":\"x\"}\r\ndata: é\r\n\r\n"
        var parser = EventStreamParser()
        var found: [String] = []
        for byte in text.utf8 { if let event = parser.push(byte) { found.append(event) } }
        #expect(found == ["{\"type\":\"x\"}\né"])
    }

    @Test func `an unfinished event at the end is never dispatched`() {
        #expect(events(["data: a\n"]).isEmpty)
        #expect(events(["data: a"]).isEmpty)
    }

    @Test func `one space after the colon is dropped, not more`() {
        #expect(events(["data:  two\n\n"]) == [" two"])
    }

    @Test func `a leading byte order mark is dropped`() {
        var parser = EventStreamParser()
        #expect(parser.push(contentsOf: [0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)) == ["x"])
    }
}

/// `visitUpdates` over the stub: the header, the events and the end, as stream.ts handles them.
@Suite("Remote: live updates")
struct RemoteUpdatesTests {
    private func collect(_ stream: AsyncStream<VisitUpdate>) async -> [VisitUpdate] {
        var seen: [VisitUpdate] = []
        for await update in stream { seen.append(update) }
        return seen
    }

    @Test(.timeLimit(.minutes(1)))
    func `open, comments, events and the end`() async throws {
        let server = StubServer()
        server.on("GET", "/api/visits/V_1/stream", .events([
            ": connected\n\n", "data: {\"type\":\"a\"}\n", "\n: heartbeat\n\n",
            "data: one\r\ndata: two\r\n\r\n", "data: x\r", "\n\r\n",
        ], end: true))
        let service = try server.service(token: "secret")
        let seen = await collect(await service.visitUpdates(visitId: "V_1"))
        #expect(seen == [.open, .changed, .changed, .changed, .dropped])

        let sent = try #require(server.last)
        #expect(sent.line == "GET /api/visits/V_1/stream")
        #expect(sent.header("Authorization") == "Bearer secret")
        #expect(sent.header("Accept") == "text/event-stream")
        #expect(sent.query == nil, "The token goes in the header, never the URL")
        #expect(server.lines == ["GET /api/health", "GET /api/visits/V_1/stream"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `events that arrive later each mean read again`() async throws {
        let server = StubServer()
        server.on("GET", "/api/visits/V_1/stream", .events([": connected\n\n"], end: false))
        let service = try server.service(token: "t")
        var updates = await service.visitUpdates(visitId: "V_1").makeAsyncIterator()
        #expect(await updates.next() == .open)
        server.push("data: {\"type\":\"ticket.called\"}\n\n")
        #expect(await updates.next() == .changed)
        server.push(": heartbeat\n\ndata: a\n")
        server.push("\n")
        #expect(await updates.next() == .changed)
        server.endStreams()
        #expect(await updates.next() == .dropped)
        #expect(await updates.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [401, 403, 404, 500])
    func `a refused stream only drops`(status: Int) async throws {
        let server = StubServer()
        server.on("GET", "/api/visits/V_1/stream", .streamStatus(status))
        let seen = await collect(try await server.service(token: "t").visitUpdates(visitId: "V_1"))
        #expect(seen == [.dropped])
    }

    @Test(.timeLimit(.minutes(1)))
    func `a failed connection only drops`() async throws {
        let server = StubServer()
        server.on("GET", "/api/visits/V_1/stream", .fail(.networkConnectionLost))
        let seen = await collect(try await server.service(token: "t").visitUpdates(visitId: "V_1"))
        #expect(seen == [.dropped])
    }

    @Test(.timeLimit(.minutes(1)))
    func `dropStreams ends the visit's streams and no other`() async throws {
        let server = StubServer()
        server.on("GET", "/api/visits/V_1/stream", .events([": connected\n\n"], end: false))
        server.on("GET", "/api/visits/V_2/stream", .events([": connected\n\n"], end: false))
        let service = try server.service(token: "t")
        var first = await service.visitUpdates(visitId: "V_1").makeAsyncIterator()
        var second = await service.visitUpdates(visitId: "V_2").makeAsyncIterator()
        #expect(await first.next() == .open)
        #expect(await second.next() == .open)
        await service.dropStreams(visitId: "V_1")
        #expect(await first.next() == .dropped)
        #expect(await first.next() == nil)
        server.push("data: still here\n\n")
        #expect(await second.next() == .changed)
        await service.dropStreams()
        #expect(await second.next() == .dropped)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a reader that stops listening ends the request`() async throws {
        let server = StubServer()
        server.on("GET", "/api/visits/V_1/stream", .events([": connected\n\n"], end: false))
        let service = try server.service(token: "t")
        let reader = Task {
            for await update in await service.visitUpdates(visitId: "V_1") where update == .open {
                break
            }
        }
        await reader.value
        while server.openStreams > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.openStreams == 0)
    }
}

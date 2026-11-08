import Foundation
import Testing
@testable import DawriCore

private struct Typed: Sendable, CustomTestStringConvertible {
    let text: String
    var testDescription: String { text.debugDescription }
    init(_ text: String) { self.text = text }
}

/// Every spelling of a Hugging Face host that a field could be handed. Each must be refused as a
/// forbidden host, never accepted under any other reading.
private let huggingFace: [Typed] = [
    // Plain, sub-domains and the bare suffix.
    "https://hf.space", "https://dawri.hf.space", "https://xtamim-dawri.hf.space",
    "https://a.b.c.hf.space", "https://huggingface.co", "https://www.huggingface.co",
    "https://api-inference.huggingface.co", "https://router.huggingface.co",
    "https://hf.co", "https://api.hf.co",
    // Case.
    "HTTPS://DAWRI.HF.SPACE", "https://Dawri.Hf.Space", "https://HuggingFace.CO", "hTtPs://HF.CO",
    // Trailing dot, one or more.
    "https://dawri.hf.space.", "https://huggingface.co.", "https://hf.co.",
    "https://dawri.hf.space..", "https://hf.space./",
    // User info before the host.
    "https://user@dawri.hf.space", "https://user:pass@huggingface.co",
    "https://localhost@dawri.hf.space", "http://127.0.0.1@dawri.hf.space",
    "https://a@b@huggingface.co", "https://me@hf.co",
    // Port.
    "https://dawri.hf.space:443", "https://huggingface.co:8443", "http://dawri.hf.space:80",
    "https://hf.co:443/", "https://user@dawri.hf.space:8100/",
    // Every trick at once.
    "  HTTPS://Admin:Secret@Dawri.HF.Space.:443/  ", "HTTPS://X@API.HF.CO.:8443",
    // No scheme.
    "dawri.hf.space", "huggingface.co:443", "HF.SPACE.",
    // Named anywhere, even where a client would not send it.
    "http://localhost/?next=dawri.hf.space", "http://localhost#huggingface.co",
    "http://localhost/huggingface", "https://dawri.hf.space\\@localhost",
    "http://localhost\\@dawri.hf.space", "https://myhf.space", "https://notahuggingfacehost.example",
    // Other schemes, which are refused regardless.
    "ws://dawri.hf.space", "ftp://huggingface.co",
].map(Typed.init)

/// Not plain ASCII or escaped, so a look-alike or encoded host cannot slip past the name check.
private let disguised: [Typed] = [
    "https://dawri.hf%2Espace", "https://dawri%2Ehf.space", "https://huggingface%2eco",
    "https://dawri.hf\u{2024}space", "https://dawri.hf\u{FF0E}space", "https://ｈｆ.space",
    "https://huggingface\u{200B}.co", "https://dawri.h\u{00AD}f.space", "https://hf\u{0301}.space",
    "https://xn--hf-space.example\u{200D}", "https://dawri .hf.space", "https://dawri.hf.space\t",
    "https://dawri\u{0000}.hf.space",
].map(Typed.init)

@Suite("ServerAddress: no Hugging Face host gets through")
struct ServerAddressHuggingFaceTests {
    @Test(arguments: huggingFace)
    fileprivate func `refused as a forbidden host`(typed: Typed) {
        let verdict = ServerAddress.parse(typed.text)
        if typed.text.hasPrefix("ws:") || typed.text.hasPrefix("ftp:") {
            #expect(verdict == .refused(.forbiddenHost) || verdict == .refused(.unsupportedScheme))
        } else {
            #expect(verdict == .refused(.forbiddenHost))
        }
        #expect(verdict.url == nil)
    }

    @Test(arguments: disguised)
    fileprivate func `refused when disguised`(typed: Typed) {
        let verdict = ServerAddress.parse(typed.text)
        #expect(verdict.url == nil, "\(verdict)")
    }

    /// Whatever the guard accepts, the host of the URL it gives back is never a Hugging Face one.
    @Test(arguments: huggingFace + disguised)
    fileprivate func `nothing accepted resolves to one`(typed: Typed) {
        let host = ServerAddress.parse(typed.text).url?.host() ?? ""
        #expect(!host.contains("hf.space"))
        #expect(!host.contains("huggingface"))
        #expect(!host.hasSuffix("hf.co"))
    }
}

@Suite("ServerAddress: http only on the local network")
struct ServerAddressSchemeTests {
    @Test(arguments: [
        "http://localhost", "http://localhost:8100", "http://localhost.:8100/", "http://LOCALHOST:8100",
        "http://127.0.0.1:8100", "http://127.255.255.254", "http://10.0.0.5:8100", "http://10.255.0.1",
        "http://172.16.0.1:8100", "http://172.31.255.255", "http://192.168.1.20:8100",
        "http://192.168.0.1/", "http://169.254.10.20:8100", "http://jabers-mac.local:8100",
        "http://Jabers-MacBook.local.", "http://[::1]:8100", "http://[fe80::1]:8100",
        "http://[FE80::1:2:3:4]", "http://[febf::1]", "http://[0:0:0:0:0:0:0:1]",
    ].map(Typed.init))
    fileprivate func `accepted on a local address`(typed: Typed) throws {
        let url = try #require(ServerAddress.parse(typed.text).url, "\(typed.text)")
        #expect(url.scheme == "http")
    }

    @Test(arguments: [
        "http://example.com", "http://dawri.example.com:8100", "http://8.8.8.8", "http://172.15.0.1",
        "http://172.32.0.1", "http://192.169.1.1", "http://169.255.0.1", "http://11.0.0.1",
        "http://128.0.0.1", "http://0.0.0.0", "http://[2001:db8::1]", "http://[fec0::1]",
        "http://[::2]", "http://localhost.example.com", "http://local", "http://mylocal",
        "http://example.local.com", "http://192.168.1.20.nip.io",
    ].map(Typed.init))
    fileprivate func `refused as insecure anywhere else`(typed: Typed) {
        #expect(ServerAddress.parse(typed.text) == .refused(.insecure))
    }

    @Test(arguments: [
        "https://example.com", "https://dawri.example.com:8443", "https://8.8.8.8",
        "https://192.168.1.20:8100", "https://localhost", "https://[2001:db8::1]:443",
    ].map(Typed.init))
    fileprivate func `https is allowed anywhere that is not Hugging Face`(typed: Typed) throws {
        let url = try #require(ServerAddress.parse(typed.text).url, "\(typed.text)")
        #expect(url.scheme == "https")
    }

    @Test func `no scheme: http on a local host, https elsewhere`() {
        #expect(ServerAddress.parse("192.168.1.20:8100").url?.absoluteString == "http://192.168.1.20:8100")
        #expect(ServerAddress.parse("localhost:8100").url?.absoluteString == "http://localhost:8100")
        #expect(ServerAddress.parse("example.com").url?.absoluteString == "https://example.com")
    }

    @Test(arguments: ["ftp://192.168.1.20", "ws://localhost:8100", "file:///etc/hosts", "httpx://localhost",
                      "javascript://localhost"].map(Typed.init))
    fileprivate func `other schemes are refused`(typed: Typed) {
        #expect(ServerAddress.parse(typed.text) == .refused(.unsupportedScheme))
    }
}

@Suite("ServerAddress: the shape of what is typed")
struct ServerAddressShapeTests {
    @Test func `the URL given back is only scheme, host and port`() {
        #expect(ServerAddress.parse("  HTTP://192.168.1.20:8100/  ").url?.absoluteString == "http://192.168.1.20:8100")
        #expect(ServerAddress.parse("http://Jabers-Mac.Local.:8100").url?.absoluteString == "http://jabers-mac.local:8100")
        #expect(ServerAddress.parse("http://[FE80::1]:8100").url?.absoluteString == "http://[fe80::1]:8100")
    }

    @Test(arguments: ["", "   ", "\n\t"].map(Typed.init))
    fileprivate func `nothing typed`(typed: Typed) {
        #expect(ServerAddress.parse(typed.text) == .refused(.empty))
    }

    @Test(arguments: ["http://user@localhost:8100", "http://a:b@192.168.1.20", "https://me@example.com"].map(Typed.init))
    fileprivate func `user info is refused`(typed: Typed) {
        #expect(ServerAddress.parse(typed.text) == .refused(.userInfo))
    }

    @Test(arguments: [
        "http://localhost:8100/api", "http://localhost:8100/api/health", "http://localhost?x=1",
        "http://localhost#top", "http://localhost//", "http://localhost\\evil.example",
    ].map(Typed.init))
    fileprivate func `a path, query or fragment is refused`(typed: Typed) {
        #expect(ServerAddress.parse(typed.text) == .refused(.path))
    }

    @Test(arguments: [
        // Ports.
        "http://localhost:", "http://localhost:0", "http://localhost:65536", "http://localhost:123456",
        "http://localhost:80a", "http://localhost:-1", "http://[::1]:", "http://[::1]8100",
        // Names.
        "http://", "http://.", "http://-a.local", "http://a-.local", "http://a..local", "http://a_b.local",
        "http://exa$mple.com", "https://\(String(repeating: "a", count: 64)).com",
        // Addresses a resolver could read another way.
        "http://127.1", "http://2130706433", "http://0x7f.0.0.1", "http://0x7f000001", "http://010.0.0.1",
        "http://192.168.001.20", "http://256.0.0.1", "http://192.168.1", "http://1.2.3.4.5",
        // IPv6.
        "http://[::1", "http://[1::2::3]", "http://[12345::1]", "http://[::ffff:127.0.0.1]",
        "http://[fe80::1%en0]", "http://[g::1]", "http://[]", "http://::1:8100",
        // Something that is not an address.
        "localhost:http", "http:/localhost", "mailto:me@example.com",
    ].map(Typed.init))
    fileprivate func `a shape this guard will not read is refused`(typed: Typed) {
        let verdict = ServerAddress.parse(typed.text)
        #expect(verdict.url == nil, "\(verdict)")
    }
}

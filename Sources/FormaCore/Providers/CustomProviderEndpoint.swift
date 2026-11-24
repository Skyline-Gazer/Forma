import Foundation

/// Normalization of the one user-configured send target: an OpenAI-compatible
/// Chat Completions server. Nothing here touches the network. The returned URL
/// is the exact value `EgressEndpoint.custom` records in the scope, the value
/// the egress gate re-compares at send time, and the only URL the transport is
/// allowed to build a request against for this provider.
///
/// Rules, in order of failure:
///   1. The value must parse as an absolute http(s) URL with a host.
///   2. No userinfo, query or fragment. A key smuggled into a saved base URL
///      would ride along with every authorized request, and the scope identity
///      could not be compared against a stable string.
///   3. Scheme is https everywhere except the loopback interfaces, where a
///      local server (Ollama-style) legitimately speaks plain http. Loopback is
///      decided from the host *literal*, never from a DNS answer, so the saved
///      URL string itself states how far the data goes.
///   4. The path must address the Chat Completions operation. A `/v1` (or
///      bare-host) base is completed; a path that already names
///      `/chat/completions` is kept; any other path is a configuration error
///      rather than something to guess at.
public enum CustomProviderEndpoint {
    /// The suffix every accepted base is completed to.
    static let chatCompletionsSuffix = "/chat/completions"

    public static func chatCompletionsURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let host = url.host, !host.isEmpty else { return nil }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        switch url.scheme?.lowercased() {
        case "https": break
        case "http": guard isLoopback(host: host) else { return nil }
        default: return nil
        }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        let finalPath: String
        if path.isEmpty {
            finalPath = "/v1" + chatCompletionsSuffix
        } else if path.hasSuffix(chatCompletionsSuffix) {
            finalPath = path
        } else if path.hasSuffix("/v1") {
            finalPath = path + chatCompletionsSuffix
        } else {
            return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = finalPath
        components.query = nil
        components.fragment = nil
        guard let result = components.url else { return nil }
        return result.normalized()
    }

    /// Loopback by name or literal address: `localhost`, `::1` and the whole
    /// `127.0.0.0/8` block (a local server is commonly bound to `127.0.0.2`).
    /// A host that merely *resolves* to loopback is not loopback for consent
    /// purposes; the written URL must say so.
    public static func isLoopback(host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" { return true }
        let bare = lowered.hasPrefix("[") && lowered.hasSuffix("]")
            ? String(lowered.dropFirst().dropLast()) : lowered
        if bare == "::1" || bare == "0:0:0:0:0:0:0:1" { return true }
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for (index, part) in parts.enumerated() {
            guard part.count >= 1, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), (0...255).contains(value) else { return false }
            if index == 0, value != 127 { return false }
        }
        return true
    }
}

extension URL {
    /// Collapse whatever `URLComponents` produced to one canonical spelling so
    /// the scope identity, the ticket endpoint and the compared wire URL are
    /// byte-equal for the same server. Lowercases scheme and host the way the
    /// egress contract's existing cloud identities already are written.
    fileprivate func normalized() -> URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.url
    }
}

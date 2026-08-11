import Foundation

/// Whether a pairing address looks like it lives on a private network the
/// operator controls (D-08, D-11).
///
/// Since ADR 0003 the connection to a server Mac is plain HTTP, so its privacy
/// comes entirely from the network it runs on: a Tailscale tailnet or a
/// trusted LAN. This is what decides whether the pairing pane shows that
/// warning. It never blocks - an operator with a legitimate exception (a
/// VPN-mapped public address, say) can still pair - so a false positive costs
/// a dismissible warning, and a false negative costs a missing one.
enum TrustedNetworkAddress {
    static func isTrusted(_ address: String) -> Bool {
        let host = normalize(address)
        guard !host.isEmpty else { return true }
        if let octets = ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }
        if host.hasPrefix("[") || host.contains(":") {
            // An IPv6 literal: only loopback is recognizably trusted without
            // parsing the full address space.
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return bare == "::1"
        }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // Tailscale MagicDNS names. The tailnet itself is the trust boundary,
        // and its addresses are in the CGNAT range handled above; this covers
        // the name form the pairing pane is actually given.
        if host.hasSuffix(".ts.net") { return true }
        return false
    }

    private static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _):
            return true                                    // RFC1918 10/8
        case (172, 16...31):
            return true                                    // RFC1918 172.16/12
        case (192, 168):
            return true                                    // RFC1918 192.168/16
        case (100, 64...127):
            return true                                    // CGNAT 100.64/10 - Tailscale
        case (127, _):
            return true                                    // loopback
        default:
            return false
        }
    }
}

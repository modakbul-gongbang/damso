import Foundation

/// Where this Mac keeps the paired server's bearer token (D-07, ADR 0003).
///
/// A 0600 file, mirroring how the server itself stores the same secret, rather
/// than the Keychain: the token is also what an MCP client's own config needs
/// to reach `/mcp`, and a file path is something the operator can point that
/// config at without going through `security find-generic-password`.
protocol ServerTokenStoring {
    func read() throws -> String?
    func write(_ token: String) throws
    func delete() throws
}

/// Deliberately anchored to the fixed application-support directory rather
/// than the user-selectable storage root: the store is what `damso.migration`
/// copies, backs up, and relocates, and a credential must never ride along
/// with a store export (the client-side half of D-24's rule).
final class FileServerTokenStore: ServerTokenStoring {
    static let defaultDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Damso", isDirectory: true)
        .appendingPathComponent(".client-credentials", isDirectory: true)

    private let fileURL: URL
    private let fileManager: FileManager

    init(directory: URL = FileServerTokenStore.defaultDirectory, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("server-token", isDirectory: false)
        self.fileManager = fileManager
    }

    func read() throws -> String? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    func write(_ token: String) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(token.utf8).write(to: fileURL, options: [.atomic])
        // `.atomic` writes through a temporary file and renames it, so the
        // permissions have to be applied to the final path afterward - setting
        // them before the write would be lost with the temporary file.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

final class InMemoryServerTokenStore: ServerTokenStoring {
    private var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func read() throws -> String? { token }
    func write(_ token: String) throws { self.token = token }
    func delete() throws { token = nil }
}

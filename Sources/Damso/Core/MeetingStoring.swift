import Foundation

/// The full canonical-store contract the app touches, extracted from the
/// concrete `MeetingStore` (R3). `MeetingStore` remains the local
/// implementation - the machine that owns the canonical store always talks
/// to it directly, on the mini or in a single-machine setup. A remote
/// implementation (a client Mac reaching a mini's store) reads through a
/// local cache and writes through `damso.serve`, but exposes the exact same
/// surface so no caller needs to know which one it holds.
///
/// No code outside `MeetingStore.swift` and its extensions may construct a
/// `CanonicalStoreLayout` or read `MeetingStore.rootURL` directly - every
/// canonical-store touch point goes through one of these methods instead
/// (D-C1/D-C3, `MeetingWorkspaceController` call-site audit).
protocol MeetingStoring: AnyObject {
    // MARK: Lifecycle

    func bootstrap() throws
    func health() -> StorageHealth

    /// Whether this store is ready to read without side effects: locally,
    /// whether the root directory already exists (so opening the app never
    /// silently creates a store the user hasn't chosen yet); remotely,
    /// whether remote execution has been configured at all.
    var isConfigured: Bool { get }

    // MARK: Path resolution for backend requests and local file access
    //
    // `*Path` strings identify a location on whichever machine owns the
    // canonical store (embedded in a damso.serve/processing request body).
    // `*URL` values identify a location on THIS machine to read with
    // FileManager - the canonical store locally, or the synced cache
    // remotely. The two differ only in remote mode; conflating them there
    // would either send a local-only path to the mini or try to open a file
    // that was never synced.

    var storeRootPath: String { get }
    var peoplesDirectoryPath: String { get }
    func recordDirectoryPath(stem: String) -> String
    func recordDirectoryURL(stem: String) -> URL

    /// A location on THIS machine for purely local bookkeeping that never
    /// becomes part of a backend request or the canonical store itself (e.g.
    /// External Sync's checkpoint file) - locally, the canonical store root;
    /// remotely, the local cache mirror, never the server's own
    /// `storeRootPath` (which is a foreign filesystem path, unwritable and
    /// often nonexistent on this Mac).
    var localRootURL: URL { get }

    /// Whether this Mac holds the record's own audio files, as opposed to
    /// only the metadata mirror of a record whose audio lives on the server.
    /// A `FileManager` presence check on audio is only meaningful when this
    /// is true; asking it of a handed-off record answers "missing" for a
    /// perfectly intact recording.
    func holdsRecordAudioLocally(stem: String) -> Bool

    // MARK: Records

    func createRecord(_ draft: MeetingDraft) throws -> MeetingRecord
    func commit(_ record: MeetingRecord, artifacts: [String: Data]) throws
    func commitImported(_ record: MeetingRecord, movingAudioFrom audioURL: URL) throws
    func load(stem: String) throws -> MeetingRecord
    func list() throws -> [MeetingRecord]
    func update(_ record: MeetingRecord) throws
    func delete(stem: String) throws
    func quarantine(stem: String, reason: String) throws
    func invalidatePhaseOneDependents(stem: String) throws
    func invalidateCleanupOverlay(stem: String) throws
    func checksum(stem: String) throws -> String

    // MARK: People

    func listPeople(records: [MeetingRecord]) throws -> [LocalPersonProfile]
    func profileNotes(name: String) -> String?
    func profileEmail(name: String) -> String?
    func mergeProfiles(primaryName: String, absorbedName: String) throws -> ProfileMergeOutcome
    func deletePerson(named name: String, aliases: [String]) throws -> ProfileDeleteOutcome
    func unmarkPersonDeleted(_ name: String)

    // MARK: Processing artifacts

    func processingArtifacts(stem: String) throws -> MeetingProcessingArtifacts
    func hasPhaseOneTranscript(stem: String) -> Bool
    func hasCompletePhaseOneReviewArtifacts(stem: String) -> Bool
    func cachedSpeakerSuggestions(stem: String) -> [String: [SpeakerSuggestion]]
    func hasCachedSpeakerSuggestions(stem: String) -> Bool
    func writeSpeakerSuggestions(_ suggestions: [SpeakerSuggestion], stem: String)
    func hasCleanupOverlay(stem: String) -> Bool
    func storedSummary(stem: String) throws -> StructuredSummary?
    func storedSummaryArtifact(stem: String) throws -> StoredSummaryArtifact?
}

extension MeetingStoring {
    /// Protocol requirements cannot carry a default argument value the way
    /// `MeetingStore.commit(_:artifacts:)` itself does; this restores the
    /// no-artifacts call shape for callers going through `any MeetingStoring`.
    func commit(_ record: MeetingRecord) throws {
        try commit(record, artifacts: [:])
    }
}

extension MeetingStore: MeetingStoring {
    var isConfigured: Bool { FileManager.default.fileExists(atPath: rootURL.path) }
    var storeRootPath: String { rootURL.path }
    var peoplesDirectoryPath: String { CanonicalStoreLayout(root: rootURL).peoples.path }
    var localRootURL: URL { rootURL }

    func recordDirectoryPath(stem: String) -> String {
        CanonicalStoreLayout(root: rootURL).recordDirectory(stem: stem).path
    }

    /// Always: a local store's records are whole on this Mac by definition.
    func holdsRecordAudioLocally(stem: String) -> Bool { true }

    func recordDirectoryURL(stem: String) -> URL {
        CanonicalStoreLayout(root: rootURL).recordDirectory(stem: stem)
    }
}

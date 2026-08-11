import Foundation

/// A throwaway `UserDefaults` suite that removes itself when the test ends.
///
/// Tests need an isolated suite because they run in parallel and would
/// otherwise fight over the global preference. Creating one per test is
/// correct; the trap is cleanup. Clearing the suite only on the way *in*
/// leaks one persistent domain per call - the test writes to it, nothing ever
/// removes it, and the plists pile up in `~/Library/Preferences` forever.
/// Two separate test files did exactly that, and 725 + 181 stale files had
/// accumulated before anyone looked.
///
/// Bind this to a local so it lives for the whole test body; `deinit` is what
/// does the cleanup.
final class ScratchDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init(prefix: String = "damso-tests-scratch") {
        suiteName = "\(prefix)-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeSuite(named: suiteName)
        // Those two empty the suite but still leave a zero-key plist behind,
        // so remove the file too. The suite name carries a UUID this instance
        // generated, so the only file this can ever match is the one it
        // created. Note this does not always win: `cfprefsd` caches the suite
        // and can write an empty plist back out after the delete, so a full
        // run still leaves a handful of 42-byte files. Flushing the daemon
        // first (`CFPreferencesAppSynchronize`) was tried and changed nothing.
        // What matters is that no test *data* survives a run anymore.
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}

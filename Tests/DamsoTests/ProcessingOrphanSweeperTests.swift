import Darwin
import Testing
@testable import Damso

struct ProcessingOrphanSweeperTests {
    @Test
    func matchesOrphanedProcessingByParentAndModule() {
        let ps = """
        4321 1 /usr/bin/python3 -m damso.processing --request -
        4322 1 /usr/bin/python3 -m damso.summary --request -
        4400 900 /usr/bin/python3 -m damso.processing --request -
        5000 1 /usr/bin/python3 -m damso.index --store /x
        6000 1 /Applications/Safari.app/Contents/MacOS/Safari
        """
        let orphans = ProcessingOrphanSweeper.matchingPIDs(psOutput: ps, parent: 1)
        #expect(orphans.sorted() == [4321, 4322])
    }

    @Test
    func matchesOwnChildrenByParentPID() {
        let ps = """
        7001 4242 /usr/bin/python3 -m damso.processing --request -
        7003 7001 /usr/bin/python3 -m damso.processing --whisper-worker -
        7002 1 /usr/bin/python3 -m damso.processing --request -
        """
        #expect(ProcessingOrphanSweeper.matchingPIDs(psOutput: ps, parent: 4242) == [7003, 7001])
    }

    @Test
    func matchesOrphanedRootAndNestedWhisperWorkerLeafFirst() {
        let ps = """
        7101 1 /usr/bin/python3 -m damso.processing --request -
        7102 7101 /usr/bin/python3 -m damso.processing --whisper-worker -
        7103 7101 /opt/homebrew/bin/ffmpeg -i local-audio.caf output.wav
        7201 9000 /usr/bin/python3 -m damso.processing --request -
        7202 7201 /usr/bin/python3 -m damso.processing --whisper-worker -
        """
        #expect(ProcessingOrphanSweeper.matchingPIDs(psOutput: ps, parent: 1) == [7102, 7103, 7101])
    }

    @Test
    func productionSnapshotCapturesIdentityAndKeepsLeafFirstOrder() {
        let ps = """
          7101     1 Tue Jul 21 09:02:22 2026     /usr/bin/python3 -m damso.processing --request -
          7102  7101 Tue Jul 21 09:02:23 2026     /opt/homebrew/bin/ffmpeg -i local-audio.caf output.wav
        """
        let targets = ProcessingOrphanSweeper.matchingTargets(psOutput: ps, parent: 1)

        #expect(targets.map(\.pid) == [7102, 7101])
        #expect(targets[0].parent == 7101)
        #expect(targets[0].command == "/opt/homebrew/bin/ffmpeg -i local-audio.caf output.wav")
        #expect(targets[0].identity == "Tue Jul 21 09:02:23 2026 /opt/homebrew/bin/ffmpeg -i local-audio.caf output.wav")
        #expect(!targets[0].isRoot)
        #expect(targets[1].identity == "Tue Jul 21 09:02:22 2026 /usr/bin/python3 -m damso.processing --request -")
        #expect(targets[1].isRoot)
    }

    @Test
    func ignoresIndexAndUnrelatedProcesses() {
        let ps = """
        8000 1 /usr/bin/python3 -m damso.index --store /x
        8001 1 node server.js
        """
        #expect(ProcessingOrphanSweeper.matchingPIDs(psOutput: ps, parent: 1).isEmpty)
    }

    @Test
    func terminationEscalatesOnlySurvivingProcessesAfterTheGracePeriod() {
        var signals: [(pid_t, Int32)] = []
        let targets = [
            ProcessingOrphanSweeper.ProcessTarget(
                pid: 7102,
                parent: 7101,
                command: "worker",
                identity: "identity-7102",
                isRoot: false
            ),
            ProcessingOrphanSweeper.ProcessTarget(
                pid: 7101,
                parent: 1,
                command: "root",
                identity: "identity-7101",
                isRoot: true
            ),
        ]
        ProcessingOrphanSweeper.terminate(
            targets,
            graceInterval: 0,
            sendSignal: { pid, signal in signals.append((pid, signal)) },
            processGroupID: { _ in nil },
            isAlive: { pid in pid == 7102 },
            processIdentity: { pid in "identity-\(pid)" },
            pause: { _ in Issue.record("zero grace must not pause") }
        )
        #expect(signals.count == 3)
        #expect(signals[0].0 == 7102 && signals[0].1 == SIGTERM)
        #expect(signals[1].0 == 7101 && signals[1].1 == SIGTERM)
        #expect(signals[2].0 == 7102 && signals[2].1 == SIGKILL)
    }

    @Test
    func terminationDoesNotSignalPIDReusedBeforeTERM() {
        var signals: [(pid_t, Int32)] = []
        ProcessingOrphanSweeper.terminate(
            [
                ProcessingOrphanSweeper.ProcessTarget(
                    pid: 8101,
                    parent: 1,
                    command: "original",
                    identity: "original",
                    isRoot: true
                ),
            ],
            graceInterval: 0,
            sendSignal: { pid, signal in signals.append((pid, signal)) },
            processGroupID: { _ in Issue.record("an unverified PID must not be inspected"); return nil },
            isAlive: { _ in Issue.record("an unverified PID must not be polled"); return true },
            processIdentity: { _ in "replacement" },
            pause: { _ in Issue.record("zero grace must not pause") }
        )
        #expect(signals.isEmpty)
    }

    @Test
    func terminationDoesNotEscalatePIDReusedAfterTERM() {
        var signals: [(pid_t, Int32)] = []
        var identityReads = 0
        ProcessingOrphanSweeper.terminate(
            [
                ProcessingOrphanSweeper.ProcessTarget(
                    pid: 8201,
                    parent: 1,
                    command: "original",
                    identity: "original",
                    isRoot: true
                ),
            ],
            graceInterval: 0,
            sendSignal: { pid, signal in signals.append((pid, signal)) },
            processGroupID: { _ in nil },
            isAlive: { _ in true },
            processIdentity: { _ in
                identityReads += 1
                return identityReads == 1 ? "original" : "replacement"
            },
            pause: { _ in Issue.record("zero grace must not pause") }
        )
        #expect(signals.count == 1)
        #expect(signals[0].0 == 8201 && signals[0].1 == SIGTERM)
    }

    @Test
    func terminationSignalsDedicatedRootGroupAfterSnapshotDescendants() {
        var signals: [String] = []
        let targets = [
            ProcessingOrphanSweeper.ProcessTarget(
                pid: 9102,
                parent: 9101,
                command: "ffmpeg",
                identity: "child",
                isRoot: false
            ),
            ProcessingOrphanSweeper.ProcessTarget(
                pid: 9101,
                parent: 1,
                command: "damso.processing",
                identity: "root",
                isRoot: true
            ),
        ]

        ProcessingOrphanSweeper.terminate(
            targets,
            graceInterval: 0,
            sendSignal: { pid, signal in signals.append("pid:\(pid):\(signal)") },
            processGroupID: { pid in pid == 9101 ? 9101 : nil },
            sendGroupSignal: { group, signal in
                signals.append("group:\(group):\(signal)")
                return true
            },
            isAlive: { _ in false },
            processIdentity: { pid in pid == 9101 ? "root" : "child" },
            pause: { _ in Issue.record("zero grace must not pause") }
        )

        #expect(signals == ["pid:9102:\(SIGTERM)", "group:9101:\(SIGTERM)"])
    }

    @Test
    func terminationDoesNotSignalGroupWhenRootIsReusedAfterGroupLookup() {
        var signals: [String] = []
        var identityReads = 0
        ProcessingOrphanSweeper.terminate(
            [
                ProcessingOrphanSweeper.ProcessTarget(
                    pid: 9201,
                    parent: 1,
                    command: "damso.processing",
                    identity: "original",
                    isRoot: true
                ),
            ],
            graceInterval: 0,
            sendSignal: { pid, signal in signals.append("pid:\(pid):\(signal)") },
            processGroupID: { _ in 9201 },
            sendGroupSignal: { group, signal in
                signals.append("group:\(group):\(signal)")
                return true
            },
            isAlive: { _ in Issue.record("a reused root must not be polled"); return false },
            processIdentity: { _ in
                identityReads += 1
                return identityReads == 1 ? "original" : "replacement"
            },
            pause: { _ in Issue.record("zero grace must not pause") }
        )

        #expect(signals.isEmpty)
    }

    @Test
    func terminationDoesNotEscalateGroupReusedAfterKILLGroupLookup() {
        var signals: [String] = []
        var identityReads = 0
        ProcessingOrphanSweeper.terminate(
            [
                ProcessingOrphanSweeper.ProcessTarget(
                    pid: 9301,
                    parent: 1,
                    command: "damso.processing",
                    identity: "original",
                    isRoot: true
                ),
            ],
            graceInterval: 0,
            sendSignal: { pid, signal in signals.append("pid:\(pid):\(signal)") },
            processGroupID: { _ in 9301 },
            sendGroupSignal: { group, signal in
                signals.append("group:\(group):\(signal)")
                return true
            },
            isAlive: { _ in true },
            processIdentity: { _ in
                identityReads += 1
                return identityReads < 4 ? "original" : "replacement"
            },
            pause: { _ in Issue.record("zero grace must not pause") }
        )

        #expect(signals == ["group:9301:\(SIGTERM)"])
    }
}

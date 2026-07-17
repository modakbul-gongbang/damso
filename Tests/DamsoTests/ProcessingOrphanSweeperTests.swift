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
        7002 1 /usr/bin/python3 -m damso.processing --request -
        """
        #expect(ProcessingOrphanSweeper.matchingPIDs(psOutput: ps, parent: 4242) == [7001])
    }

    @Test
    func ignoresIndexAndUnrelatedProcesses() {
        let ps = """
        8000 1 /usr/bin/python3 -m damso.index --store /x
        8001 1 node server.js
        """
        #expect(ProcessingOrphanSweeper.matchingPIDs(psOutput: ps, parent: 1).isEmpty)
    }
}

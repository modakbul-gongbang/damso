import Testing
@testable import Damso

@Test
func aRemoteStoreIsAlwaysTheClientRoleRegardlessOfTheServerArgument() {
    #expect(InstanceRole.current(isRemoteStore: true, arguments: ["Damso"]) == .client)
    #expect(InstanceRole.current(isRemoteStore: true, arguments: ["Damso", InstanceRole.serverRoleArgument]) == .client)
}

@Test
func aLocalStoreWithNoServerArgumentIsTheCombinedLegacyRole() {
    #expect(InstanceRole.current(isRemoteStore: false, arguments: ["Damso"]) == .combined)
    #expect(InstanceRole.current(isRemoteStore: false, arguments: ["Damso", "--export-icon", "/tmp/x.png"]) == .combined)
}

@Test
func aLocalStoreWithTheServerArgumentIsTheServerRole() {
    let role = InstanceRole.current(isRemoteStore: false, arguments: ["Damso", InstanceRole.serverRoleArgument])
    #expect(role == .server)
}

@Test
func onlyTheServerRoleStopsDetectingAndRecording() {
    #expect(InstanceRole.combined.detectsAndRecords)
    #expect(InstanceRole.client.detectsAndRecords)
    #expect(!InstanceRole.server.detectsAndRecords)
}

@Test
func onlyTheClientRoleStopsOrchestratingProcessing() {
    #expect(InstanceRole.combined.orchestratesProcessing)
    #expect(!InstanceRole.client.orchestratesProcessing)
    #expect(InstanceRole.server.orchestratesProcessing)
}

@Test
func localPythonExecutableIsNilWithoutTheArgument() {
    #expect(InstanceRole.localPythonExecutable(arguments: ["Damso"]) == nil)
    #expect(InstanceRole.localPythonExecutable(arguments: ["Damso", InstanceRole.serverRoleArgument]) == nil)
}

@Test
func localPythonExecutableReadsTheAbsolutePathFromItsArgument() {
    let path = InstanceRole.localPythonExecutable(arguments: [
        "Damso", InstanceRole.serverRoleArgument, "--local-python=/opt/homebrew/bin/python3.12",
    ])
    #expect(path == "/opt/homebrew/bin/python3.12")
}

import Foundation

// Assert-based check runner. Run with: swift run ClaudepitTests
// Add each task's check group to `groups` below.

let groups: [(String, () -> [Bool])] = [
    ("ClaudeCLI", claudeCLIChecks),
    ("ClaudeAuth", claudeAuthChecks),
    ("JSONFile", jsonFileChecks),
    ("PluginScanner", pluginScannerChecks),
    ("ConfigScanner", configScannerChecks),
    ("ConfigStore", configStoreChecks),
    ("WriteOps", writeOpsChecks),
    ("ToolInvocation", toolInvocationChecks),
    ("SessionScanner", sessionScannerChecks),
    ("SessionTranscript", sessionTranscriptChecks),
    ("TranscriptRender", transcriptRenderChecks),
    ("GroupStore", groupStoreChecks),
    ("SummaryStore", summaryStoreChecks),
    ("PlanQARunner", planQARunnerChecks),
    ("WorktreeScanner", worktreeScannerChecks),
    ("WorktreeInspector", worktreeInspectorChecks),
    ("DiffHunks", diffHunksChecks),
    ("WorktreeStager", worktreeStagerChecks),
    ("WorktreeResumer", worktreeResumerChecks),
    ("HomeAttention", homeAttentionChecks),
    ("MemoryLog", memoryLogChecks),
    ("AppConfigStore", appConfigStoreChecks),
    ("HookRegistration", hookRegistrationChecks),
    ("HerdrPath", herdrPathChecks),
    ("ManagedArtifacts", managedArtifactsChecks),
    ("ManagedInstaller", managedInstallerChecks),
    ("HookScripts", hookScriptsChecks),
    ("TaskCommandGuard", taskCommandGuardChecks),
    ("TaskModel", taskModelChecks),
    ("TopicStore", topicStoreChecks),
    ("BrainstormChangeSource", brainstormChangeSourceChecks),
]

var results: [Bool] = []
for (name, run) in groups {
    print("── \(name) ──")
    results += run()
}

let passed = results.filter { $0 }.count
let total = results.count
print("\n\(passed)/\(total) checks passed")
if passed != total { exit(1) }

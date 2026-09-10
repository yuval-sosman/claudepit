import SwiftUI
import ClaudepitCore

struct HookCard: View {
    let hook: Hook
    @ObservedObject var app: AppState
    @State private var expanded = false

    var body: some View {
        ExpandableCard(expanded: $expanded) { header } detail: { detail }
    }

    /// Set when this registration is one Claudepit installs — matched by value, so a command
    /// carried over from another machine (dead home path) is still recognised as ours.
    private var managedOwner: ManagedConfig? {
        ManagedArtifacts.owner(ofHookCommand: hook.command)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hook.event)
                        .font(.body).bold()
                    ProvenanceBadge(scope: hook.scope, origin: hook.origin)
                    if let managedOwner {
                        ManagedBadge(owner: managedOwner, app: app)
                    }
                }
                if !expanded {
                    Text((hook.matcher.map { "[\($0)] " } ?? "") + hook.command)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            // Deleting a managed hook is pointless — the next launch reinstalls it. Toggling the
            // config off in App Settings is the real action, so that's what we offer instead.
            OpenInEditorButton(url: hook.sourcePath,
                onDelete: hook.origin.pluginID == nil && managedOwner == nil ? {
                    try? WriteOps.removeHook(event: hook.event, command: hook.command,
                                             in: hook.sourcePath,
                                             epoch: Int(Date().timeIntervalSince1970))
                    app.store.reload(activePath: app.activePath)
                } : nil)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let managedOwner {
                Text(managedOwner.title).font(.subheadline).bold()
                Text(managedOwner.detail)
                    .font(.subheadline).foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    app.focusManagedConfigID = managedOwner.id
                    app.selected = .appConfig
                } label: {
                    Label("Manage in App Settings", systemImage: "gearshape.2")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let desc = HookCard.eventDescription(hook.event) {
                Text(desc)
                    .font(.subheadline).foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            SectionHeaderLabel("Command", icon: "terminal")
            Text(hook.command)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).padding(.horizontal, 9)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))

            if let matcher = hook.matcher {
                SectionHeaderLabel("Matcher", icon: "scope")
                Text(matcher)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            FilePathLabel(url: hook.sourcePath)
        }
    }

    static func eventDescription(_ event: String) -> String? {
        switch event {
        case "SessionStart":       return "Fires when a session begins or resumes. Opt-in setup phase."
        case "SessionEnd":         return "Fires when the session terminates."
        case "UserPromptSubmit":   return "Fires before Claude processes your prompt. Can inject additionalContext. Blockable."
        case "PreToolUse":         return "Fires before a tool executes. Can approve, deny, or modify. Blockable."
        case "PermissionRequest":  return "Fires when a tool needs a permission decision."
        case "PermissionDenied":   return "Fires when the user denies a permission."
        case "PostToolUse":        return "Fires after a tool succeeds."
        case "PostToolUseFailure": return "Fires after a tool fails."
        case "PostToolBatch":      return "Fires after a batch of tool calls completes."
        case "SubagentStart":      return "Fires when a subagent starts."
        case "SubagentStop":       return "Fires when a subagent stops."
        case "TaskCreated":        return "Fires when a task is created."
        case "TaskCompleted":      return "Fires when a task completes."
        case "Stop":               return "Fires when Claude finishes responding. Blockable."
        case "StopFailure":        return "Fires when Claude's response fails. Blockable."
        case "TeammateIdle":       return "Fires when a teammate becomes idle."
        case "PreCompact":         return "Fires before context compaction."
        case "PostCompact":        return "Fires after context compaction."
        case "Notification":       return "Async. Fires for notifications."
        case "ConfigChange":       return "Async. Fires on config change."
        case "PreModelSwitch":     return "Sequential. Fires before a model switch. Blockable."
        case "PostModelSwitch":    return "Async. Fires after a model change."
        case "WorktreeCreate":     return "Fires on worktree creation (isolation)."
        case "WorktreeRemove":     return "Fires on worktree teardown."
        case "CwdChanged":         return "Environment reactive. Fires when the working directory changes."
        case "FileChanged":        return "Environment reactive. Fires when a watched file changes."
        case "DirectoryAdded":     return "Environment reactive. Fires when a directory is added."
        case "InstructionsLoaded": return "Async. Fires when instructions are loaded."
        case "MessageDisplay":     return "Display event. Fires when a message is displayed."
        default:                   return nil
        }
    }
}

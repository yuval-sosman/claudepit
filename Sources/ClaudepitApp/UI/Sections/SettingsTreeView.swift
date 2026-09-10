import SwiftUI
import AppKit
import ClaudepitCore

// Keys where Claude Code merges child entries across layers instead of replacing the whole value.
private let mergeKeys: Set<String> = ["hooks"]

private func nodeMatches(_ val: Any, key: String, query: String) -> Bool {
    if key.localizedCaseInsensitiveContains(query) { return true }
    if let s = val as? String, s.localizedCaseInsensitiveContains(query) { return true }
    if let b = val as? Bool, "\(b)".contains(query) { return true }
    if let dict = val as? [String: Any] {
        return dict.contains { nodeMatches($0.value, key: $0.key, query: query) }
    }
    if let arr = val as? [Any] {
        return arr.enumerated().contains { nodeMatches($0.element, key: "\($0.offset)", query: query) }
    }
    return false
}

/// Every hook command string at or below `val`. Keyed on `"command"` so sibling strings that merely
/// look like one (`"type": "command"`, `"matcher": "*"`) are not mistaken for commands.
/// Pure — mirrors `nodeMatches`' shape.
private func hookCommands(in val: Any, key: String = "") -> [String] {
    if let s = val as? String { return key == "command" ? [s] : [] }
    if let dict = val as? [String: Any] { return dict.flatMap { hookCommands(in: $0.value, key: $0.key) } }
    if let arr = val as? [Any] { return arr.flatMap { hookCommands(in: $0, key: key) } }
    return []
}

/// The managed config owning **every** command beneath `val`, for the hook *entry* node.
///
/// Exclusive on purpose: `HookRegistration.prune` preserves foreign hooks that share an entry with
/// ours, so a hand-merged entry can hold both. Claiming the whole entry there would mislabel the
/// user's own hook as app-owned, so a single foreign command withholds the badge — the managed
/// `command` leaf inside still carries its own.
private func managedCommandOwner(_ val: Any) -> ManagedConfig? {
    let owners = hookCommands(in: val).map { ManagedArtifacts.owner(ofHookCommand: $0) }
    guard let first = owners.first ?? nil,
          owners.allSatisfy({ $0?.id == first.id }) else { return nil }
    return first
}

// MARK: - Main tree view

struct SettingsTreeView: View {
    @ObservedObject var app: AppState
    var showUnified: Bool = false
    var expandOverride: Bool? = nil
    var filterQuery: String = ""

    var body: some View {
        let layers = app.store.settingsLayers

        VStack(alignment: .leading, spacing: 16) {
            if layers.isEmpty {
                Text("No settings files found").foregroundStyle(.secondary)
            } else if showUnified {
                UnifiedSettingsTree(app: app, layers: layers, expandOverride: expandOverride, filterQuery: filterQuery)
            } else {
                let overriddenKeyPaths = computeOverriddenKeyPaths(layers)
                ForEach(Array(layers.enumerated()), id: \.offset) { idx, layer in
                    SettingsLayerSection(
                        layer: layer,
                        layerIndex: idx,
                        overriddenKeyPaths: overriddenKeyPaths,
                        expandOverride: expandOverride,
                        app: app,
                        filterQuery: filterQuery
                    )
                }
            }
        }
    }

    private func computeOverriddenKeyPaths(_ layers: [ConfigStore.SettingsLayer]) -> Set<String> {
        var result = Set<String>()
        for (idx, layer) in layers.enumerated() {
            for key in layer.raw.keys {
                guard !mergeKeys.contains(key) else { continue }
                for higherIdx in (idx + 1)..<layers.count {
                    if layers[higherIdx].raw[key] != nil {
                        result.insert("\(idx)/\(key)")
                        break
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Per-layer section

private struct SettingsLayerSection: View {
    let layer: ConfigStore.SettingsLayer
    let layerIndex: Int
    let overriddenKeyPaths: Set<String>
    var expandOverride: Bool? = nil
    @ObservedObject var app: AppState
    var filterQuery: String = ""

    @State private var showingJsonEditor = false

    private var scopeColor: Color {
        switch layer.scope {
        case .global:  return .blue
        case .project: return .green
        case .local:   return .orange
        default:       return .secondary
        }
    }

    private var scopeLabel: String {
        switch layer.scope {
        case .global:  return "User (global)"
        case .project: return "Project"
        // Both settings.local.json files report .local; disambiguate by where the file lives.
        case .local:   return isUnderGlobalClaude ? "Local (user)" : "Local (project)"
        default:       return layer.scope.rawValue
        }
    }

    private var isUnderGlobalClaude: Bool {
        layer.source.standardizedFileURL.path
            .hasPrefix(Paths.globalClaude.standardizedFileURL.path + "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeLabel)
                        .font(.subheadline).bold()
                        .foregroundStyle(scopeColor)
                    Text(layer.source.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                OpenInEditorButton(url: layer.source)

                Button { showingJsonEditor = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces").font(.system(size: 11))
                        Text("JSON").font(.caption).fontWeight(.medium)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(scopeColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(scopeColor.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(scopeColor.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 1) {
                let sortedKeys = layer.raw.keys.sorted().filter {
                    filterQuery.isEmpty || nodeMatches(layer.raw[$0]!, key: $0, query: filterQuery)
                }
                if sortedKeys.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                } else {
                    ForEach(sortedKeys, id: \.self) { key in
                        let isOverridden = overriddenKeyPaths.contains("\(layerIndex)/\(key)")
                        let overridingScope = overridingLayerScope(for: key)
                        SettingsTreeNode(
                            key: key,
                            value: layer.raw[key]!,
                            keyPath: [key],
                            sourceURL: layer.source,
                            isOverridden: isOverridden,
                            overridingScope: overridingScope,
                            depth: 0,
                            app: app,
                            expandOverride: expandOverride,
                            filterQuery: filterQuery
                        )
                    }
                }
            }
            .padding(8)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .sheet(isPresented: $showingJsonEditor) {
            JsonEditorSheet(url: layer.source, scopeLabel: scopeLabel, scopeColor: scopeColor, app: app)
        }
    }

    private func overridingLayerScope(for key: String) -> Scope? {
        let layers = app.store.settingsLayers
        for higherIdx in (layerIndex + 1)..<layers.count {
            if layers[higherIdx].raw[key] != nil { return layers[higherIdx].scope }
        }
        return nil
    }
}

// MARK: - Recursive tree node

struct SettingsTreeNode: View {
    let key: String
    let value: Any
    let keyPath: [String]
    let sourceURL: URL
    let isOverridden: Bool
    let overridingScope: Scope?
    let depth: Int
    @ObservedObject var app: AppState
    var provenanceScope: Scope? = nil
    var childProvenance: [String: Scope]? = nil
    var expandOverride: Bool? = nil
    var filterQuery: String = ""

    @State private var expanded: Bool
    @State private var editing = false
    @State private var editBuffer = ""
    @State private var isHovered = false

    init(key: String, value: Any, keyPath: [String], sourceURL: URL, isOverridden: Bool, overridingScope: Scope?, depth: Int, app: AppState, provenanceScope: Scope? = nil, childProvenance: [String: Scope]? = nil, expandOverride: Bool? = nil, filterQuery: String = "") {
        self.key = key
        self.value = value
        self.keyPath = keyPath
        self.sourceURL = sourceURL
        self.isOverridden = isOverridden
        self.overridingScope = overridingScope
        self.depth = depth
        self.app = app
        self.provenanceScope = provenanceScope
        self.childProvenance = childProvenance
        self.expandOverride = expandOverride
        self.filterQuery = filterQuery
        let isContainer = value is [String: Any] || value is [Any]
        _expanded = State(initialValue: depth == 0 && isContainer)
    }

    private var valueKind: ValueKind {
        if value is [String: Any] { return .object }
        if value is [Any] { return .array }
        return .leaf
    }

    /// Which managed config owns this node, if any — the two detections mirror how the installers
    /// write. Top-level keys are claimed by key *and* layer, so only the active project's
    /// settings.json is marked, never the global layer or another project's. Everything below is
    /// claimed by value: the command names one of our scripts, whatever home it points at.
    ///
    /// The `hooks` key itself and each per-event array are deliberately never claimed — they are
    /// shared containers that hold foreign hooks too. Ownership starts at the hook *entry*
    /// (`hooks.<Event>.<n>`, depth 2); the containers between that entry and its `command` leaf are
    /// left unbadged so one hook reads as two markers, not four stacked down the indent guide.
    private var managedOwner: ManagedConfig? {
        if depth == 0 {
            guard let base = app.activePath else { return nil }
            return ManagedArtifacts.owner(ofSettingsKey: key, sourceURL: sourceURL, base: base)
        }
        if let s = value as? String { return ManagedArtifacts.owner(ofHookCommand: s) }
        guard keyPath.first == "hooks", depth == 2 else { return nil }
        return managedCommandOwner(value)
    }

    var body: some View {
        let showChildren = filterQuery.isEmpty
            ? expanded
            : (valueKind != .leaf && nodeMatches(value, key: key, query: filterQuery))
        VStack(alignment: .leading, spacing: 0) {
            rowContent
            if showChildren {
                childrenContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: expandOverride) { _, override in
            guard let override, valueKind != .leaf else { return }
            withAnimation(.easeInOut(duration: 0.18)) { expanded = override }
        }
    }

    // MARK: Row

    @ViewBuilder
    private var rowContent: some View {
        let owner = managedOwner
        HStack(spacing: 0) {
            // Indentation
            if depth > 0 {
                indentGuide
            }

            HStack(spacing: 8) {
                // Expand chevron or dot
                if valueKind != .leaf {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(expanded ? Color.accentColor : .secondary)
                        .frame(width: 14)
                } else {
                    Circle()
                        .fill(isOverridden ? Color.secondary.opacity(0.35) : Color.accentColor.opacity(0.45))
                        .frame(width: 6, height: 6)
                        .frame(width: 14)
                }

                // Key
                Text(key)
                    .font(depth == 0 ? .body.monospaced() : .callout.monospaced())
                    .fontWeight(depth == 0 ? .semibold : .regular)
                    .foregroundStyle(isOverridden ? .secondary : .primary)
                    .strikethrough(isOverridden, color: .secondary)

                // Value summary / edit field
                if editing {
                    HStack(spacing: 6) {
                        TextField("", text: $editBuffer)
                            .textFieldStyle(.plain)
                            .font(.callout.monospaced())
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: .infinity)
                            .onSubmit { commitEdit() }
                        Button { commitEdit() } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        Button { editing = false } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    switch valueKind {
                    case .object:
                        let dict = value as! [String: Any]
                        Text("{\(dict.count) \(dict.count == 1 ? "key" : "keys")}")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    case .array:
                        let arr = value as! [Any]
                        Text("[\(arr.count) \(arr.count == 1 ? "item" : "items")]")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    case .leaf:
                        let valueMatchesQuery = !filterQuery.isEmpty && !isOverridden
                            && leafDisplayValue.localizedCaseInsensitiveContains(filterQuery)
                        Text(leafDisplayValue)
                            .font(.callout.monospaced())
                            .foregroundStyle(valueMatchesQuery ? AnyShapeStyle(.tint) : AnyShapeStyle(isOverridden ? .tertiary : .secondary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                // Edit pencil on hover (leaves only) — before badges.
                // Managed nodes are read-only here: an edit would be overwritten on next launch.
                if valueKind == .leaf && !isOverridden && !editing && isHovered && owner == nil {
                    Button {
                        editBuffer = leafRawValue
                        editing = true
                    } label: {
                        Image(systemName: Icon.edit)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                // Badges
                if let owner, !editing {
                    ManagedBadge(owner: owner, app: app)
                }
                if let overridingScope, !editing {
                    overriddenBadge(by: overridingScope)
                }
                if isFromOverride && !editing {
                    overridesBadge
                }
                if let provenanceScope, !editing {
                    ProvenanceBadge(scope: provenanceScope, origin: .user)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered && !isOverridden ? Color.white.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
            .textSelection(.disabled) // click-to-edit rows: keep tap gesture clean
            .onHover { isHovered = $0 }
            .onTapGesture {
                if valueKind != .leaf {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } else if let owner {
                    // Not editable here — send the user to where the edit actually sticks, so the
                    // row stays live rather than swallowing the click.
                    app.focusManagedConfigID = owner.id
                    app.selected = .appConfig
                } else if !isOverridden && !editing {
                    editBuffer = leafRawValue
                    withAnimation { editing = true }
                }
            }
            // Empty string = no tooltip, so only managed rows explain themselves.
            .help(owner == nil ? "" : "Installed by Claudepit — edits here are overwritten. Click to manage.")
        }
    }

    // MARK: Children

    @ViewBuilder
    private var childrenContent: some View {
        switch valueKind {
        case .object:
            let dict = value as! [String: Any]
            VStack(alignment: .leading, spacing: 0) {
                let visibleKeys = dict.keys.sorted().filter {
                    filterQuery.isEmpty || nodeMatches(dict[$0]!, key: $0, query: filterQuery)
                }
                ForEach(visibleKeys, id: \.self) { childKey in
                    SettingsTreeNode(
                        key: childKey,
                        value: dict[childKey]!,
                        keyPath: keyPath + [childKey],
                        sourceURL: sourceURL,
                        isOverridden: false,
                        overridingScope: nil,
                        depth: depth + 1,
                        app: app,
                        provenanceScope: childProvenance?[childKey],
                        expandOverride: expandOverride,
                        filterQuery: filterQuery
                    )
                }
            }
        case .array:
            let arr = value as! [Any]
            VStack(alignment: .leading, spacing: 0) {
                let visibleItems = Array(arr.enumerated()).filter {
                    filterQuery.isEmpty || nodeMatches($0.element, key: "\($0.offset)", query: filterQuery)
                }
                ForEach(visibleItems, id: \.offset) { idx, item in
                    SettingsTreeNode(
                        key: "\(idx)",
                        value: item,
                        keyPath: keyPath + ["\(idx)"],
                        sourceURL: sourceURL,
                        isOverridden: false,
                        overridingScope: nil,
                        depth: depth + 1,
                        app: app,
                        expandOverride: expandOverride,
                        filterQuery: filterQuery
                    )
                }
            }
        case .leaf:
            EmptyView()
        }
    }

    // MARK: Indent guide

    private var indentGuide: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 1)
                    .padding(.leading, 20)
            }
        }
    }

    // MARK: Helpers

    private var leafRawValue: String {
        if let s = value as? String { return s }
        if let b = value as? Bool { return b ? "true" : "false" }
        return "\(value)"
    }

    private var leafDisplayValue: String {
        let k = keyPath.last ?? ""
        let upper = k.uppercased()
        let secret = ["TOKEN", "KEY", "SECRET", "PASSWORD"].contains { upper.contains($0) }
        let raw = leafRawValue
        if secret, raw.count > 4 { return "••••" + raw.suffix(4) }
        return raw
    }

    private var isFromOverride: Bool {
        guard let topKey = keyPath.first else { return false }
        guard !mergeKeys.contains(topKey) else { return false }
        let layers = app.store.settingsLayers
        guard let myIdx = layers.firstIndex(where: { $0.source == sourceURL }) else { return false }
        for lowerIdx in 0..<myIdx where layers[lowerIdx].raw[topKey] != nil { return true }
        return false
    }

    private func overriddenBadge(by scope: Scope) -> some View {
        let label: String
        switch scope {
        case .project: label = "overridden by project"
        case .local:   label = "overridden by local"
        default:       label = "overridden"
        }
        return Text(label)
            .font(.caption).bold()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }

    private var overridesBadge: some View {
        Text("overrides")
            .font(.caption).bold()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.green.opacity(0.15), in: Capsule())
            .foregroundStyle(.green)
    }

    private func commitEdit() {
        editing = false
        let newValue: Any
        if editBuffer == "true"       { newValue = true }
        else if editBuffer == "false" { newValue = false }
        else if let n = Int(editBuffer)    { newValue = n }
        else if let d = Double(editBuffer) { newValue = d }
        else                          { newValue = editBuffer }
        try? WriteOps.setValueAtKeyPath(keyPath, value: newValue, in: sourceURL,
                                        epoch: Int(Date().timeIntervalSince1970))
        app.store.reload(activePath: app.activePath)
    }

    private enum ValueKind { case object, array, leaf }
}

// MARK: - Unified (effective) view

private struct UnifiedSettingsTree: View {
    @ObservedObject var app: AppState
    let layers: [ConfigStore.SettingsLayer]
    var expandOverride: Bool? = nil
    var filterQuery: String = ""

    /// Merged dict: last layer wins per key, except mergeKeys which deep-merge their children.
    private var merged: [(key: String, value: Any, scope: Scope, source: URL, childProvenance: [String: Scope]?)] {
        var mergedDict: [String: Any] = [:]
        var winningScope: [String: Scope] = [:]
        var winningSource: [String: URL] = [:]
        var childProvenanceMap: [String: [String: Scope]] = [:]
        for layer in layers {
            for (key, val) in layer.raw {
                if mergeKeys.contains(key),
                   let existing = mergedDict[key] as? [String: Any],
                   let incoming = val as? [String: Any] {
                    mergedDict[key] = existing.merging(incoming) { _, new in new }
                    winningScope[key] = layer.scope
                    winningSource[key] = layer.source
                    // Track per-child provenance: last layer that provided each child key wins
                    var cp = childProvenanceMap[key] ?? [:]
                    for childKey in incoming.keys { cp[childKey] = layer.scope }
                    childProvenanceMap[key] = cp
                } else {
                    mergedDict[key] = val
                    winningScope[key] = layer.scope
                    winningSource[key] = layer.source
                    // First time seeing a merge key — seed child provenance from this layer
                    if mergeKeys.contains(key), let dict = val as? [String: Any] {
                        childProvenanceMap[key] = dict.keys.reduce(into: [:]) { $0[$1] = layer.scope }
                    }
                }
            }
        }
        return mergedDict.keys.sorted().compactMap { key in
            guard let val = mergedDict[key],
                  let scope = winningScope[key],
                  let source = winningSource[key] else { return nil }
            return (key: key, value: val, scope: scope, source: source, childProvenance: childProvenanceMap[key])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Effective settings")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("— merged result, highest-precedence layer wins (hooks: additive)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                if merged.isEmpty {
                    Text("No settings found").foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                } else {
                    ForEach(merged.filter { filterQuery.isEmpty || nodeMatches($0.value, key: $0.key, query: filterQuery) }, id: \.key) { entry in
                        SettingsTreeNode(
                            key: entry.key,
                            value: entry.value,
                            keyPath: [entry.key],
                            sourceURL: entry.source,
                            isOverridden: false,
                            overridingScope: nil,
                            depth: 0,
                            app: app,
                            provenanceScope: entry.scope,
                            childProvenance: entry.childProvenance,
                            expandOverride: expandOverride,
                            filterQuery: filterQuery
                        )
                    }
                }
            }
            .padding(8)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
    }
}

// MARK: - JSON editor sheet

private struct JsonEditorSheet: View {
    let url: URL
    let scopeLabel: String
    let scopeColor: Color
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var errorMessage: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeLabel)
                        .font(.subheadline).bold()
                        .foregroundStyle(scopeColor)
                    Text(url.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(text.components(separatedBy: "\n").count) lines")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.quaternary)
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(scopeColor)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider().opacity(0.2)

            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(.black.opacity(0.3))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(.ultraThinMaterial)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: pretty, encoding: .utf8) {
                text = str
            } else {
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }

    private func save() {
        errorMessage = nil
        guard let data = text.data(using: .utf8) else { return }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            _ = try JSONFile.backup(url, epoch: Int(Date().timeIntervalSince1970))
            try data.write(to: url, options: .atomic)
            app.store.reload(activePath: app.activePath)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

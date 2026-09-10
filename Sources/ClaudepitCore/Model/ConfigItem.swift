import Foundation

public enum Scope: String, CaseIterable, Hashable, Sendable {
    case global, project, local, plugin
}

public enum Origin: Equatable, Hashable, Sendable {
    case user
    case plugin(id: String)
    public var pluginID: String? { if case .plugin(let id) = self { return id }; return nil }
}

/// Common surface every visible config item exposes. Powers reused row/badge/open-in-editor.
public protocol ConfigItem: Identifiable {
    var displayName: String { get }
    var scope: Scope { get }
    var sourcePath: URL { get }
    var origin: Origin { get }
    var isOverridden: Bool { get }
}

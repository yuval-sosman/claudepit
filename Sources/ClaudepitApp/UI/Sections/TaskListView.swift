import SwiftUI
import ClaudepitCore

/// Dependency-tree list. Roots = tasks whose blockers are outside the filtered set.
/// Children nest under their first rendered blocker (deduped); tasks unreachable from
/// any root (pure cycles) fall back to flat roots so nothing is silently dropped.
struct TaskListView: View {
    let tasks: [ProjectTask]
    @Binding var selection: String?
    @ObservedObject var app: AppState
    var sort: TasksSection.Sort = .priority

    private struct Node: Identifiable { let task: ProjectTask; let children: [Node]; var id: String { task.id } }

    private func sorted(_ ts: [ProjectTask]) -> [ProjectTask] {
        ts.sorted { a, b in orderedBefore(a, b, sort: sort, app: app) }
    }
    private func children(of id: String) -> [ProjectTask] {
        tasks.filter { $0.id != id && $0.dependsOn.contains(id) }
    }

    /// Build the forest once: first-seen-wins dedup, pure-cycle orphans appended flat.
    private var forest: [Node] {
        let byID = Set(tasks.map { $0.id })
        var placed = Set<String>()
        func build(_ t: ProjectTask) -> Node? {
            guard placed.insert(t.id).inserted else { return nil }
            let kids = sorted(children(of: t.id)).compactMap { build($0) }
            return Node(task: t, children: kids)
        }
        let acyclic = sorted(tasks.filter { t in !t.dependsOn.contains { byID.contains($0) } })
        var roots = acyclic.compactMap { build($0) }
        roots += sorted(tasks.filter { !placed.contains($0.id) }).compactMap { build($0) }
        return roots
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(forest) { node($0) }
            }
            .padding(.vertical, 8)
        }
    }

    // ponytail: AnyView breaks the recursive opaque-type self-reference; tree depth is tiny.
    private func node(_ n: Node) -> AnyView {
        if n.children.isEmpty {
            return AnyView(row(n.task))
        }
        return AnyView(DisclosureGroup(isExpanded: .constant(true)) {
            ForEach(n.children) { node($0) }.padding(.leading, 16)
        } label: {
            row(n.task)
        })
    }

    private func row(_ task: ProjectTask) -> some View {
        Button { selection = task.id } label: {
            TaskCardView(task: task, app: app)
        }
        .buttonStyle(.plain)
        .selectableRowBackground(isSelected: selection == task.id)
    }
}

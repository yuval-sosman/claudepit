import SwiftUI
import ClaudepitCore

struct PlansSection: View {
    @ObservedObject var app: AppState
    @State private var plans: [PlanFile] = []
    @State private var selectedPlan: PlanFile?
    @State private var timeFilter: TimeFilter = .all
    @State private var showTimeFilter: Bool = false
    private var plansDir: URL {
        Paths.plansRoot
    }

    private var filteredPlans: [PlanFile] {
        plans.filter { timeFilter.includes($0.modifiedAt) }
    }

    var body: some View {
        MasterDetailLayout(listWidth: 300) {
            listCard
        } detail: {
            detailCard
        }
        .onAppear {
            reload()
            applyFocusPlanPath()
            if selectedPlan == nil { selectedPlan = plans.first }
        }
        .onChange(of: app.focusPlanPath) { applyFocusPlanPath() }
        .onChange(of: app.plansChangeToken) { reload() }
        .onChange(of: selectedPlan) { _, plan in app.selectedPlanName = plan?.name }
    }

    // MARK: List card

    private var listCard: some View {
        GlassCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Plans").font(.headline)
                    Spacer()
                    Button { showTimeFilter = true } label: {
                        Image(systemName: timeFilter.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(timeFilter.isActive ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by date")
                    .popover(isPresented: $showTimeFilter, arrowEdge: .bottom) {
                        TimeFilterPopover(filter: $timeFilter)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                if timeFilter.isActive {
                    HStack(spacing: 4) {
                        Text(timeFilter.label)
                        Button { timeFilter = .all } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }

                Divider().opacity(0.15)
                if filteredPlans.isEmpty {
                    EmptyState("No plans found.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredPlans) { plan in
                                planRow(plan)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func planRow(_ plan: PlanFile) -> some View {
        HStack(spacing: 0) {
            Button { selectedPlan = plan } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name)
                        .font(.body)
                        .lineLimit(1)
                    Text(plan.modifiedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Menu {
                fileContextMenu(url: plan.path)
                Divider()
                Button(role: .destructive) {
                    try? FileManager.default.trashItem(at: plan.path, resultingItemURL: nil)
                    if selectedPlan?.path == plan.path { selectedPlan = nil }
                    reload()
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 8)
        }
        .selectableRowBackground(isSelected: selectedPlan == plan)
    }

    // MARK: Detail card

    private var detailCard: some View {
        Group {
            if let plan = selectedPlan {
                PlanDetailView(plan: plan, app: app) { app.plansChangeToken += 1 }
            } else {
                GlassCard {
                    EmptyState("Select a plan")
                }
            }
        }
    }

    // MARK: Data

    private func applyFocusPlanPath() {
        guard let path = app.focusPlanPath else { return }
        reload()
        selectedPlan = plans.first { $0.path.path == path }
        app.focusPlanPath = nil
    }

    private func reload() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: plansDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            plans = []
            return
        }
        plans = items
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> PlanFile? in
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let modified = attrs?.contentModificationDate ?? Date.distantPast
                let name = url.deletingPathExtension().lastPathComponent
                return PlanFile(name: name, path: url, modifiedAt: modified)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

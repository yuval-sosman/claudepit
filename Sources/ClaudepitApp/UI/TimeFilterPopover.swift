import SwiftUI

struct TimeFilterPopover: View {
    @Binding var filter: TimeFilter
    @Environment(\.dismiss) private var dismiss

    // pending selection — only committed to filter on Apply
    @State private var pending: TimeFilter = .all
    @State private var customFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var customTo: Date = Date()

    private var pendingIsCustom: Bool {
        if case .custom = pending { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter by date modified")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                presetChip(nil, label: "All")
                ForEach(TimePreset.allCases, id: \.self) { p in
                    presetChip(p, label: p.label)
                }
            }

            Divider().opacity(0.2)

            Text("Custom range")
                .font(.caption)
                .foregroundStyle(pendingIsCustom ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("From")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                    DatePicker("", selection: $customFrom, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .onChange(of: customFrom) { _, _ in
                            let from = min(customFrom, customTo)
                            let to   = max(customFrom, customTo)
                            pending = .custom(from: from, to: to)
                        }
                }
                HStack(spacing: 8) {
                    Text("To")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                    DatePicker("", selection: $customTo, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .onChange(of: customTo) { _, _ in
                            let from = min(customFrom, customTo)
                            let to   = max(customFrom, customTo)
                            pending = .custom(from: from, to: to)
                        }
                }
            }

            Divider().opacity(0.2)

            HStack {
                Spacer()
                Button("Apply") {
                    filter = pending
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(pending == filter)
            }
        }
        .padding(14)
        .frame(width: 240)
        .onAppear {
            pending = filter
            if case .custom(let from, let to) = filter {
                customFrom = from
                customTo = to
            }
        }
    }

    private func presetChip(_ preset: TimePreset?, label: String) -> some View {
        let isSelected: Bool = {
            if let p = preset { return pending == .preset(p) }
            return pending == .all
        }()
        return Button {
            if let p = preset {
                pending = .preset(p)
            } else {
                pending = .all
            }
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isSelected ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

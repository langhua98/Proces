import SwiftUI

struct ImportReviewView: View {
    @ObservedObject var session: ImportSession
    let projectID: UUID

    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?

    private var project: Project? { store.project(projectID) }

    private var duplicateNumbers: Set<Int> {
        var counts: [Int: Int] = [:]
        for c in session.candidates { if let n = c.assignedNumber { counts[n, default: 0] += 1 } }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private var missingNumbers: [Int] {
        guard let project else { return [] }
        let assigned = Set(session.candidates.compactMap(\.assignedNumber))
        return project.frames.filter { !$0.optimized && !assigned.contains($0.number) }.map(\.number)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("结果") {
                    let recognized = session.candidates.filter { $0.detectedNumber != nil }.count
                    LabeledContent("自动识别成功", value: "\(recognized) 张")
                    let unassigned = session.candidates.filter { $0.assignedNumber == nil }.count
                    if unassigned > 0 {
                        Text("\(unassigned) 张没有编号，请手动填写，不填的会被忽略").foregroundStyle(.orange)
                    }
                    if !duplicateNumbers.isEmpty {
                        Text("编号重复：\(duplicateNumbers.sorted().map { LabelRenderer.text(for: $0) }.joined(separator: "、"))，后面的会覆盖前面的")
                            .foregroundStyle(.orange)
                    }
                    if !missingNumbers.isEmpty {
                        Text("导入后仍缺 \(missingNumbers.count) 张：\(summary(missingNumbers))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("照片") {
                    ForEach($session.candidates) { $c in
                        HStack(spacing: 12) {
                            if let t = c.thumbnail {
                                Image(uiImage: t).resizable().scaledToFit().frame(width: 90, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.method).font(.caption)
                                    .foregroundStyle(c.detectedNumber == nil ? Color.orange : Color.secondary)
                                if let w = c.warning {
                                    Text(w).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            TextField("编号", value: $c.assignedNumber, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .padding(6)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(c.assignedNumber.map { duplicateNumbers.contains($0) } == true ? Color.orange : Color.primary)
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("确认导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if let project { FrameImporter.discard(project) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { apply() }
                }
            }
        }
    }

    private func summary(_ numbers: [Int]) -> String {
        let shown = numbers.prefix(12).map { LabelRenderer.text(for: $0) }.joined(separator: "、")
        return numbers.count > 12 ? shown + "…" : shown
    }

    private func apply() {
        guard var project else { return }
        let valid = session.candidates.filter { c in
            guard let n = c.assignedNumber else { return false }
            return project.frames.contains { $0.number == n }
        }
        do {
            _ = try FrameImporter.apply(valid, to: &project)
            store.save(project)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

import SwiftUI
import UIKit

struct ComposeView: View {
    let projectID: UUID

    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var options = ComposeOptions()
    @State private var running = false
    @State private var progress: Double = 0
    @State private var status = ""
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var initialized = false

    private var project: Project? { store.project(projectID) }

    private var fpsChoices: [Double] {
        var list: [Double] = [24, 30, 60]
        if let p = project {
            let original = (p.nominalFPS * 100).rounded() / 100
            if !list.contains(original) { list.append(original) }
        }
        return list.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                if let project {
                    Section {
                        LabeledContent("已优化照片", value: "\(project.optimizedCount)/\(project.frames.count)")
                        if project.optimizedCount < project.frames.count {
                            Toggle("缺少的照片用原图代替", isOn: $options.useOriginalForMissing)
                            Text(options.useOriginalForMissing
                                 ? "原图和 GPT 照片风格不同，视频里可能会跳一下"
                                 : "缺少的照片会跳过，由前后的照片补上")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("画面") {
                        Picker("帧率", selection: $options.fps) {
                            ForEach(fpsChoices, id: \.self) { Text(String(format: "%g fps", $0)).tag($0) }
                        }
                        Picker("补帧", selection: $options.interpolation) {
                            ForEach(InterpolationMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("颜色平滑（减少闪烁）", isOn: $options.colorSmoothing)
                        Picker("尺寸", selection: $options.sizeMode) {
                            ForEach(OutputSizeMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("编码", selection: $options.codec) {
                            ForEach(OutputCodec.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Section("声音") {
                        Toggle("保留原视频声音", isOn: $options.keepAudio)
                            .disabled(!project.hasAudio)
                        if !project.hasAudio {
                            Text("原视频没有声音").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if running {
                        Section {
                            ProgressView(value: progress) { Text(status).font(.footnote) }
                        }
                    }
                    if let errorText {
                        Section { Text(errorText).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("合成视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始合成") { start() }.disabled(running)
                }
            }
            .interactiveDismissDisabled(running)
            .onAppear {
                guard !initialized, let p = project else { return }
                initialized = true
                let original = (p.nominalFPS * 100).rounded() / 100
                options.fps = original > 0 ? original : 30
                options.keepAudio = p.hasAudio
            }
        }
    }

    private func start() {
        guard let project else { return }
        running = true
        errorText = nil
        progress = 0
        let opts = options
        task = Task { @MainActor in
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await VideoComposer().compose(project: project, options: opts) { p, s in
                        Task { @MainActor in
                            progress = p
                            status = s
                        }
                    }
                }.value
                var updated = store.project(projectID) ?? project
                updated.hasOutput = true
                updated.revision += 1
                store.save(updated)
                running = false
                dismiss()
            } catch {
                running = false
                if !(error is CancellationError) {
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

struct FrameDetailView: View {
    let project: Project
    let frame: FrameItem

    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("导出的照片").tag(0)
                    Text("GPT 优化后").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                Spacer(minLength: 0)
                if tab == 1 && !frame.optimized {
                    ContentUnavailableView("还没有导入", systemImage: "photo")
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
                Spacer(minLength: 0)
                Text("时间 \(String(format: "%.2f", frame.time)) 秒 · 原视频第 \(frame.sourceIndex + 1) 帧")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical)
            .navigationTitle("第 \(LabelRenderer.text(for: frame.number)) 张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task(id: tab) {
                image = nil
                let url = tab == 0 ? ProjectPaths.export(project.id, frame.number) : ProjectPaths.optimized(project.id, frame.number)
                image = await ThumbnailCache.shared.image(for: url, maxPixel: 2400)
            }
        }
    }
}

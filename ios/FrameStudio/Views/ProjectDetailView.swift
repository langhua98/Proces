import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ProjectDetailView: View {
    let projectID: UUID

    @EnvironmentObject private var store: ProjectStore
    @AppStorage("promptTemplate") private var prompt = PromptDefaults.text
    @State private var busy: String?
    @State private var message: String?
    @State private var shareItems: ShareItems?
    @State private var importItems: [PhotosPickerItem] = []
    @State private var showFileImport = false
    @State private var importSession: ImportSession?
    @State private var showCompose = false
    @State private var showPromptEditor = false
    @State private var selectedFrame: FrameItem?

    var body: some View {
        if let project = store.project(projectID) {
            content(project)
        } else {
            ContentUnavailableView("项目不存在", systemImage: "questionmark.folder")
        }
    }

    private func content(_ project: Project) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(project.videoWidth)×\(project.videoHeight) · \(String(format: "%.0f", project.nominalFPS)) fps · \(formatSeconds(project.duration)) · \(project.samplingDescription)")
                    .font(.footnote).foregroundStyle(.secondary)

                StepCard(title: "① 导出照片交给 GPT", systemImage: "square.and.arrow.up") {
                    Text("共 \(project.frames.count) 张，编号在每张照片底部黑边的右下角。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            saveToAlbum(project)
                        } label: {
                            Label("存到相册", systemImage: "photo.stack")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            shareImages(project)
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            shareZip(project)
                        } label: {
                            Label("ZIP", systemImage: "doc.zipper")
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack {
                        Button {
                            UIPasteboard.general.string = prompt
                            message = "提示词已复制，粘贴到 ChatGPT 里和照片一起发送"
                        } label: {
                            Label("复制提示词", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        Button("编辑提示词") { showPromptEditor = true }
                            .font(.footnote)
                    }
                }

                StepCard(title: "② 导入 GPT 优化后的照片", systemImage: "square.and.arrow.down") {
                    Text("已导入 \(project.optimizedCount)/\(project.frames.count) 张。会自动识别编号、裁掉黑边。可以分多次导入。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        PhotosPicker(selection: $importItems, maxSelectionCount: nil, matching: .images) {
                            Label("从相册导入", systemImage: "photo.on.rectangle.angled")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            showFileImport = true
                        } label: {
                            Label("从文件导入", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                StepCard(title: "③ 合成视频", systemImage: "film") {
                    Button {
                        showCompose = true
                    } label: {
                        Label("合成视频", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(project.optimizedCount == 0)
                    if project.hasOutput {
                        OutputPlayer(url: ProjectPaths.output(project.id), token: project.revision)
                            .aspectRatio(CGFloat(project.videoWidth) / CGFloat(max(project.videoHeight, 1)), contentMode: .fit)
                            .frame(maxHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        HStack {
                            Button {
                                saveVideo(project)
                            } label: {
                                Label("保存到相册", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                shareItems = ShareItems(urls: [ProjectPaths.output(project.id)])
                            } label: {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Text("照片").font(.headline).padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(project.frames) { f in
                        FrameCell(project: project, frame: f)
                            .onTapGesture { selectedFrame = f }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItems) { ActivityView(items: $0.urls) }
        .sheet(item: $importSession) { session in
            ImportReviewView(session: session, projectID: projectID)
        }
        .sheet(isPresented: $showCompose) { ComposeView(projectID: projectID) }
        .sheet(item: $selectedFrame) { f in FrameDetailView(project: project, frame: f) }
        .sheet(isPresented: $showPromptEditor) { PromptEditor(prompt: $prompt) }
        .onChange(of: importItems) { _, items in
            guard !items.isEmpty else { return }
            importItems = []
            importFromPhotos(items, project)
        }
        .fileImporter(isPresented: $showFileImport, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFromFiles(urls, project)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .overlay {
            if let busy { BusyOverlay(text: busy) }
        }
        .errorAlert($message)
    }

    // MARK: - 导出

    private func exportURLs(_ project: Project) -> [URL] {
        project.frames.map { ProjectPaths.export(project.id, $0.number) }
    }

    private func saveToAlbum(_ project: Project) {
        busy = "正在存到相册…"
        let urls = exportURLs(project)
        Task { @MainActor in
            defer { busy = nil }
            do {
                try await PhotoLibrary.saveImages(urls, album: "帧工坊 · \(project.name)")
                message = "已存到相册「帧工坊 · \(project.name)」，共 \(urls.count) 张"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func shareImages(_ project: Project) {
        shareItems = ShareItems(urls: exportURLs(project))
    }

    private func shareZip(_ project: Project) {
        busy = "正在打包…"
        let dir = ProjectPaths.exports(project.id)
        let name = "\(project.name)-照片"
        Task { @MainActor in
            defer { busy = nil }
            do {
                let url = try await Task.detached { try Zipper.zip(directory: dir, name: name) }.value
                shareItems = ShareItems(urls: [url])
            } catch {
                message = "打包失败：\(error.localizedDescription)"
            }
        }
    }

    private func saveVideo(_ project: Project) {
        busy = "正在保存…"
        Task { @MainActor in
            defer { busy = nil }
            do {
                try await PhotoLibrary.saveVideo(ProjectPaths.output(project.id))
                message = "视频已保存到相册"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: - 导入

    private func importFromPhotos(_ items: [PhotosPickerItem], _ project: Project) {
        busy = "正在识别编号…"
        Task { @MainActor in
            let importer = FrameImporter(project: project)
            var candidates: [ImportCandidate] = []
            do {
                try importer.prepareTempDir()
                for (i, item) in items.enumerated() {
                    busy = "正在识别编号 \(i + 1)/\(items.count)…"
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    if let c = try? await Task.detached(priority: .userInitiated, operation: {
                        try importer.process(data: data, name: nil)
                    }).value {
                        candidates.append(c)
                    }
                }
            } catch {
                message = error.localizedDescription
            }
            busy = nil
            finishImport(candidates, total: items.count)
        }
    }

    private func importFromFiles(_ urls: [URL], _ project: Project) {
        busy = "正在识别编号…"
        Task { @MainActor in
            let importer = FrameImporter(project: project)
            var candidates: [ImportCandidate] = []
            do {
                try importer.prepareTempDir()
                for (i, url) in urls.enumerated() {
                    busy = "正在识别编号 \(i + 1)/\(urls.count)…"
                    let access = url.startAccessingSecurityScopedResource()
                    let data = try? Data(contentsOf: url)
                    if access { url.stopAccessingSecurityScopedResource() }
                    guard let data else { continue }
                    let name = url.lastPathComponent
                    if let c = try? await Task.detached(priority: .userInitiated, operation: {
                        try importer.process(data: data, name: name)
                    }).value {
                        candidates.append(c)
                    }
                }
            } catch {
                message = error.localizedDescription
            }
            busy = nil
            finishImport(candidates, total: urls.count)
        }
    }

    private func finishImport(_ candidates: [ImportCandidate], total: Int) {
        if candidates.isEmpty {
            message = "没有成功读取任何照片"
            return
        }
        let sorted = candidates.sorted { ($0.assignedNumber ?? Int.max) < ($1.assignedNumber ?? Int.max) }
        importSession = ImportSession(candidates: sorted)
        if candidates.count < total {
            message = "有 \(total - candidates.count) 张照片读取失败，已跳过"
        }
    }
}

private struct FrameCell: View {
    let project: Project
    let frame: FrameItem

    var body: some View {
        let url = frame.optimized ? ProjectPaths.optimized(project.id, frame.number) : ProjectPaths.export(project.id, frame.number)
        ThumbnailView(url: url, maxPixel: 300, token: project.revision)
            .frame(maxWidth: .infinity)
            .aspectRatio(CGFloat(project.videoWidth) / CGFloat(max(project.videoHeight, 1)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    if frame.optimized {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(LabelRenderer.text(for: frame.number)).monospacedDigit()
                }
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(4)
            }
    }
}

private struct PromptEditor: View {
    @Binding var prompt: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $prompt).frame(minHeight: 220)
                } footer: {
                    Text("每张照片都用同一段提示词，GPT 生成的效果会更一致，视频更不容易闪烁。")
                }
                Section {
                    Button("恢复默认") { prompt = PromptDefaults.text }
                }
            }
            .navigationTitle("提示词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

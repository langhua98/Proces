import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ProjectListView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var pending: PendingVideo?
    @State private var loading = false
    @State private var message: String?
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView {
                        Label("还没有项目", systemImage: "film.stack")
                    } description: {
                        Text("点右上角 ＋ 选择一个视频（最长 15 秒）\n拆成照片 → 交给 GPT 优化 → 导入后合成视频")
                    }
                } else {
                    List {
                        ForEach(store.projects) { p in
                            NavigationLink(value: p.id) { ProjectRow(project: p) }
                        }
                        .onDelete { offsets in
                            let items = offsets.map { store.projects[$0] }
                            items.forEach { store.delete($0) }
                        }
                    }
                }
            }
            .navigationTitle("帧工坊")
            .navigationDestination(for: UUID.self) { id in
                ProjectDetailView(projectID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        PhotosPicker(selection: $pickerItem, matching: .videos) {
                            Label("从相册选择视频", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("从文件选择视频", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                pickerItem = nil
                loadVideo(item)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie]) { result in
                switch result {
                case .success(let url):
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        pending = PendingVideo(url: dest)
                    } catch {
                        message = "读取视频失败：\(error.localizedDescription)"
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .sheet(item: $pending) { p in
                NewProjectView(videoURL: p.url) { id in
                    path.append(id)
                }
            }
            .overlay {
                if loading { BusyOverlay(text: "正在读取视频…") }
            }
            .errorAlert($message)
        }
    }

    private func loadVideo(_ item: PhotosPickerItem) {
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    message = "无法读取这个视频"
                    return
                }
                pending = PendingVideo(url: movie.url)
            } catch {
                message = "读取视频失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: ProjectPaths.export(project.id, 1), maxPixel: 200)
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.headline)
                Text("\(project.frames.count) 张 · 已优化 \(project.optimizedCount) · \(formatSeconds(project.duration))")
                    .font(.caption).foregroundStyle(.secondary)
                if project.hasOutput {
                    Label("已合成视频", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

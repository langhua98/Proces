import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum Route: Hashable {
    case project(UUID)
    case newProject(URL)
}

struct ProjectListView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var loading = false
    @State private var message: String?
    @State private var path: [Route] = []

    @State private var showPhotoPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.projects.isEmpty {
                    VStack(spacing: 24) {
                        ContentUnavailableView {
                            Label("还没有项目", systemImage: "film.stack")
                        } description: {
                            Text("选择一个视频（最长 15 秒）\n拆成照片 → 交给 GPT 优化 → 导入后合成视频")
                        }
                        .frame(maxHeight: 260)
                        importButtons
                        Spacer()
                    }
                    .padding()
                } else {
                    List {
                        Section {
                            importButtons
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                        }
                        Section("项目") {
                            ForEach(store.projects) { p in
                                NavigationLink(value: Route.project(p.id)) { ProjectRow(project: p) }
                            }
                            .onDelete { offsets in
                                let items = offsets.map { store.projects[$0] }
                                items.forEach { store.delete($0) }
                            }
                        }
                    }
                }
            }
            // 文件选择器单独挂在内层视图上，避免和外层的 sheet 冲突导致弹不出来
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
            .navigationTitle("帧工坊")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .project(let id):
                    ProjectDetailView(projectID: id)
                case .newProject(let url):
                    // 用页面跳转代替弹窗：选择器刚关闭时弹窗经常被系统丢掉
                    NewProjectView(videoURL: url) { id in
                        path = [.project(id)]
                    }
                }
            }
            .overlay {
                if loading { BusyOverlay(text: "正在读取视频…") }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .videos,
                      preferredItemEncoding: .current)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            loadVideo(item)
        }
        .errorAlert($message)
    }

    private var importButtons: some View {
        HStack(spacing: 12) {
            Button {
                showPhotoPicker = true
            } label: {
                Label("从相册选视频", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                showFileImporter = true
            } label: {
                Label("从文件选视频", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private func openNewProject(_ url: URL) {
        // 等选择器完全关闭后再跳转
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            path.append(.newProject(url))
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                openNewProject(dest)
            } catch {
                message = "读取视频失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            message = error.localizedDescription
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
                openNewProject(movie.url)
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

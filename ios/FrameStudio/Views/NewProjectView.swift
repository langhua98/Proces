import SwiftUI

struct NewProjectView: View {
    let videoURL: URL
    var onCreated: (UUID) -> Void

    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    enum Rate: String, CaseIterable, Identifiable {
        case two = "每秒 2 张"
        case four = "每秒 4 张"
        case eight = "每秒 8 张"
        case all = "全部帧"
        var id: String { rawValue }
        var value: Double? {
            switch self {
            case .two: return 2
            case .four: return 4
            case .eight: return 8
            case .all: return nil
            }
        }
    }

    @State private var info: VideoInfo?
    @State private var name = ""
    @State private var rate: Rate = .four
    @State private var smart = true
    @State private var running = false
    @State private var progress: Double = 0
    @State private var status = ""
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    private var usedDuration: Double { min(info?.duration ?? 0, FrameExtractor.maxDuration) }

    private var estimated: Int {
        guard let info else { return 0 }
        let all = Int((usedDuration * info.fps).rounded())
        guard let v = rate.value else { return all }
        return min(max(2, Int((usedDuration * v).rounded())), all)
    }

    var body: some View {
            Form {
                Section("视频") {
                    if let info {
                        LabeledContent("时长", value: formatSeconds(info.duration))
                        LabeledContent("分辨率", value: "\(info.width)×\(info.height)")
                        LabeledContent("帧率", value: String(format: "%.2f fps", info.fps))
                        if info.duration > FrameExtractor.maxDuration + 0.05 {
                            Text("视频超过 15 秒，只处理前 15 秒").foregroundStyle(.orange)
                        }
                    } else {
                        ProgressView()
                    }
                }
                Section("项目名称") {
                    TextField(defaultName, text: $name)
                }
                Section {
                    Picker("抽帧频率", selection: $rate) {
                        ForEach(Rate.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("智能抽帧", isOn: $smart)
                        .disabled(rate == .all)
                    LabeledContent("要交给 GPT 的照片", value: "约 \(estimated) 张")
                } header: {
                    Text("抽帧")
                } footer: {
                    Text("智能抽帧：画面动得多的地方多抽、镜头切换处一定抽。合成时会自动用渐变补回中间的画面。")
                }
                Section {
                    if running {
                        ProgressView(value: progress) { Text(status).font(.footnote) }
                    } else {
                        Button {
                            start()
                        } label: {
                            Label("开始拆帧", systemImage: "scissors")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(info == nil)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("新建项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始拆帧") { start() }
                        .disabled(running || info == nil)
                }
            }
            .navigationBarBackButtonHidden(running)
            .onDisappear {
                if running { task?.cancel() }
            }
            .task {
                do {
                    info = try await VideoInfo.load(videoURL).0
                } catch {
                    errorText = error.localizedDescription
                }
            }
    }

    private var defaultName: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "项目 " + f.string(from: Date())
    }

    private func start() {
        running = true
        errorText = nil
        progress = 0
        let id = UUID()
        let options = SamplingOptions(perSecond: rate.value, smart: smart && rate != .all)
        let source = videoURL
        let projectName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
        task = Task { @MainActor in
            let dir = ProjectPaths.dir(id)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let videoName = "input." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension)
                let dest = dir.appendingPathComponent(videoName)
                try FileManager.default.copyItem(at: source, to: dest)

                let result = try await Task.detached(priority: .userInitiated) {
                    try await FrameExtractor().extract(videoURL: dest, projectID: id, options: options) { p, s in
                        Task { @MainActor in
                            progress = p
                            status = s
                        }
                    }
                }.value

                let project = Project(id: id, name: projectName, createdAt: Date(), videoFileName: videoName,
                                      videoWidth: result.width, videoHeight: result.height, nominalFPS: result.nominalFPS,
                                      duration: result.duration, totalSourceFrames: result.totalFrames,
                                      samplingDescription: options.description, layout: result.layout,
                                      frames: result.frames, hasAudio: result.hasAudio)
                store.save(project)
                try? FileManager.default.removeItem(at: source)
                running = false
                onCreated(id)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                running = false
                if !(error is CancellationError) {
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

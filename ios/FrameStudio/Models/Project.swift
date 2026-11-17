import Foundation
import CoreGraphics

/// 导出给 GPT 的画布布局。所有矩形都以左上角为原点，单位是画布像素。
struct CanvasLayout: Codable, Hashable {
    var canvasWidth: Int
    var canvasHeight: Int
    /// 原视频画面所在区域（只有这块参与合成）
    var contentRect: CGRect
    /// 画面下方放编号的黑边区域
    var stripRect: CGRect
}

struct FrameItem: Codable, Identifiable, Hashable {
    /// 照片编号，从 1 开始，画在黑边右下角
    var number: Int
    /// 在原视频中的帧序号（从 0 开始）
    var sourceIndex: Int
    /// 在原视频中的时间（秒，相对第一帧）
    var time: Double
    /// 是否已经导入 GPT 优化后的照片
    var optimized: Bool = false

    var id: Int { number }
}

struct Project: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var videoFileName: String
    var videoWidth: Int
    var videoHeight: Int
    var nominalFPS: Double
    var duration: Double
    var totalSourceFrames: Int
    var samplingDescription: String
    var layout: CanvasLayout
    var frames: [FrameItem]
    var hasAudio: Bool
    var hasOutput: Bool = false
    /// 每次导入 / 合成后加 1，用来刷新界面缩略图
    var revision: Int = 0

    var optimizedCount: Int { frames.filter(\.optimized).count }
}

enum ProjectPaths {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Projects", isDirectory: true)
    }

    static func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func manifest(_ id: UUID) -> URL { dir(id).appendingPathComponent("project.json") }
    static func video(_ p: Project) -> URL { dir(p.id).appendingPathComponent(p.videoFileName) }
    static func originals(_ id: UUID) -> URL { dir(id).appendingPathComponent("originals", isDirectory: true) }
    static func exports(_ id: UUID) -> URL { dir(id).appendingPathComponent("照片", isDirectory: true) }
    static func optimizedDir(_ id: UUID) -> URL { dir(id).appendingPathComponent("optimized", isDirectory: true) }
    static func importTemp(_ id: UUID) -> URL { dir(id).appendingPathComponent("import-tmp", isDirectory: true) }
    static func output(_ id: UUID) -> URL { dir(id).appendingPathComponent("output.mp4") }

    static func fileName(_ number: Int, ext: String) -> String { String(format: "%04d", number) + "." + ext }
    static func original(_ id: UUID, _ n: Int) -> URL { originals(id).appendingPathComponent(fileName(n, ext: "jpg")) }
    static func export(_ id: UUID, _ n: Int) -> URL { exports(id).appendingPathComponent(fileName(n, ext: "jpg")) }
    static func optimized(_ id: UUID, _ n: Int) -> URL { optimizedDir(id).appendingPathComponent(fileName(n, ext: "png")) }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

import Foundation
import CoreImage
import UIKit
import Vision
import Combine
import UniformTypeIdentifiers

struct ImportCandidate: Identifiable {
    let id = UUID()
    /// 已经裁掉编号黑边、只剩画面的临时文件
    let tempURL: URL
    let thumbnail: UIImage?
    let detectedNumber: Int?
    var assignedNumber: Int?
    let method: String
    let warning: String?
}

final class ImportSession: Identifiable, ObservableObject {
    let id = UUID()
    @Published var candidates: [ImportCandidate]
    init(candidates: [ImportCandidate]) { self.candidates = candidates }
}

final class FrameImporter: @unchecked Sendable {
    let project: Project
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(project: Project) {
        self.project = project
    }

    func prepareTempDir() throws {
        let dir = ProjectPaths.importTemp(project.id)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 处理一张 GPT 优化后的照片：识别编号 → 缩放回导出时的画布 → 裁掉编号黑边
    func process(data: Data, name: String?) throws -> ImportCandidate {
        guard var ci = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw SimpleError("无法读取图片")
        }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        guard let source = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImageFiles.sRGB) else {
            throw SimpleError("无法读取图片")
        }
        let L = project.layout
        let expectedAspect = Double(L.canvasWidth) / Double(L.canvasHeight)
        let actualAspect = Double(source.width) / Double(source.height)
        var warning: String?
        if abs(actualAspect - expectedAspect) / expectedAspect > 0.03 {
            warning = "比例和导出时不一致（\(source.width)×\(source.height)），画面可能被拉伸"
        }
        guard let canvas = ImageFiles.resize(source, width: L.canvasWidth, height: L.canvasHeight) else {
            throw SimpleError("处理图片失败")
        }

        var number: Int?
        var method = "未识别到编号"
        // 1. 编号所在的黑边右侧
        let strip = L.stripRect.integral
        let numberArea = CGRect(x: strip.minX + strip.width * 0.4, y: strip.minY, width: strip.width * 0.6, height: strip.height)
        if let img = canvas.cropping(to: numberArea), let n = recognizeNumber(in: img) {
            number = n
            method = "识别编号"
        }
        // 2. 整个底部（GPT 可能把编号挪了位置）
        if number == nil {
            let h = Double(L.canvasHeight)
            let bottom = CGRect(x: 0, y: h * 0.6, width: Double(L.canvasWidth), height: h * 0.4)
            if let img = canvas.cropping(to: bottom), let n = recognizeNumber(in: img) {
                number = n
                method = "识别编号"
            }
        }
        // 3. 文件名
        if number == nil, let name, let n = Self.numberFromFileName(name, max: project.frames.count) {
            number = n
            method = "按文件名"
        }

        guard let content = canvas.cropping(to: L.contentRect.integral) else { throw SimpleError("裁剪失败") }
        let url = ProjectPaths.importTemp(project.id).appendingPathComponent(UUID().uuidString + ".png")
        try ImageFiles.write(content, to: url, type: .png)
        let thumb = ImageFiles.thumbnail(content, maxPixel: 240).map { UIImage(cgImage: $0) }
        return ImportCandidate(tempURL: url, thumbnail: thumb, detectedNumber: number, assignedNumber: number,
                               method: method, warning: warning)
    }

    private func recognizeNumber(in image: CGImage) -> Int? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let results = request.results else { return nil }
        let maxNumber = project.frames.count
        var best: (number: Int, score: Float)?
        for obs in results {
            for cand in obs.topCandidates(3) {
                for token in Self.numberTokens(cand.string) {
                    guard (1...maxNumber).contains(token.value) else { continue }
                    // 4 位数字（和导出格式一致）优先
                    let score = cand.confidence + (token.digits == 4 ? 1 : 0)
                    if best == nil || score > best!.score { best = (token.value, score) }
                }
            }
        }
        return best?.number
    }

    /// 把识别出来的文字拆成数字，顺便纠正常见的识别错误（O→0、I→1 等）
    static func numberTokens(_ s: String) -> [(value: Int, digits: Int)] {
        let fix: [Character: Character] = [
            "O": "0", "o": "0", "D": "0", "Q": "0", "I": "1", "l": "1", "|": "1", "i": "1",
            "Z": "2", "z": "2", "S": "5", "s": "5", "B": "8", "G": "6", "g": "9", "q": "9",
        ]
        var out: [(value: Int, digits: Int)] = []
        for raw in s.split(whereSeparator: { $0.isWhitespace || $0 == "#" || $0 == "-" || $0 == "_" || $0 == "." }) {
            var digits = ""
            var ok = true
            for ch in raw {
                if ch.isASCII && ch.isNumber {
                    digits.append(ch)
                } else if let f = fix[ch] {
                    digits.append(f)
                } else {
                    ok = false
                    break
                }
            }
            if ok, (1...5).contains(digits.count), let v = Int(digits) { out.append((value: v, digits: digits.count)) }
        }
        return out
    }

    static func numberFromFileName(_ name: String, max: Int) -> Int? {
        let base = (name as NSString).deletingPathExtension
        for token in base.split(whereSeparator: { !$0.isNumber }) where token.count == 4 {
            if let v = Int(token), (1...max).contains(v) { return v }
        }
        return nil
    }

    /// 把确认好的照片放进项目
    static func apply(_ candidates: [ImportCandidate], to project: inout Project) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: ProjectPaths.optimizedDir(project.id), withIntermediateDirectories: true)
        var count = 0
        for c in candidates {
            guard let n = c.assignedNumber, let idx = project.frames.firstIndex(where: { $0.number == n }) else { continue }
            let dest = ProjectPaths.optimized(project.id, n)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: c.tempURL, to: dest)
            project.frames[idx].optimized = true
            count += 1
        }
        try? fm.removeItem(at: ProjectPaths.importTemp(project.id))
        project.revision += 1
        return count
    }

    static func discard(_ project: Project) {
        try? FileManager.default.removeItem(at: ProjectPaths.importTemp(project.id))
    }
}

import AVFoundation
import CoreImage
import UIKit
import UniformTypeIdentifiers

struct SamplingOptions: Hashable {
    /// 每秒抽几张；nil 表示全部帧
    var perSecond: Double?
    /// 智能抽帧：画面动得多的地方多抽
    var smart: Bool

    var description: String {
        guard let s = perSecond else { return "全部帧" }
        return "每秒 \(Int(s)) 张" + (smart ? "（智能）" : "")
    }
}

struct ExtractionResult {
    var width: Int
    var height: Int
    var nominalFPS: Double
    var duration: Double
    var totalFrames: Int
    var hasAudio: Bool
    var layout: CanvasLayout
    var frames: [FrameItem]
}

struct VideoInfo {
    var width: Int
    var height: Int
    var fps: Double
    var duration: Double
    var hasAudio: Bool
    var orientation: CGImagePropertyOrientation

    static func load(_ url: URL) async throws -> (VideoInfo, AVURLAsset, AVAssetTrack) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SimpleError("这个文件里没有视频画面")
        }
        let (naturalSize, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let orientation = Self.orientation(from: transform)
        let rotated: Bool
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: rotated = true
        default: rotated = false
        }
        let w = Int(abs(rotated ? naturalSize.height : naturalSize.width).rounded())
        let h = Int(abs(rotated ? naturalSize.width : naturalSize.height).rounded())
        let info = VideoInfo(width: w, height: h, fps: Double(fps > 0 ? fps : 30), duration: duration,
                             hasAudio: hasAudio, orientation: orientation)
        return (info, asset, track)
    }

    static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        func eq(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < 0.01 }
        let (a, b, c, d) = (t.a, t.b, t.c, t.d)
        if eq(a, 0) && eq(b, 1) && eq(c, -1) && eq(d, 0) { return .right }
        if eq(a, 0) && eq(b, -1) && eq(c, 1) && eq(d, 0) { return .left }
        if eq(a, -1) && eq(b, 0) && eq(c, 0) && eq(d, -1) { return .down }
        if eq(a, -1) && eq(b, 0) && eq(c, 0) && eq(d, 1) { return .upMirrored }
        if eq(a, 1) && eq(b, 0) && eq(c, 0) && eq(d, -1) { return .downMirrored }
        if eq(a, 0) && eq(b, 1) && eq(c, 1) && eq(d, 0) { return .leftMirrored }
        if eq(a, 0) && eq(b, -1) && eq(c, -1) && eq(d, 0) { return .rightMirrored }
        return .up
    }
}

final class FrameExtractor: @unchecked Sendable {
    static let maxDuration: Double = 15

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func extract(videoURL: URL, projectID: UUID, options: SamplingOptions,
                 progress: @escaping @Sendable (Double, String) -> Void) async throws -> ExtractionResult {
        let (info, asset, track) = try await VideoInfo.load(videoURL)
        let limit = min(info.duration, Self.maxDuration)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 600))

        // 第一遍：读出每一帧的时间；智能抽帧时同时计算画面变化
        progress(0, "分析视频…")
        var times: [Double] = []
        var signatures: [[Float]] = []
        try readFrames(asset: asset, track: track, range: range) { pts, pixelBuffer in
            times.append(pts.seconds)
            if options.smart { signatures.append(self.signature(pixelBuffer)) }
            progress(min(0.3, 0.3 * pts.seconds / max(limit, 0.01)), "分析视频…")
        }
        guard !times.isEmpty else { throw SimpleError("没有读到任何画面") }
        let t0 = times[0]

        let selected = Self.select(times: times.map { $0 - t0 }, signatures: signatures, options: options, duration: limit)
        let selectedSet = Set(selected)
        let layout = LayoutCalculator.layout(videoWidth: info.width, videoHeight: info.height)

        let fm = FileManager.default
        for dir in [ProjectPaths.originals(projectID), ProjectPaths.exports(projectID), ProjectPaths.optimizedDir(projectID)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 第二遍：生成被选中的照片
        var frames: [FrameItem] = []
        var index = 0
        let total = selected.count
        try readFrames(asset: asset, track: track, range: range) { pts, pixelBuffer in
            defer { index += 1 }
            guard selectedSet.contains(index) else { return }
            guard let cg = self.orientedImage(pixelBuffer, info.orientation) else { return }
            let number = frames.count + 1
            try ImageFiles.write(cg, to: ProjectPaths.original(projectID, number), type: .jpeg, quality: 0.93)
            guard let data = LabelRenderer.renderExport(original: cg, number: number, layout: layout) else {
                throw SimpleError("生成照片失败")
            }
            try data.write(to: ProjectPaths.export(projectID, number), options: .atomic)
            frames.append(FrameItem(number: number, sourceIndex: index, time: pts.seconds - t0))
            progress(0.3 + 0.7 * Double(number) / Double(max(total, 1)), "生成照片 \(number)/\(total)")
        }
        guard !frames.isEmpty else { throw SimpleError("没有生成任何照片") }

        return ExtractionResult(width: info.width, height: info.height, nominalFPS: info.fps, duration: limit,
                                totalFrames: times.count, hasAudio: info.hasAudio, layout: layout, frames: frames)
    }

    // MARK: - 解码

    private func readFrames(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange,
                            handler: (CMTime, CVPixelBuffer) throws -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SimpleError("无法读取视频") }
        reader.add(output)
        guard reader.startReading() else {
            throw SimpleError("无法读取视频：\(reader.error?.localizedDescription ?? "")")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var finished = false
        while !finished {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else {
                    finished = true
                    return
                }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
                try handler(CMSampleBufferGetPresentationTimeStamp(sample), pb)
            }
        }
        if reader.status == .failed {
            throw SimpleError("读取视频出错：\(reader.error?.localizedDescription ?? "")")
        }
    }

    private func orientedImage(_ pb: CVPixelBuffer, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        var ci = CIImage(cvPixelBuffer: pb).oriented(orientation)
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImageFiles.sRGB)
    }

    /// 32×18 的灰度缩略图，用来衡量相邻帧之间画面变化了多少
    private func signature(_ pb: CVPixelBuffer) -> [Float] {
        let w = 32, h = 18
        let ci = CIImage(cvPixelBuffer: pb)
        let sx = CGFloat(w) / ci.extent.width
        let sy = CGFloat(h) / ci.extent.height
        let small = ci.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: sy,
            kCIInputAspectRatioKey: sx / sy,
        ])
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        ciContext.render(small, toBitmap: &bytes, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: ImageFiles.sRGB)
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            out[i] = (0.299 * Float(bytes[i * 4]) + 0.587 * Float(bytes[i * 4 + 1]) + 0.114 * Float(bytes[i * 4 + 2])) / 255
        }
        return out
    }

    // MARK: - 抽帧

    static func select(times: [Double], signatures: [[Float]], options: SamplingOptions, duration: Double) -> [Int] {
        let n = times.count
        guard n > 1 else { return n == 1 ? [0] : [] }
        guard let sps = options.perSecond else { return Array(0..<n) }
        let target = max(2, Int((duration * sps).rounded()))
        if target >= n { return Array(0..<n) }

        if options.smart && signatures.count == n {
            var diffs = [Float](repeating: 0, count: n)
            for i in 1..<n { diffs[i] = meanAbsDiff(signatures[i - 1], signatures[i]) }
            var selected: Set<Int> = [0, n - 1]
            // 镜头切换：前后两帧都保留
            for i in 1..<n where diffs[i] > 0.18 {
                selected.insert(i - 1)
                selected.insert(i)
            }
            let mean = diffs.reduce(0, +) / Float(n)
            let base = mean * 0.5 + 0.002
            var cumulative = [Float](repeating: 0, count: n)
            for i in 1..<n { cumulative[i] = cumulative[i - 1] + min(diffs[i], 0.1) + base }
            let totalWeight = cumulative[n - 1]
            let slots = target - selected.count
            if slots > 0 && totalWeight > 0 {
                var i = 0
                for k in 1...slots {
                    let threshold = totalWeight * Float(k) / Float(slots + 1)
                    while i < n - 1 && cumulative[i] < threshold { i += 1 }
                    selected.insert(i)
                }
            }
            return selected.sorted()
        }

        var selected = Set<Int>()
        var i = 0
        for k in 0..<target {
            let t = Double(k) / sps
            while i + 1 < n && abs(times[i + 1] - t) <= abs(times[i] - t) { i += 1 }
            selected.insert(i)
        }
        return selected.sorted()
    }

    private static func meanAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var s: Float = 0
        for i in 0..<a.count { s += abs(a[i] - b[i]) }
        return s / Float(a.count)
    }
}

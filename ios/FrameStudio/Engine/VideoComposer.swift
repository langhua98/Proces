import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import simd

enum InterpolationMode: String, CaseIterable, Identifiable {
    case blend = "渐变融合（流畅）"
    case none = "不补帧（定格）"
    var id: String { rawValue }
}

enum OutputCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264（兼容好）"
    case hevc = "HEVC（体积小）"
    var id: String { rawValue }
}

enum OutputSizeMode: String, CaseIterable, Identifiable {
    case original = "原视频尺寸"
    case optimized = "GPT 照片尺寸"
    var id: String { rawValue }
}

struct ComposeOptions {
    var fps: Double = 30
    var interpolation: InterpolationMode = .blend
    var colorSmoothing = true
    var keepAudio = true
    var useOriginalForMissing = false
    var codec: OutputCodec = .h264
    var sizeMode: OutputSizeMode = .original
}

final class VideoComposer: @unchecked Sendable {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private struct Key {
        let time: Double
        let url: URL
    }

    func compose(project: Project, options: ComposeOptions,
                 progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let fm = FileManager.default

        // 1. 收集要用的照片
        var keys: [Key] = []
        for f in project.frames.sorted(by: { $0.number < $1.number }) {
            let opt = ProjectPaths.optimized(project.id, f.number)
            if f.optimized && fm.fileExists(atPath: opt.path) {
                keys.append(Key(time: f.time, url: opt))
            } else if options.useOriginalForMissing {
                keys.append(Key(time: f.time, url: ProjectPaths.original(project.id, f.number)))
            }
        }
        guard !keys.isEmpty else { throw SimpleError("还没有可用的照片：请先导入 GPT 优化后的照片") }

        // 2. 输出尺寸（编码器要求偶数）
        var size = CGSize(width: project.videoWidth, height: project.videoHeight)
        if options.sizeMode == .optimized, let s = ImageFiles.pixelSize(keys[0].url) { size = s }
        let w = max(2, Int(size.width) / 2 * 2)
        let h = max(2, Int(size.height) / 2 * 2)

        // 3. 颜色平滑：减少 GPT 每张颜色不一样带来的闪烁
        var gains = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 1), count: keys.count)
        if options.colorSmoothing && keys.count >= 3 {
            progress(0, "分析颜色…")
            let means = keys.map { averageColor($0.url) }
            gains = Self.smoothingGains(means)
        }

        // 4. 编码
        let tmpURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: tmpURL, fileType: .mp4)
        let bitrate = Int(Double(w * h) * options.fps * 0.2)
        let settings: [String: Any] = [
            AVVideoCodecKey: options.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw SimpleError("无法创建视频（尺寸 \(w)×\(h) 可能不被支持）") }
        writer.add(input)
        guard writer.startWriting() else {
            throw SimpleError("无法创建视频：\(writer.error?.localizedDescription ?? "")")
        }
        writer.startSession(atSourceTime: .zero)

        let duration = min(project.duration, FrameExtractor.maxDuration)
        let total = max(1, Int((duration * options.fps).rounded()))
        var cache: [Int: CIImage] = [:]

        func prepared(_ i: Int) throws -> CIImage {
            if let c = cache[i] { return c }
            guard var img = CIImage(contentsOf: keys[i].url) else { throw SimpleError("无法读取照片") }
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            let sx = CGFloat(w) / img.extent.width
            let sy = CGFloat(h) / img.extent.height
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: sy,
                kCIInputAspectRatioKey: sx / sy,
            ])
            img = img.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            let g = gains[i]
            if g != SIMD3<Float>(repeating: 1) {
                // 颜色是在 sRGB 下测的，Core Image 在线性空间里计算，所以做一次近似换算
                let lin = SIMD3<Float>(powf(g.x, 2.2), powf(g.y, 2.2), powf(g.z, 2.2))
                img = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(lin.x), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(lin.y), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(lin.z), w: 0),
                ])
            }
            guard let cg = ciContext.createCGImage(img, from: CGRect(x: 0, y: 0, width: w, height: h)) else {
                throw SimpleError("处理照片失败")
            }
            let result = CIImage(cgImage: cg)
            cache[i] = result
            return result
        }

        var k = 0
        for j in 0..<total {
            try Task.checkCancellation()
            let t = Double(j) / options.fps
            while k + 1 < keys.count && keys[k + 1].time <= t { k += 1 }
            cache = cache.filter { $0.key >= k }

            let a = try prepared(k)
            var frame = a
            if options.interpolation == .blend && k + 1 < keys.count && t > keys[k].time {
                let b = try prepared(k + 1)
                let span = keys[k + 1].time - keys[k].time
                let alpha = span > 0 ? (t - keys[k].time) / span : 0
                let f = CIFilter.dissolveTransition()
                f.inputImage = a
                f.targetImage = b
                f.time = Float(min(max(alpha, 0), 1))
                frame = f.outputImage ?? a
            }

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw SimpleError("编码器出错：\(writer.error?.localizedDescription ?? "")")
            }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw SimpleError("内存不足") }
            ciContext.render(frame, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: ImageFiles.sRGB)
            let pts = CMTime(seconds: t, preferredTimescale: 60000)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw SimpleError("写入视频失败：\(writer.error?.localizedDescription ?? "")")
            }
            progress(0.05 + 0.85 * Double(j + 1) / Double(total), "合成中 \(j + 1)/\(total)")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SimpleError("合成失败：\(writer.error?.localizedDescription ?? "")")
        }

        // 5. 加回原视频声音
        let finalURL = ProjectPaths.output(project.id)
        try? fm.removeItem(at: finalURL)
        if options.keepAudio && project.hasAudio {
            progress(0.95, "加入声音…")
            do {
                try await mergeAudio(videoURL: tmpURL, audioSource: ProjectPaths.video(project), output: finalURL)
                try? fm.removeItem(at: tmpURL)
            } catch {
                try? fm.removeItem(at: finalURL)
                try fm.moveItem(at: tmpURL, to: finalURL)
            }
        } else {
            try fm.moveItem(at: tmpURL, to: finalURL)
        }
        progress(1, "完成")
        return finalURL
    }

    private func mergeAudio(videoURL: URL, audioSource: URL, output: URL) async throws {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: videoURL)
        let aAsset = AVURLAsset(url: audioSource)
        guard let vTrack = try await vAsset.loadTracks(withMediaType: .video).first else { throw SimpleError("没有视频") }
        let vDuration = try await vAsset.load(.duration)
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SimpleError("合成失败")
        }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vDuration), of: vTrack, at: .zero)
        guard let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first else { throw SimpleError("没有声音") }
        let aRange = try await aTrack.load(.timeRange)
        let dur = CMTimeMinimum(vDuration, aRange.duration)
        guard let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SimpleError("合成失败")
        }
        try ca.insertTimeRange(CMTimeRange(start: aRange.start, duration: dur), of: aTrack, at: .zero)

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw SimpleError("无法导出")
        }
        export.outputURL = output
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else { throw export.error ?? SimpleError("加入声音失败") }
    }

    private func averageColor(_ url: URL) -> SIMD3<Float> {
        guard let img = CIImage(contentsOf: url) else { return SIMD3<Float>(repeating: 0.5) }
        let f = CIFilter.areaAverage()
        f.inputImage = img
        f.extent = img.extent
        guard let out = f.outputImage else { return SIMD3<Float>(repeating: 0.5) }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: out.extent.minX, y: out.extent.minY, width: 1, height: 1),
                         format: .RGBA8, colorSpace: ImageFiles.sRGB)
        return SIMD3<Float>(Float(px[0]), Float(px[1]), Float(px[2])) / 255
    }

    /// 每张照片的平均颜色和前后几张做加权平均，算出需要的校正系数。遇到镜头切换（亮度突变）时不跨越。
    static func smoothingGains(_ means: [SIMD3<Float>]) -> [SIMD3<Float>] {
        func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
        let n = means.count
        let weights: [Float] = [1, 2, 3, 2, 1]
        var out = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 1), count: n)
        for i in 0..<n {
            var acc = SIMD3<Float>(repeating: 0)
            var wsum: Float = 0
            for (offset, weight) in zip(-2...2, weights) {
                let j = i + offset
                guard j >= 0, j < n else { continue }
                if abs(luma(means[j]) - luma(means[i])) > 0.15 { continue }
                acc += means[j] * weight
                wsum += weight
            }
            guard wsum > 0 else { continue }
            let target = acc / wsum
            let g = target / simd_max(means[i], SIMD3<Float>(repeating: 0.02))
            out[i] = simd_clamp(g, SIMD3<Float>(repeating: 0.85), SIMD3<Float>(repeating: 1.18))
        }
        return out
    }
}

import UIKit

enum LayoutCalculator {
    /// GPT 图片常用的三种比例（3:2、1:1、2:3），按这个比例补边，GPT 返回时就不会裁切或变形
    static let canvases: [(Int, Int)] = [(2304, 1536), (2048, 2048), (1536, 2304)]
    /// 编号黑边至少占画布高度的比例
    static let minStripFraction = 0.1

    static func layout(videoWidth: Int, videoHeight: Int) -> CanvasLayout {
        let aspect = Double(max(videoWidth, 1)) / Double(max(videoHeight, 1))
        var best: CanvasLayout?
        var bestScore = -1.0
        for (cw, ch) in canvases {
            let boxW = Double(cw)
            let boxH = Double(ch) * (1 - minStripFraction)
            var w: Double
            var h: Double
            if aspect >= boxW / boxH {
                w = boxW
                h = boxW / aspect
            } else {
                h = boxH
                w = boxH * aspect
            }
            w = floor(w)
            h = floor(h)
            let x = floor((Double(cw) - w) / 2)
            let content = CGRect(x: x, y: 0, width: w, height: h)
            let strip = CGRect(x: 0, y: h, width: Double(cw), height: Double(ch) - h)
            let score = (w * h) / (Double(cw) * Double(ch))
            if score > bestScore {
                bestScore = score
                best = CanvasLayout(canvasWidth: cw, canvasHeight: ch, contentRect: content, stripRect: strip)
            }
        }
        return best!
    }
}

enum LabelRenderer {
    static func text(for number: Int) -> String { String(format: "%04d", number) }

    /// 生成导出给 GPT 的照片：黑色画布 + 原画面 + 黑边右下角编号
    static func renderExport(original: CGImage, number: Int, layout: CanvasLayout) -> Data? {
        let size = CGSize(width: layout.canvasWidth, height: layout.canvasHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: original).draw(in: layout.contentRect)
            drawLabel(number: number, in: layout.stripRect, canvasHeight: size.height)
        }
        return image.jpegData(compressionQuality: 0.95)
    }

    static func drawLabel(number: Int, in strip: CGRect, canvasHeight: CGFloat) {
        let fontSize = min(strip.height * 0.62, canvasHeight * 0.085)
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let str = NSAttributedString(string: text(for: number), attributes: attrs)
        let ts = str.size()
        let pad = max(strip.height * 0.2, fontSize * 0.3)
        let origin = CGPoint(x: strip.maxX - ts.width - pad, y: strip.midY - ts.height / 2)
        str.draw(at: origin)
    }
}

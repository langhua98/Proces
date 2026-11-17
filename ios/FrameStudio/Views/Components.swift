import SwiftUI
import UIKit
import AVKit
import CoreTransferable
import UniformTypeIdentifiers

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for url: URL, maxPixel: Int) async -> UIImage? {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(maxPixel)|\(mod)" as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = await Task.detached(priority: .utility) { () -> UIImage? in
            ImageFiles.thumbnail(url, maxPixel: maxPixel).map { UIImage(cgImage: $0) }
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

struct ThumbnailView: View {
    let url: URL
    var maxPixel: Int = 320
    var token: Int = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .task(id: "\(url.path)#\(token)") {
            image = await ThumbnailCache.shared.image(for: url, maxPixel: maxPixel)
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct PendingVideo: Identifiable {
    let id = UUID()
    let url: URL
}

struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(text).font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct OutputPlayer: View {
    let url: URL
    let token: Int
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: token) {
                player = AVPlayer(url: url)
            }
    }
}

struct StepCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>, title: String = "提示") -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil },
                                          set: { if !$0 { message.wrappedValue = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

func formatSeconds(_ s: Double) -> String {
    String(format: "%.1f 秒", s)
}

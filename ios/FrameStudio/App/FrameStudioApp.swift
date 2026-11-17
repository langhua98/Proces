import SwiftUI

@main
struct FrameStudioApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environmentObject(store)
        }
    }
}

enum PromptDefaults {
    static let text = """
    请优化这张图片的画质：提升清晰度和细节、去除噪点、改善光线。\
    保持画面的构图、人物、物体位置和颜色风格完全不变，不要裁剪、不要改变图片比例。\
    不要修改图片底部的黑色区域和右下角的数字。
    """
}

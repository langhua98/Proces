# 帧工坊（Proces）

iOS App：把视频（最长 15 秒）拆成带编号的照片 → 你把照片交给 GPT 优化 → 导入优化后的照片 → 自动识别编号、去掉编号、合成视频。

技术方案见 [docs/技术方案.md](docs/技术方案.md)。

## 下载 IPA

每次推送 `ios/` 下的代码，GitHub Actions 会自动在 macOS 上编译一个**未签名**的 IPA：

- Releases 页面的 `ipa-latest`（手机上可直接下载）
- 或 Actions 运行记录里的 `FrameStudio-unsigned-ipa` 附件

下载后用你自己的证书签名安装（默认 Bundle ID：`com.proces.framestudio`，可在签名工具里修改）。

## 使用流程

1. 右上角 ＋ 选择视频，选择抽帧频率（默认每秒 4 张，可选全部帧），点「开始拆帧」
2. **导出**：「存到相册」（会新建相簿）/「分享」/「ZIP」。每张照片底部有一条黑边，编号在黑边右下角
3. 点「复制提示词」，把照片和提示词一起发给 ChatGPT，下载优化后的照片
4. **导入**：从相册或文件选择优化后的照片（可分多次）。App 用文字识别读取编号，识别不到的可以手动填
5. **合成**：选帧率、补帧（渐变融合）、颜色平滑、尺寸、编码、是否保留原声音 → 预览 → 保存到相册

## 工程结构

```
ios/project.yml          XcodeGen 工程配置
ios/FrameStudio/
  Engine/                拆帧、编号、识别、合成
  Views/                 SwiftUI 界面
  Models/                项目数据
.github/workflows/ios.yml  编译未签名 IPA
```

本地编译（需要 Mac）：`brew install xcodegen && cd ios && xcodegen generate && open FrameStudio.xcodeproj`

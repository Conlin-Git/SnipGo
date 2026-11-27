<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="SnipGo">
</p>

<h1 align="center">SnipGo</h1>

<p align="center">
  轻量的 macOS 菜单栏截图工具：截图 · 圈图标注 · 马赛克 · 滚动长图 · 钉图 · 录视频
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-orange?logo=swift" alt="Swift 6">
  <img src="https://img.shields.io/badge/ScreenCaptureKit-native-blue" alt="ScreenCaptureKit">
</p>

---

## 功能

| 功能 | 说明 |
|---|---|
| 📸 **截图** | 拖拽选区，或单击直接选中窗口；方向键微调，选区按 Retina 像素对齐导出 |
| ✏️ **圈图标注** | 矩形、椭圆、直线、箭头、画笔、文字，可选 3 档粗细和 8 种颜色，⌘Z 撤销 |
| 🔲 **马赛克** | 画笔式涂抹打码，屏幕上看到的效果就是导出的效果 |
| 📜 **滚动长图** | 选区后手动滚动页面，自动拼接；能识别吸顶导航和吸底栏，右侧实时预览 |
| 📌 **钉图** | 把截图钉在桌面最上层（全屏应用里也能看到），可拖动，滚轮或触控板捏合缩放 |
| 🎬 **录视频** | QuickTime 风格的底部控制条，录整个屏幕或所选部分，输出 mp4（H.264），可录系统声音和麦克风 |
| ⚙️ **偏好设置** | 开机自启、提示音、jpg/png、自定义快捷键、文件名前缀、保存位置 |

## 安装

需要 **macOS 15 或更高版本**，并安装 Xcode（Swift 6 工具链）。

```bash
git clone https://github.com/Conlin-Git/SnipGo.git
cd SnipGo
./scripts/build.sh --install   # 编译并安装到 /Applications
open /Applications/SnipGo.app
```

第一次使用时，需要在 **系统设置 › 隐私与安全性 › 屏幕与系统录音** 中允许 SnipGo，然后重新打开应用。录制麦克风时会另外申请麦克风权限。

> 打包脚本会优先使用本机的 Apple Development 证书签名，这样重新编译后不需要再次授权；没有证书时退回 ad-hoc 签名。

## 使用

SnipGo 常驻菜单栏（剪刀图标），所有功能都可以从菜单栏菜单或快捷键进入。

### 快捷键

| 操作 | 快捷键 |
|---|---|
| 截图 | `⌘⇧1` |
| 新建录屏；录制中再按一次停止 | `⌘⇧2` |
| 复制到剪贴板 | `↩` / `⌘C` / 双击选区 |
| 保存到文件 | `⌘S` |
| 撤销标注 | `⌘Z` |
| 微调选区（按住 `⇧` 每次移动 10pt） | 方向键 |
| 取消 | `Esc` / 右键 |

两个全局快捷键都可以在「偏好设置」中修改。

### 截图与标注

1. 按 `⌘⇧1`，拖拽出一个选区，或者单击选中某个窗口。
2. 在选区下方的工具栏里选择标注工具，下面一行可以切换粗细和颜色。
3. 点 **复制** 或 **保存** 完成；点选区右上角的 **📌** 可以把截图钉在桌面上。

### 滚动长图

1. 截图选好区域后，点工具栏里的 **长截图** 按钮。
2. 像平时一样向下滚动页面，右侧会实时显示拼接结果。
3. 在工具栏中选择 **复制 / 保存 / 钉图**。

> 滚动太快、或者两帧之间全是空白时会接不上，放慢速度继续滚动即可；向上滚动的帧会被自动忽略。

### 钉图

| 操作 | 方式 |
|---|---|
| 移动 | 拖动 |
| 缩放（10%–800%） | 滚轮、触控板捏合，或 `+` / `-`；`0` 恢复 100% |
| 复制 / 保存 | `⌘C` / `⌘S` |
| 关闭 | 双击或 `Esc` |
| 更多操作 | 右键菜单（含「关闭所有钉图」） |

### 录视频

1. 按 `⌘⇧2`，屏幕上会预先选好一块区域，可以直接拖动调整。
2. 在底部控制条中选择 **录制整个屏幕** 或 **录制所选部分**，在 **选项** 里开关麦克风、系统声音和鼠标指针。
3. 点 **录制** 开始。要结束时，单击菜单栏里的 ⏹ 计时按钮，或者再按一次 `⌘⇧2`。录好的 mp4 会在 Finder 中自动选中。

## 项目结构

```
SnipGo/
├── Package.swift
├── Resources/              Info.plist、图标源图
├── scripts/
│   ├── build.sh            编译 → 组装 .app → 生成图标 → 签名（--install 安装）
│   └── make_icon.swift     生成 AppIcon.icns
├── Sources/
│   ├── SnipCore/           长图拼接算法（纯算法，可单测）
│   └── SnipGo/
│       ├── Capture/        冻结屏幕、遮罩窗口、选区、工具栏、流程调度
│       ├── Editor/         标注模型与渲染（含马赛克）
│       ├── Scroll/         长截图会话（SCStream 采帧 + 实时预览）
│       ├── Record/         录屏会话（SCRecordingOutput）与底部控制条
│       ├── Pin/            钉图窗口
│       ├── Preferences/    SwiftUI 偏好设置、快捷键录制控件
│       └── Output/         保存、剪贴板、提示音
├── Tests/SnipCoreTests/    拼接算法单元测试
└── docs/技术方案.md         技术方案与任务清单
```

## 技术要点

- **截屏**：用 ScreenCaptureKit 的 `SCScreenshotManager` 冻结每块屏幕，用 `CGWindowListCopyWindowInfo` 按前后顺序识别窗口。
- **长图拼接**：每行提取 32 个列块的亮度特征，在中间区域枚举位移，选出不匹配行最少的那个；自动识别并保留吸顶和吸底区域；新增的条带单独拷贝保存，避免内存随帧数膨胀。
- **录屏**：`SCStream` 配合 `SCRecordingOutput` 直接写 mp4，像素尺寸取偶数，帧率 60fps。
- **全局快捷键**：Carbon `RegisterEventHotKey`，不需要辅助功能权限。

更多设计细节见 [docs/技术方案.md](docs/技术方案.md)。

## 开发

```bash
swift build          # 调试编译
swift test           # 运行长图拼接单元测试
./scripts/build.sh   # 打包为 build/SnipGo.app
```

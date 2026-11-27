# SnipGo OCR 与翻译方案（草案，待确认）

> 目标：截图后可以一键识别图中文字，并翻译成指定语言。
> 约束：免费、离线、不引入第三方依赖、不新增系统权限；最低系统版本仍为 macOS 15。

## 1. 范围

| 做 | 不做（本期） |
|---|---|
| 截图工具栏新增「识字」「翻译」两个按钮 | 屏幕实时取词、划词翻译 |
| 识别结果面板：可编辑、可复制、显示识别出的语言 | 在原图上覆盖译文（图片翻译） |
| 翻译面板：原文 / 译文对照，可切换目标语言，可复制译文 | 在线翻译接口（DeepL、Google、大模型） |
| 钉图右键菜单新增「识别文字」「翻译」（**待确认**） | 只识别图中一部分文字（框选部分文字） |
| 全局快捷键「截图并识字」（**待确认**，默认不设置） | 二维码 / 条形码识别、公式识别 |

## 2. 技术选型

| 能力 | 方案 | 说明 |
|---|---|---|
| OCR | Vision `VNRecognizeTextRequest` | 系统自带，离线，免费；macOS 15 支持简体/繁体中文、英、日、韩等，可开启自动检测语言 |
| 翻译 | Translation 框架 `TranslationSession` | 系统自带，离线，免费；首次使用某个语言对时系统弹窗下载语言包，之后离线可用 |
| 界面 | SwiftUI 面板（`NSPanel` + `NSHostingView`） | macOS 15 上 `TranslationSession` 只能通过 SwiftUI 的 `.translationTask` 获取，结果面板本来就用 SwiftUI 写，正好用它 |

不选在线接口的原因：要么收费，要么需要申请 key、有调用额度，而且截图内容会上传到第三方。

## 3. 交互流程

```
选区（可已标注）
 ├─ 点「识字」 ─→ 关闭遮罩 → 在选区附近弹出「识别结果」面板
 │                   ├─ 文本框（可编辑）  [复制] [翻译] [关闭]
 │                   └─ 点「翻译」→ 面板切到对照模式
 └─ 点「翻译」 ─→ 关闭遮罩 → 直接弹出对照面板（先 OCR，再翻译）
                     ├─ 左：原文（可编辑，编辑后可重新翻译）
                     ├─ 右：译文     目标语言 [简体中文 ⌄]
                     └─ [复制译文] [复制原文] [关闭]
```

- 工具栏位置：放在「长截图」之后、「保存」之前；图标用 SF Symbol `text.viewfinder`（识字）和 `character.bubble`（翻译）。
- 识别时用 `renderResult()` 的结果，也就是包含标注的图。马赛克盖住的文字自然识别不出来，这符合预期。
- 面板为浮动 `NSPanel`：可拖动；Esc 或 ⌘W 关闭；⌘C 在没有选中文字时复制全部内容。
- 识别中显示转圈；没有识别到文字时显示「未识别到文字」。
- 目标语言默认规则：原文主要是中文 → 英文，否则 → 简体中文。用户手动切换后会记住（UserDefaults `translateTarget`），下次优先使用；但原文是中文且记住的也是中文时仍用英文。

## 4. 关键实现

### 4.1 OCR（`TextRecognizer`）
1. `VNImageRequestHandler(cgImage:)` + `VNRecognizeTextRequest`，在后台队列执行，完成后回到主线程。
2. 参数：`recognitionLevel = .accurate`、`usesLanguageCorrection = true`、`automaticallyDetectsLanguage = true`、`recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]`。
3. 小字处理：选区像素高度小于 64 时，先把图放大 2 倍再识别，提高准确率。
4. 文本排版（放进 `SnipCore/TextLayout.swift`，纯算法可单测）：
   - 每个结果有一个归一化包围框；先按行聚类（框的纵向重叠超过 50% 视为同一行），行内按 x 排序。
   - 同一行内两个片段的间距明显大于字宽时插入空格；中文片段之间不加空格。
   - 行距明显大于平均行距时视为分段，输出空行。
5. 识别出的语言用 `NLLanguageRecognizer` 判断，结果用于决定默认目标语言。

### 4.2 翻译（`TranslatePanel`，SwiftUI）
1. 视图持有 `@State var config: TranslationSession.Configuration?`，挂 `.translationTask(config) { session in ... }`。
2. 需要翻译时设置 `config = .init(source: nil, target: 目标语言)`（`source` 为 nil 表示自动检测）；切换目标语言或原文被编辑后，调用 `config?.invalidate()` 重新翻译。
   - 实现时确认：中英混排文本 NaturalLanguage 会判成英文，若把它当源语言传入，中文段落会翻错，因此源语言始终交给框架检测；NaturalLanguage 的结果只用于默认目标语言和「原文已经是目标语言」提示。
3. 按段落拆分后用 `session.translations(from:)` 批量翻译，保留原来的分段。
4. 发起翻译前用 `LanguageAvailability().status(from:to:)` 检查：
   - `.installed`：直接翻译；
   - `.supported`：系统会弹出语言包下载提示，下载完成后自动继续；
   - `.unsupported`：面板提示「系统不支持该语言对」。
5. 目标语言列表取 `LanguageAvailability().supportedLanguages`，常用的（简体中文、英文、日文、韩文）放在前面。

### 4.3 接入现有代码

| 文件 | 改动 |
|---|---|
| `Capture/ToolbarView.swift` | `ToolbarCommand` 新增 `.recognizeText`、`.translate`；截图工具栏加两个按钮 |
| `Capture/CaptureCoordinator.swift` | 处理这两个命令：`renderResult()` → `finish()` → 打开面板，并把选区的全局坐标传给面板用于定位 |
| `OCR/TextRecognizer.swift`（新） | Vision 调用、小字放大 |
| `OCR/TextResultPanel.swift`（新） | 识别结果 / 对照翻译 SwiftUI 面板与窗口控制器 |
| `SnipCore/TextLayout.swift`（新） | 行聚类、空格与分段规则 |
| `Tests/SnipCoreTests/TextLayoutTests.swift`（新） | 中文、英文、中英混排、多栏、空行等用例 |
| `Pin/PinWindow.swift` | 右键菜单加两项（**待确认**） |
| `Settings.swift` / `AppDelegate.swift` | 全局快捷键「截图并识字」（**待确认**） |
| `docs/技术方案.md` | 把「OCR」从「不做」移到「做」，补充本方案的要点 |

长截图会话的工具栏本期不加这两个按钮。长图可以先钉图，再在钉图上识别（前提是确认做钉图入口）。

## 5. 权限与体积
- 不新增权限。Vision 和 Translation 都在本机运行，不联网（下载语言包时由系统联网）。
- 不新增依赖，App 体积基本不变；语言包由系统管理，占用的是系统空间。

## 6. 风险

| 风险 | 应对 |
|---|---|
| SnipGo 是菜单栏应用（`LSUIElement=1`），语言包下载提示可能无法正常弹出 | 实现后第一时间验证；如果有问题，先把面板设为 key window 并激活应用，或者引导用户去 系统设置 → 通用 → 语言与地区 → 翻译语言 里手动下载 |
| 翻译质量不如 DeepL 或大模型 | 本期接受；以后需要时再加「自定义翻译接口」选项（不在本期范围） |
| 艺术字、手写、极小字识别率低 | 小字放大；结果可编辑，用户可以手动修正 |
| 多栏排版的阅读顺序可能错乱 | 行聚类时考虑横向间距，有明显栏间距时按栏输出；单测覆盖 |

## 7. 任务清单
- [x] T21 `SnipCore/TextLayout` 排版算法 + 单元测试
- [x] T22 `TextRecognizer`：Vision 识别、小字放大、语言判断
- [x] T23 识别结果面板：编辑、复制、加载与空结果状态、定位与关闭
- [x] T24 翻译：`.translationTask` 接入、语言可用性检查、目标语言切换与记忆
- [x] T25 截图工具栏接入两个按钮 + 协调器处理
- [ ] T26 （待确认）钉图右键菜单入口
- [ ] T27 （待确认）全局快捷键「截图并识字」
- [ ] T28 构建验证：编译、单测、真机验证中英日文截图识别与翻译、首次下载语言包流程

## 8. 待你确认
1. 钉图右键菜单要不要加「识别文字 / 翻译」入口？
2. 要不要加全局快捷键「截图并识字」？如果要，默认留空，还是给一个默认组合（建议 ⌘⇧O；⌘⇧3/4/5 已被系统截图占用）？
3. 翻译默认规则（中文 → 英文，其他 → 简体中文）是否可以？

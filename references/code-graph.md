# HERMES 项目代码图谱

> 自动生成时间：2026-06-29
> 项目：HERMES — macOS Live Photo 合成与多平台媒体下载工具

---

## 项目概览

**项目名称**：HERMES
**用途**：macOS 原生应用，支持将静态照片 + 视频合成为 Apple Live Photo、从抖音/小红书/得物下载无水印媒体并自动合成、导入系统相册。
**技术栈**：Swift 6.2 · AppKit · AVFoundation · CoreMedia · ImageIO · Photos · SQLite3 · Combine
**最低系统**：macOS 26.0
**Bundle ID**：`com.codex.Hermes`
**构建方式**：Xcode 项目（`HERMES.xcodeproj`）+ SwiftPM（`Package.swift`，仅用于 `tool` 可执行目标）
**总代码量**：~46,858 行（27 个 Swift 源文件）

### 双可执行目标

| 目标 | 入口 | 用途 |
|------|------|------|
| Hermes.app | `HermesApp.swift` | 主应用 GUI |
| tool (CLI) | `tool.swift` | 命令行 Live Photo 合成工具，由主应用通过 `Process` 调用 |

---

## 目录结构

```
HERMES/
├── Sources/
│   ├── HermesApp.swift                       # 应用入口，菜单栏
│   ├── Models/
│   │   └── ImporterModel.swift               # 核心数据模型（~1880 行）
│   ├── UIModels.swift                        # 数据类型定义
│   ├── EmptyStateViews.swift                 # 空状态/拖放区域视图
│   ├── SidebarController.swift               # Finder 风格侧边栏
│   ├── SettingsWindow.swift                  # 设置窗口
│   ├── DownloadViews.swift                   # 下载栏与进度 UI
│   ├── tool.swift                            # Live Photo 合成 CLI 工具
│   ├── LivePhotoToolRunner.swift             # tool 进程调用封装
│   ├── PhotoLibraryImporter.swift            # 系统相册导入
│   ├── dydl.swift                            # 抖音下载器（~2850 行）
│   ├── dwdl.swift                            # 得物下载器
│   ├── rndl.swift                            # 小红书下载器
│   ├── DewuLogStore.swift                    # 得物日志 SQLite 访问
│   ├── DownloaderHTTPCompatibility.swift     # curl 回退 + DoH DNS
│   ├── Views/
│   │   ├── CollectionViews/
│   │   │   ├── PairCollectionView.swift      # 队列页缩略图集合视图
│   │   │   ├── DownloadCollectionView.swift  # 下载页缩略图集合视图
│   │   │   └── CompletedCollectionView.swift # 完成页缩略图集合视图
│   │   ├── Other/
│   │   │   ├── MainWindowController.swift    # 主窗口控制器
│   │   │   ├── NativeWindowToolbarController.swift # 动态工具栏
│   │   │   └── PageControllers.swift         # 页面切换控制器
│   │   └── Thumbnail/
│   │       ├── ThumbnailService.swift        # 缩略图基础设施
│   │       └── ThumbnailItemViews.swift      # 缩略图视图组件
│   └── Utilities/
│       ├── FileNaming.swift                  # 文件命名工具
│       ├── FileSystemUtilities.swift         # 文件类型检查
│       ├── RegexUtilities.swift              # 正则辅助
│       └── DownloaderInfra.swift             # 共享下载基础设施
├── Build/
│   └── Info.plist                            # 应用元数据
├── script/
│   ├── build_and_run.sh                      # 调试构建/运行脚本
│   ├── package_app.sh                        # Release 打包/安装脚本
│   └── project_config.sh                     # 共享项目配置
├── build.sh                                  # 主构建脚本
├── Package.swift                             # SwiftPM（tool 目标）
├── README.md                                 # 项目说明
└── .gitignore                                # Git 忽略规则
```

---

## 文件详细分析

### 1. `Sources/HermesApp.swift` — 应用入口与菜单栏

| 属性 | 说明 |
|------|------|
| **行数** | ~172 |
| **关键类型** | `HermesApp` (enum, `@main`), `HermesAppDelegate` (final class) |
| **职责** | 应用启动、主菜单构建、全局快捷操作 |

**关键流程：**
- `HermesApp.main()` → 创建 `NSApplication`，设置 `activationPolicy = .regular`
- `HermesAppDelegate.applicationDidFinishLaunching()` → 构建菜单 → 创建 `MainWindowController` → 显示窗口
- 菜单项通过 `NotificationCenter` 与 UI 层通信：
  - `OpenImportPanel` → 打开文件选择面板
  - `StartImport` → 开始合成
  - `SelectSidebarSection` → 切换侧边栏（queue/downloads/completed）
  - `RefreshCurrentPage` → 刷新当前页面
  - `OpenCurrentFolder` / `ChooseCurrentFolder` → 文件夹操作

**自定义 Notification.Name**：定义了 6 个全局通知名称。

---

### 2. `Sources/Models/ImporterModel.swift` — 核心数据模型（~1880 行）

| 属性 | 说明 |
|------|------|
| **类型** | `final class ImporterModel: ObservableObject` |
| **标注** | `@MainActor` |
| **职责** | 管理全部应用状态：文件队列、配对、下载、已完成项目、文件夹、偏好设置 |

**@Published 属性**：
- `selection: SidebarSection?` — 当前选中的侧边栏页面
- `files: [URL]` — 队列中的原始文件
- `pairs: [PairItem]` — 已识别的图像-视频配对
- `completed: [CompletedItem]` — 已完成项目
- `outputFolder / downloadOutputFolder: URL` — 输出/下载文件夹
- `importToPhotos / addToAlbum / completedAddToAlbum: Bool` — 偏好设置
- `downloadPairs / downloadPhotos / downloadVideos / downloadCompleted` — 下载页面状态
- `isDownloading / isProcessing / isImportingCompleted` 等处理状态标志
- `downloadProgressItems: [DownloadProgressItem]` — 下载进度条数据

**UserDefaults 持久化**：
- `OutputFolderPath` + `OutputFolderBookmark.v1` — 导出文件夹
- `CompletedRecords.v1` + `ImportedCompletedStems.v1` — 完成记录
- `DownloadOutputFolderPath.v1` + `DownloadOutputFolderBookmark.v1` — 下载文件夹
- `DownloadCompletedRecords.v1` + `ImportedDownloadCompletedStems.v1` — 下载完成记录

**核心方法**：
- `addFiles(_:)` / `clear(deleteFiles:)` / `chooseFiles()` — 队列管理
- `chooseOutputFolder()` / `moveOutputFolder(to:)` — 文件夹管理
- `processPairs()` / `processDownloadPairs()` — Live Photo 合成流程
- `downloadShare()` / `enqueueDownloadShare(shareText:)` — 下载入口
- `runSingleDownloader(shareText:destinationRoot:progress:)` — 平台路由（抖音/小红书/得物）
- `refreshDownloads()` / `applyDownloadedItems(_:)` — 下载文件夹扫描
- `rebuildPairs()` / `downloadItems(in:excluding:)` — 文件配对逻辑

---

### 3. `Sources/UIModels.swift` — 数据类型定义

| 属性 | 说明 |
|------|------|
| **行数** | ~205 |
| **关键类型** | `PairItem`, `CompletedItem`, `DownloadGridItem`, `DownloadScanResult`, `SidebarSection`, `CompletedFilter`, `DownloadFilter`, `AppSymbol`, `ToolRunResult` |

**主要数据结构**：
- `PairItem` — 图像-视频配对（id, imageURL, videoURL, status, message）
- `CompletedItem` — 已完成项目（Codable, imagePath, moviePath, modifiedTime, importedToPhotos）
- `DownloadGridItem` — 下载页面网格项（kind: pair/photo/video）
- `DownloadScanResult` — 下载文件夹扫描结果
- `SidebarSection` — 侧边栏分区（queue/downloads/completed）
- `AppSymbol` — SF Symbol 名称查找表

---

### 4. `Sources/dydl.swift` — 抖音下载器（~2850 行）

| 属性 | 说明 |
|------|------|
| **类型** | `enum DouyinNativeDownloader` |
| **职责** | 从抖音分享链接下载无水印最高分辨率媒体 |

**多源扫描策略**：
1. **Web Detail API** — `https://www.douyin.com/aweme/v1/web/aweme/detail/` 获取公开媒体列表
2. **Share Page HTML** — 解析 `_ROUTER_DATA` / `RENDER_DATA` / `__NEXT_DATA__` 提取种子信息
3. **Desktop Electron Cache** — 扫描抖音桌面客户端 `Cache_Data` 目录，通过 Node.js 脚本解析 Brotli 压缩缓存
   - `DouyinCacheIndex` — 缓存索引与增量更新
   - `cachedDesktopAweme()` — 多阶段匹配（awemeID、description、videoID）
   - `cachedDirectMediaAweme()` — 直接媒体 URL 匹配
   - `cachedTimelineLivePhotoVideos()` — 时间线关联 Live Photo 视频匹配
4. **Live Electron Request** — 使用抖音桌面客户端 Electron 运行时发起 HTTPS 请求
5. **Slides API** — `https://www.iesdouyin.com/web/api/v2/aweme/slidesinfo/`
6. **Mobile Feed API** — `https://api5-normal-c-lf.amemv.com/aweme/v1/feed/`

**媒体评分**：按分辨率 × 帧率 × HDR 标志 × 编码格式排序，选择最高质量可下载流。

**Live Photo 处理**：
- 自动识别多图帖的 Live Photo 视频对
- 从缓存或 Electron 请求中补充缺失的 Live Photo 视频 URL
- 检测可疑 Live Photo URL（video_id 参数包含 HTTP URL 而非视频 ID）

**缓存扫描**：
- 支持 3 个缓存根路径（沙盒/非沙盒容器）
- Brotli 解码（Node.js 辅助脚本）
- 并行 worker 处理

---

### 5. `Sources/rndl.swift` — 小红书下载器

| 属性 | 说明 |
|------|------|
| **类型** | `enum XHSNativeDownloader` |
| **职责** | 从小红书分享链接下载媒体 |

**策略**：双 User-Agent 策略（桌面 Safari + 移动 Safari），选择返回媒体最多的结果。

**解析**：从 HTML 提取 `__INITIAL_STATE__` JSON，多路径回退查找 `noteData`。

**视频评分**：按编码（h264/h265/h266/av1）、码率、HDR 标志评分。

**图片处理**：剥离 TIFF/EXIF/IPTC 元数据。

---

### 6. `Sources/dwdl.swift` — 得物下载器

| 属性 | 说明 |
|------|------|
| **类型** | `enum DewuNativeDownloader` |
| **职责** | 从得物分享链接下载媒体 |

**多源策略**：
1. 分享页 HTML — 解析 `__NEXT_DATA__`
2. App 日志 SQLite — 通过 `DewuLogStore` 读取
3. App API 重放 — 从日志提取 `pre_request_url`/header
4. 播放日志回退
5. 公开视频 URL

**App 联动**：后台打开得物 App 触发 API 请求，轮询新日志记录。

---

### 7. `Sources/DewuLogStore.swift` — 得物日志 SQLite

| 属性 | 说明 |
|------|------|
| **类型** | `enum DewuLogStore` |
| **职责** | 发现得物 App 容器，读取 SQLite 日志数据库 |

**功能**：定位 `com.siwuai.duapp` 容器，按日期查询 `DuLog.db`，安全书签访问。

---

### 8. `Sources/tool.swift` — Live Photo 合成 CLI

| 属性 | 说明 |
|------|------|
| **行数** | ~1372 |
| **职责** | 提取/生成 Asset ID，写入 EXIF MakerNote/HEIC ISO BMFF，生成 Apple 兼容 MOV |

**功能**：
- JPEG EXIF IFD 解析/序列化
- HEIC ISO BMFF 解析/写入
- hev1 → hvc1 视频编码转换
- AVAssetReader/Writer 管道

---

### 9. `Sources/LivePhotoToolRunner.swift` — Tool 进程调用

| 属性 | 说明 |
|------|------|
| **职责** | 查找 tool 二进制（Bundle 资源或 SwiftPM 构建产物），通过 `Process` 运行 |

---

### 10. 视图层文件

| 文件 | 职责 |
|------|------|
| `MainWindowController.swift` | NSSplitViewController，窗口配置，绑定 ImporterModel |
| `NativeWindowToolbarController.swift` | NSToolbarDelegate，动态工具栏（按页面切换） |
| `PageControllers.swift` | 页面容器，三页面切换（queue/downloads/completed） |
| `SidebarController.swift` | Finder 风格侧边栏（NSTableView + NSVisualEffectView） |
| `SettingsWindow.swift` | 设置窗口（导入偏好） |
| `EmptyStateViews.swift` | 空状态 + 拖放区域视图 |
| `DownloadViews.swift` | 下载栏 UI（玻璃态输入框 + 圆形下载按钮 + 进度条） |
| `PairCollectionView.swift` | 队列页 NSCollectionView |
| `DownloadCollectionView.swift` | 下载页 NSCollectionView |
| `CompletedCollectionView.swift` | 完成页 NSCollectionView |
| `ThumbnailService.swift` | 缩略图缓存（内存 NSCache + 磁盘 JPEG）、异步加载 |
| `ThumbnailItemViews.swift` | 缩略图 Cell、封面/时长角标 |

---

### 11. 工具类文件

| 文件 | 职责 |
|------|------|
| `FileNaming.swift` | 文件名清理（CJK 感知，120 字符限制，冲突避免） |
| `FileSystemUtilities.swift` | 图片/视频类型判断，修改日期辅助 |
| `RegexUtilities.swift` | 正则匹配辅助（firstMatch, firstCapture, allMatches） |
| `DownloaderInfra.swift` | 共享下载基础设施（进度聚合 actor，重试逻辑，curl 回退） |
| `DownloaderHTTPCompatibility.swift` | DNS-over-HTTPS 解析，curl 命令行回退，并发限制 |
| `PhotoLibraryImporter.swift` | 系统相册导入（Live Photo 对 + 独立媒体文件） |

---

## 数据流图

```
用户操作
  ├── 拖放文件 → ImporterModel.addFiles → rebuildPairs → 队列页显示
  ├── 点击合成 → ImporterModel.processPairs
  │       └── LivePhotoToolRunner.run (Process → tool CLI)
  │           └── tool.swift: extractAssetID, writeMakerNote, createCompatibleMOV
  │               └── PhotoLibraryImporter.importLivePhotoPair (可选)
  ├── 输入分享链接 → ImporterModel.downloadShare
  │       └── runSingleDownloader (平台路由)
  │           ├── DouyinNativeDownloader.run → dydl.swift
  │           │   ├── resolveURL → extractAwemeID
  │           │   ├── fetchAweme (Web API → Caches → Slides → Mobile Feed)
  │           │   └── download (并行下载)
  │           ├── XHSNativeDownloader.run → rndl.swift
  │           └── DewuNativeDownloader.run → dwdl.swift
  │               └── DewuLogStore (SQLite 日志读取)
  └── 刷新下载页 → ImporterModel.refreshDownloads
          └── downloadItems(in:excluding:) → 扫描下载文件夹 → 重建网格
```

---

## 构建配置

### Xcode 项目 (`HERMES.xcodeproj`)
- **目标**：Hermes (macOS App) + tool (Command Line Tool)
- **Swift Language Mode**：v6
- **最低部署目标**：macOS 26.0
- **链接框架**：AppKit, AVFoundation, CoreMedia, ImageIO, Photos, UniformTypeIdentifiers, libsqlite3

### SwiftPM (`Package.swift`)
- **目标**：HermesTool（仅包含 `tool.swift`）
- **用途**：独立构建 CLI 工具（开发/CI 使用）

### 构建脚本
- `build.sh` — 主构建脚本（xcodebuild Debug/Release）
- `script/build_and_run.sh` — 调试运行（支持 lldb/log/telemetry 模式）
- `script/package_app.sh` — Release 打包/安装

---

## 设计模式与约定

- **@MainActor ObservableObject**：ImporterModel 是整个应用的单例数据模型
- **enum 命名空间**：下载器使用无实例 enum（DouyinNativeDownloader, XHSNativeDownloader, DewuNativeDownloader）
- **NotificationCenter + Combine**：视图层通过 @Published 属性 + Notification 通信
- **Security-Scoped Bookmarks**：文件夹访问使用 `NSURL.bookmarkData` 持久化
- **Actor 并发**：下载进度聚合、缩略图加载限制使用 actor
- **渐进式扫描**：抖音下载器用多阶段回退策略保证最大媒体覆盖率

---

## 修改指南

| 场景 | 入口点 | 注意事项 |
|------|--------|----------|
| 修改抖音下载逻辑 | `dydl.swift` 的 `fetchAweme()` | 多源回退策略已有完整覆盖，新增源需添加评分逻辑 |
| 添加新平台下载器 | `Sources/` 新增文件 + `ImporterModel.runSingleDownloader` | 参考 dydl/rndl/dwdl 的模式 |
| 修改 UI 布局 | 对应 View 文件 | 缩略图大小在 `ThumbnailCollectionStyle` |
| 添加新的 UserDefaults 持久化 | `ImporterModel` | 遵循现有 Key 命名约定 |
| 修改支持的图片/视频格式 | `FileSystemUtilities.isImage/isVideo` | 同时检查 tool.swift 的格式处理 |
| 添加新菜单命令 | `HermesAppDelegate` 中 `.commands {}` | 使用 NotificationCenter 或直接调用 model 方法 |

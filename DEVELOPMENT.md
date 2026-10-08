# HERMES 小改动开发

版本 1.0；更新日期：2026-10-07。

变更摘要：建立功能入口与测试导航，提供专项与最终补充检查、独立 Debug 增量构建和构建计时；共享回归保留增量中间产物；记录逐步抽出职责的约定。

## 功能定位

先从用户看到的行为找到入口，再沿表中的共享依赖检查影响范围。文件移动、职责变化或新增测试时，同步更新本表和 `script/change_checks.py` 的映射。

| 功能或现象 | 主要入口 | 共享依赖与检查范围 | 现有验证入口 |
| --- | --- | --- | --- |
| 启动、退出、应用菜单 | `Sources/HermesApp.swift` | `ImporterModel`、主窗口、工具栏；退出还涉及取消和记录落盘 | 模型及 UI/UX 回归 |
| 主窗口、侧栏、页面切换、设置 | `Sources/Views/Other/MainWindowController.swift`、`Sources/SidebarController.swift`、`Sources/Views/Other/PageControllers.swift`、`Sources/SettingsWindow.swift` | 模型状态、选择、工具栏、检查器生命周期 | UI/UX 回归；修改设置持久化时补模型回归 |
| 下载输入、进度覆盖层、结果提示 | `Sources/DownloadViews.swift` | 页面布局、输入高度、模型进度、集合视图；只改呈现不必自动扩大为平台下载回归 | `script/test_window_layout.py`、UI/UX 回归 |
| 集合布局、滚动、选择、拖出、删除 | `Sources/Views/CollectionViews/ThumbnailGridController.swift`、`ThumbnailGridArrangementController.swift` | 单元格、媒体身份、文件操作；与系统 AppKit 行为核对 | `HermesLayoutTests`；最终候选补 UI/UX 回归 |
| 缩略图缩放、焦点、叠化、角标恢复 | `Sources/Views/CollectionViews/ThumbnailGridZoomController.swift`、`ThumbnailZoomGeometry.swift`、`ThumbnailZoomOverlay.swift` | 六个相邻方向、边界、交接、位图身份、单元格角标 | `HermesLayoutTests`；最终候选补 UI/UX 回归 |
| 缩略图加载、缓存、单元格、合成效果 | `Sources/Views/Thumbnail/` | 系统缩略图、异步图像身份、复用、拖出、缩放交接 | `HermesLayoutTests`；最终候选补 UI/UX 回归 |
| 下载、队列、已完成页面的媒体映射 | `Sources/Views/CollectionViews/DownloadCollectionView.swift`、`PairCollectionView.swift`、`CompletedCollectionView.swift` | `UIModels`、准确配对身份、原生资源动作、共享网格 | 布局、UI/UX、原生媒体回归 |
| 检查器、媒体信息、地图位置卡 | `Sources/Views/Other/MediaInspectorController.swift`、`MediaLocationCard.swift`、`Sources/Utilities/MediaInspection.swift` | 元数据读取、坐标、迟到异步结果、宽度和可见性 | `LocationCardTests`、UI/UX、原生媒体回归 |
| 队列、合成、历史记录、筛选、文件监控、目录迁移 | `Sources/Models/ImporterModel.swift` | 跨页面状态、文件读写、记录生命周期；按共享模型变更处理 | 模型、UI/UX、原生媒体回归；最终候选补下载、合成与元数据检查 |
| 抖音、小红书、得物的解析和下载 | `Sources/dydl.swift`、`rndl.swift`、`dwdl.swift`、`DewuLogStore.swift` | 云端原始来源、准确资源身份、兼容网络、取消、媒体验证 | 网络、下载、来源归属回归；最终候选补应用及合成、元数据检查 |
| 网络兼容、子进程、恢复策略 | `Sources/DownloaderHTTPCompatibility.swift`、`Sources/Utilities/DownloaderNetworkPolicy.swift`、`SubprocessRunner.swift`、`DouyinSourceResolver.swift`、`DewuDownloadRecoveryPolicy.swift`、`DewuPlaybackLogVideoExtractor.swift` | 同时被平台下载和测试使用 | `HermesNetworkingTests`、下载回归 |
| Live Photo 合成、配对和元数据 | `Sources/tool.swift`、`Sources/LivePhotoToolRunner.swift` | 媒体字节、标识符、方向、音轨、输出事务 | helper 构建、合成安全、元数据安全；调用侧补应用回归 |
| 导入照片、复制和原生媒体动作 | `Sources/PhotoLibraryImporter.swift`、`Sources/Utilities/NativeMediaResources.swift` | 原生资源身份、导入设置、合成准备；夹具测试不写用户图库 | 应用回归；最终候选按影响补合成检查 |
| 文件、命名、来源、缓存音频等公共工具 | `Sources/Utilities/FileSystemUtilities.swift`、`FileNaming.swift`、`MediaFileUtilities.swift`、`DownloaderInfra.swift`、`XHSCachedMotionReader.swift`、`XHSLivePhotoAudioRecovery.swift` 等 | 多个下载器、模型或媒体路径共享，不能只按文件名判断为局部修改 | 布局、网络、应用、下载、来源回归；最终候选补合成及元数据检查 |
| 构建、安装、版本、测试缓存 | `build.sh`、`script/project_config.sh`、`package_app.sh`、`versioning.sh`、`app_regression.py` | 缓存、运行中应用保护、事务回滚；仅在隔离夹具中测试安装流程 | 构建安全、版本、安全缓存及开发工具测试 |

## 日常小改动

1. 复现问题，确定功能入口和用户可观察的预期行为。
2. 只修改相关职责；查看快速检查计划，运行对应专项。
3. 需要真实窗口时构建 Debug 候选；布局和外观可先使用共享组件 Demo。
4. 修改稳定后运行最终候选的相关检查；相同内容的已通过结果不因提交或推送重跑。
5. 需要交付应用时直接用现有打包入口构建并安装 Release，避免提前再构建一次 Release。

```bash
# 默认只查看工作区改动的检查计划，包括暂存、未暂存和未忽略的新文件。
python3 script/check_change.py

# 运行当前改动的专项检查；完成后打印每项和总耗时。
python3 script/check_change.py --run

# 查看分支相对 main 的累计改动，包含当前尚未提交的内容。
python3 script/check_change.py --base main

# 最终候选：按同一影响范围补充集成检查，不扩大到无关功能。
python3 script/check_change.py --base main --final --run

# 同一交付中专项已通过，且源码、测试、依赖、配置、工具链未变：只运行补充项。
python3 script/check_change.py --base main --final-only --run

# 也可明确指定功能文件，不依赖 Git 当前是否有未提交改动。
python3 script/check_change.py Sources/Views/CollectionViews/ThumbnailGridZoomController.swift --run
```

入口打印变更文件、选择原因、实际命令和最终候选需要补充的检查。未知代码、共享模型、公共文件或媒体工具采用较宽的检查；重命名同时考虑旧、新路径，避免漏掉原功能。执行失败立即停止，并保留失败状态；中断时停止这一轮创建的进程组。`--final-only` 不缓存或推断旧测试结果，调用者需确认已有结果适用于当前内容；未知代码拒绝这种模式。它不会自动下载真实平台样本、写用户照片图库、安装或发布应用；真实样本验收仍按当前任务的授权执行。

缩放、几何、排列、单元格和图片缓存各有对应的测试组，日常修改只运行相关组；最终候选补完整布局和实际主窗口检查。`--final-only` 用 `--skip` 跳过已经通过且内容未变的相关组。明确修改某个现有布局测试文件时，仅运行该测试类；新增或未映射的应用文件扩大编译与检查范围。

`swift test --filter` 缩小的是测试执行范围；SwiftPM 仍可能构建其他测试目标。应用模型、UI/UX、原生媒体回归继续使用既有共享缓存，一次调用只编译一次，三个测试各自隔离执行。

## Debug 构建与预览

```bash
# 独立于其他工作树和 Release 安装的 Debug 构建，只构建，不启动。
python3 script/dev_build.py

# 打印 Xcode 构建阶段计时，用于比较首次与后续增量构建。
python3 script/dev_build.py --timing

# 构建成功后启动；已有 HERMES 正在运行时保留它，打印新应用路径。
python3 script/dev_build.py --run

# 位置卡使用与正式应用相同的组件。
./Demos/LocationCard/build.command

# 缩放 Demo 共用几何和输入逻辑；呈现与正式应用仍有差异。
./Demos/ThumbnailZoom/build.command
```

默认 Debug 缓存位于本工作树 `.build/development/DerivedData`，产品目录固定，便于增量编译；只保留一份当前 Debug 产品。构建加锁，拒绝覆盖这个目录中正在运行的 HERMES。不同工作树各自独立，已有的 `HERMES_DERIVED_DATA_DIR` 和 `HERMES_PRODUCTS_DIR` 自定义路径仍被尊重，自定义产品不自动清理。

当前工作树 Release 安装成功后，现有安装脚本会清理默认开发目录中的闲置应用产品，并保留编译缓存。运行中的应用、正在构建的目录、自定义或链接的输出目录继续保留；此清理只针对当前工作树。

Demo 能加快局部确认，不能替代真实主窗口的布局、手势、交接和交互验收。Debug 候选不代表 `/Applications/HERMES.app` 已更新。

## 编译范围优化

先记录实际构建、专项测试和应用回归的耗时，再根据最慢阶段决定是否调整模块。日常修改先使用现有 `HermesThumbnailUI`、`HermesNetworking` 和专项入口。

共享应用回归仍为一套程序，由 `script/regression_compilation.py` 保留当前源码快照、对象文件及 Swift 依赖记录。内容变化时，由 Swift 增量编译判断受影响文件，再链接当前程序；内容相同仍直接复用已校验的程序。源文件集合、工具链或编译配置变化时重建中间缓存；中间产物也有内容校验，失败和中断会清除中间状态并保留上一份成功程序。测试结果不缓存，三套回归继续各自使用独立进程、偏好域和临时目录。

仅增加源文件不会自动缩小模块编译范围。新增 target 也会增加依赖与维护成本；需要计时证明收益后，再按明确职责拆分。现有三套应用回归的隔离、失效条件和跨工作树复用保持有效。

本次本地计时（同一工作树与工具链；单次测量）：

| 场景 | 时间与范围 |
| --- | --- |
| Debug 首次构建 / 同源码再次构建 | 17.10 秒 / 1.45 秒；再次构建没有 Swift 源码编译任务 |
| 原共享回归首次编译 | 253.79 秒 |
| 增量方式的共享回归首次编译 / 同源码缓存命中 | 221.79 秒 / 0.17 秒 |
| 隔离副本修改 `SidebarSection.title` 的一个返回字符串 | 5.44 秒，52 个源文件中只有 `UIModels.swift` 对象内容变化；正式源码未改 |
| 缩放相关专项 / 最终补充的剩余布局测试 | 61 项约 13.60 秒 / 44 项约 29.34 秒；两组覆盖 105 项且不重复执行 |

首次编译仍较慢；接口、依赖、文件集合或工具链变化时，Swift 可能扩大重编范围。上表的测试时间只计测试执行，编译时间另计。模型 58 项、UI/UX 18 组、原生媒体 27 项在新编译方式下通过。

## 逐步抽出职责

- 以后修 bug 或增加功能时，先判断大文件内是否已有可独立的相关职责；在本次改动能验证的范围内抽成组件，再实现功能。
- 新职责放入职责明确的组件，通过小接口与现有模型连接；避免继续把不同功能堆入 `ImporterModel.swift` 或平台下载器。
- 不为减少行数拆文件，不在无关修复中顺带重构，不一次性重写整个项目。
- 保留已确认的状态、媒体身份、来源、顺序、动画、交互及 UI；抽出前后的行为使用相关现有测试和真实场景核对。

构建与模块优化参考：[Apple：Improving the speed of incremental builds](https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds)。

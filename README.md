# Hermes

## 1.7 / 0608：审计修复（2026-09-16）

基准提交：`02e0dafb65ab52e500fd17a43174e730667328c9`。本轮修复审计报告中的 P1-01、P1-02 和 P2-01 至 P2-05：

- 刷新只扫描，不再自动清理任何下载子目录，包括空目录。
- 导出扫描失败保留历史及导入标记并提示；启动时媒体暂不可访问不撤销导入状态；成功空扫描仍按实际文件更新列表。
- 下载进度按任务 ID 隔离；同一任务内保留防倒退规则。
- 旧目录扫描过期后继续扫描最新目录，支持连续切换。
- 开始页和下载页共用同目录同名唯一配对规则，歧义素材保留为未配对项。
- 菜单、Command+Return 和工具栏共用当前页面合成命令及启用条件；已完成页不能触发隐藏队列。
- 删除确认明确只移走下载源文件，保留合成导出文件。

平台解析器、网络与 HDR 处理、下载队列执行、合成子进程和退出行为保持不变。Git 取消跟踪 87 个旧构建产物，本地副本保留；`Build/Info.plist`、`Build/Assets` 仍是受跟踪的构建输入。

验证与应用状态：35 项模型安全场景、23 项 SwiftPM 测试（19 项网络 + 4 项界面）和 4 项真实合成工具安全场景通过；Release 构建及签名校验通过。已在应用未运行时安装到 `/Applications/HERMES.app`，版本 1.7 / 0608，签名团队 `FJP7ATDRW3`。安装前后 `CompletedRecords.v1` 83 条、`DownloadCompletedRecords.v1` 45 条的内容哈希均一致；应用未自动启动。

补充验证：同一导出目录通过符号链接访问时，归一化路径后仍需文件版本完全匹配才保留导入标记；文件被替换后会撤销旧标记。权限拒绝用注入错误验证；目录缺失与恢复、配对及目录切换使用真实临时文件；删除范围测试拦截文件操作，没有操作系统废纸篓。

验证日志在 `Build/Audit-0608/`（本地保留，不纳入 Git）。旧版与偏好备份：`/Users/long/Library/Application Support/HERMES/Backups/0607-before-0608-20260916-103633`。

模型回归不在 SwiftPM 测试目标内，必须单独运行：

```sh
swift test
python3 script/test_model_safety.py
# 参数指向本次构建的 tool，不使用历史构建产物：
python3 script/test_composition_safety.py /path/to/current/tool
./build.sh --release --no-run
```

本轮不包括子进程超时/取消、逐项提交合成结果、窗口关闭/退出策略与 GitHub Actions 环境部署。这些项目需要单独的生命周期设计和验收；没有宣称完整实网下载或真实照片图库导入已回归。

## 1.7 / 0607：筛选缩略图尺寸修复（2026-09-15）

缩略图按 148 点格子和窗口屏幕倍率请求，修复此前 512 点再乘倍率导致的过大图像。独立测试 App 对照确认主线程负担下降，保留原生筛选排列动画；不改变下载/合成逻辑或原始媒体。Release 构建和 HEIC/JPEG 的 1 倍/2 倍尺寸检查通过；已在空闲时替换正式安装为 0607，记录核验一致。

仅面向 macOS 27（Apple Silicon）。

Xcode macOS app project.

## Project Layout

- `HERMES.xcodeproj`: Xcode macOS app project.
- `Package.swift`: SwiftPM package definition for the `tool` CLI helper target.
- `Sources/HermesApp.swift`: macOS app entry point, menu bar.
- `Sources/Models/ImporterModel.swift`: Core data model, app state, download orchestration.
- `Sources/UIModels.swift`: Data type definitions (PairItem, CompletedItem, etc.).
- `Sources/tool.swift`: Helper tool that creates Live Photo resources (Apple-compatible metadata + MOV).
- `Sources/LivePhotoToolRunner.swift`: Process launcher for the tool CLI.
- `Sources/PhotoLibraryImporter.swift`: System Photos library import.
- `Sources/dydl.swift`: Douyin (TikTok) native downloader.
- `Sources/rndl.swift`: Xiaohongshu (RED) native downloader.
- `Sources/dwdl.swift`: Dewu native downloader.
- `Sources/DewuLogStore.swift`: Dewu app SQLite log reader.
- `Sources/DownloaderHTTPCompatibility.swift`: Network compatibility layer (DoH, curl fallback).
- `Sources/DownloadViews.swift`: Download bar UI and progress.
- `Sources/EmptyStateViews.swift`: Empty state and drop zone views.
- `Sources/SidebarController.swift`: Finder-style sidebar.
- `Sources/SettingsWindow.swift`: Settings window.
- `Sources/Views/`: View controllers, collection views, thumbnail system.
- `Sources/Utilities/`: Shared utilities (FileNaming, Regex, HTTP infra).
- `Build/Info.plist`: App bundle metadata.
- `Build/Assets/AppIcon.icon`: App icon source.
- `script/build_and_run.sh`: Debug run/debug/log helper.
- `script/package_app.sh`: Xcode Release packaging script.
- `build.sh`: Main build script (Debug build + launch by default).

## Build

Run from this directory:

```sh
./build.sh
```

The build script uses Debug configuration by default, builds the `Hermes` scheme with Xcode, and opens the app. Use `--release` for Release config, `--no-run` to skip launching, or `--clean` to clean first.

Alternatively:

```sh
./script/build_and_run.sh
```

The run script delegates its build step to `build.sh`, then opens the debug app
or attaches logs/debug tooling depending on the selected mode.

## 更新说明

- 2026-09-15（1.7 / 0606，已安装）: 按原设计恢复下载页、已完成页筛选时的系统原生缩略图排列动画，继续遵循系统“减少动态效果”。保留 0605 的列表快照优化和历史记录保护。筛选体验以系统“照片”App 的自然缩略图过渡为参考，不通过关闭排列动画处理性能问题。

- 2026-09-15（1.7 / 0605，已安装）: 修复刷新清除旧格式合成历史的迁移缺陷，恢复本机 45 组已核验源关联，保留 83 条已完成记录与 57 条已导入状态。原生筛选复用列表快照并取消整批切换动画，刷新和实际合成仍验证文件版本。25 项模型回归通过，Release 签名、安装及刷新后记录保持已验证。

- 2026-09-15（1.7 / 0604，已安装）: 包含 0603 功能修复及本轮非下载维护：玻璃控件使用公开 API、本地文件扫描后台执行并防止清空后旧结果回填、合成工具及时读取日志以避免管道阻塞、缩略图重复回退清理。下载解析、网络策略、HEVC/Live Photo 媒体兼容代码未在本轮修改。Release 签名与安装校验通过，已启动 `/Applications/HERMES.app`；旧安装版 0602 备份到 `Build/PreviousInstalled-0602.app`。

- 2026-09-15（1.7 / 0603，修复版待安装）: 按授权分两批修复功能审计的 1、3、6、8、4、5，以及随后单独处理的 2。合成先在独立临时目录完成，同名输出自动追加序号并保留既有文件；异步导入按项目 ID 回写状态；成组文件移到废纸篓失败时回滚并保留记录；下载失败详情保留为可查看提示；配对限制为同目录唯一同名；完成记录关联具体来源和文件版本。目录迁移仅在相关任务空闲时执行，预检冲突、同步关联路径及选择状态，失败时回滚并报告实际文件位置。三个平台的解析、网络请求、资源选择、备用顺序未修改。修复版独立构建，不覆盖正在运行的 App。

  旧记录兼容：既有导入状态仅在具体输出文件与记录时间一致时迁移；无法确认来源的旧下载合成记录不再按同名素材自动关联，可能需要重新确认。文件版本使用文件标识、大小及修改/创建时间，不进行大视频全文哈希。

- 2026-09-15（1.7 / 0602）: 统一按钮、悬停提示、设置、右键菜单、输入说明和辅助功能状态文案；区分自动设置与立即操作、移除记录与移走文件，合成提示随选择范围变化，全部媒体筛选改为“全部项目”。仅修改 UI 文案及其显示范围；Release 安装和签名核验通过，确认弹窗实测后取消，未移除记录或文件。

- 2026-09-15（1.7 / 0601）: 工具栏默认仅显示图标；“显示”菜单可切换工具栏文字并打开自定义面板。包含本轮 UI 辅助功能和材质修复。Release 编译、签名和安装文件一致性检查通过，已安装到 `/Applications/HERMES.app`，菜单显隐经实测并恢复仅图标。

- 2026-09-15（UI 核验修订 1）: 补齐下载输入框、缩略图、进度条的辅助功能语义；工具栏开关使用原生状态控件，并支持按页面保存系统工具栏自定义配置；失败提示与选择状态独立；进度内容使用标准材质并响应减少动态效果。仅修改 UI 层；独立副本验证，未替换已安装 App。详见 `docs/UI审计.md`。

- 2026-09-15（1.7 / 0600）: “关于”面板补充作者“九尾大人”及个人版权信息；版本和构建号继续自动读取。

- 2026-09-15（1.7 / 0599）: 完善原生“关于”面板，展示应用图标、名称、自动读取的版本与构建号、用途、主要功能、系统和芯片要求，以及文件保存说明。

- 2026-09-15（1.7 / 0598）: 将本次抖音免缓存高清源下载升级作为 1.7 发布；包含此前的下载兼容、窗口布局和 Cookie 残留清理修复。版本约定：重大功能更新递增 0.1，日常修复递增构建号。

- 2026-09-15（1.6 / 0597）: 抖音普通视频新增免桌面缓存的源视频探测：使用接口返回的视频 URI 请求源地址，再通过少量 Range 请求读取 MP4 视频轨尺寸；只有实际分辨率更高才替换普通流。支持 4 GB 以上 MP4 的扩展长度，拒绝不支持 Range 或异常元数据的响应；探测或下载失败保留原有备用方式。延长大视频下载时限。指定测试视频源头信息已验证为 2560×1440、60 fps、1695.65 秒、含音轨，完整源大小 4,552,212,113 字节；普通接口此前仅下载到 1280×720。

- 2026-09-15（1.6 / 0596）: 构建产物使用独立目录，构建、调试、打包不再强制退出 App；运行中拒绝清理和覆盖安装。小红书与抖音页面请求统一验证 HTTP 状态并执行兼容兜底。抖音子进程和 curl 使用文件捕获输出并设置超时，避免管道阻塞；修正 curl 配置隔离参数顺序。

- 2026-09-15（1.6 / 0595）: 移除手动 Cookie 输入、保存、验证、请求传递及菜单入口，并在启动时清理旧保存值；统一最低系统为 macOS 27；修复缩略图网格不随窗口宽度变化、长状态文字撑大窗口，以及同路径文件更新后缩略图不刷新的问题。增加布局与缩略图更新回归检查，共 10 项检查通过；40 张测试缩略图上追加指定小红书链接下载成功。

- 2026-09-15（1.6 / 0594）: 恢复 App 入口编译引用；新增小红书 `xhslink.cn` 分享链接识别、平台路由与短链解析；修复模型变化后正文页面未刷新的问题。保留既有 `xhslink.com` 支持和已安装 App 的标识。macOS 27 上指定链接已下载 HEIC 原图与伴随视频，8 项网络策略测试通过。

- 2026-06-30: 得物混合图文帖下载时，静态图失败不再阻断后续 Live Photo 视频解析和下载。
- 2026-06-30: 修复得物 Live Photo 下载在详情接口无视频时过早停止的问题，继续读取 App 播放日志补齐伴随视频。
- 2026-06-30: 下载网络层新增直连策略，禁用系统代理配置，过滤 DoH 假 IP/内网 IP，并在受保护域名 404 时走兼容解析兜底。
- 2026-06-30: 缩略图取消 HERMES 自己的成功/失败缓存，改为每次请求 Quick Look 系统缩略图结果。
- 2026-06-30: 收紧原生 UI 边界，统一由窗口层管理选择面板和确认弹窗，模型层只处理已选择的路径。
- 2026-06-30: 统一窗口标题栏、工具栏和页面正文背景，由 AppKit 系统背景控制器集中配置。
- 2026-06-30: 删除缩略图页自定义滚动保存、恢复、回顶和边界控制，改回 NSScrollView 系统原生滚动。
- 2026-06-30: 修复缩略图页面初始叠层，开始页不再露出下载/已完成页缩略图，并在切页内容刷新后再恢复滚动位置。
- 2026-06-30: 缩略图网格重写为 Quick Look 系统缩略图、AppKit diffable 数据源和三页共用滚动控制。
- 2026-06-30: 删除缩略图列表的页面切换滚动保存/恢复逻辑，只保留明确请求时的 AppKit 原生同步回到顶部。
- 2026-06-30: 缩略图列表的刷新补上同 ID 内容变更的 cell reload，避免状态更新后仍显示旧缩略图。
- 2026-06-29: 缩略图选中和失败状态改为图片外侧的 AppKit 风格状态环，取消旧的图片图层自定义描边。
- 2026-06-29: 恢复侧边栏顶部靠右的系统原生隐藏边栏按钮，并跟随侧边栏分隔线定位。
- 2026-06-29: 下载进度堆叠动画改为主条淡出下移，后续条目依次推进补位。
- 2026-06-29: 下载任务完成后，进度条会先显示到 100%，再按原有动画消失。

## Package

Run from this directory:

```sh
./script/package_app.sh
```

If HERMES is running, packaging builds a new copy but skips installation to protect current downloads. Quit the app before installing.

The packaging script increments `CURRENT_PROJECT_VERSION` in the Xcode project,
builds the `Hermes` scheme with Xcode Release configuration, stages
`Build/HERMES.app`, atomically replaces `/Applications/HERMES.app`, and opens
the installed copy. Use
`--no-version-bump` or `--no-open` when needed. Set `HERMES_INSTALL_DIR` to
override the installation directory.

## 回归检查

```sh
swift test
python3 script/test_window_layout.py
python3 script/test_build_safety.py
python3 script/test_composition_safety.py
python3 script/test_model_safety.py
```

窗口检查使用离屏测试窗口验证长状态文字不会改变窗口尺寸，不启动安装的 App。

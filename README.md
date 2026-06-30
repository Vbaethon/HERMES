# Hermes

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

The packaging script increments `CURRENT_PROJECT_VERSION` in the Xcode project,
builds the `Hermes` scheme with Xcode Release configuration, stages
`Build/HERMES.app`, atomically replaces `/Applications/HERMES.app`, and opens
the installed copy. Use
`--no-version-bump` or `--no-open` when needed. Set `HERMES_INSTALL_DIR` to
override the installation directory.

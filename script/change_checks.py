"""Map HERMES responsibilities to existing checks; unknown code widens coverage."""
from dataclasses import dataclass
from fnmatch import fnmatchcase


APP = ("model", "uiux", "native")
MEDIA = ("tool", "composition", "metadata")
SHARED = ("layout", "network", *APP, "download", "attribution")
ALL = (*SHARED, *MEDIA, "build", "version", "cache", "development", "debug")
LAYOUT_GROUPS = {
    "location": ("LocationCardTests",),
    "zoom": ("ThumbnailZoomTests", "ThumbnailZoomArtworkTests", "ThumbnailPointerGeometryTests",
             "ThumbnailBadgeRenderingTests", "ThumbnailScrollAnchorTests", "ThumbnailPerformanceTests"),
    "geometry": ("ThumbnailLayoutTests", "ThumbnailPointerGeometryTests", "ThumbnailZoomArtworkTests", "ThumbnailZoomTests"),
    "arrangement": ("ThumbnailArrangementTests", "ThumbnailLayoutTests", "ThumbnailScrollAnchorTests", "ThumbnailZoomTests"),
    "items": ("ThumbnailSelectionTests", "ThumbnailDragTests", "ThumbnailAccessibilityTests", "ThumbnailDeletionTests",
              "ThumbnailBadgeRenderingTests", "ThumbnailZoomArtworkTests", "ThumbnailZoomTests"),
    "images": ("ThumbnailPerformanceTests", "ThumbnailZoomArtworkTests", "ThumbnailZoomTests"),
}
LAYOUT_CASES = tuple(sorted({case for cases in LAYOUT_GROUPS.values() for case in cases}))
LAYOUT_GROUPS.update({"test:" + case: (case,) for case in LAYOUT_CASES})


@dataclass(frozen=True)
class Rule:
    paths: tuple[str, ...]
    reason: str
    quick: tuple[str, ...]
    final: tuple[str, ...] = ()


RULES = tuple(Rule((f"Tests/HermesLayoutTests/{case}.swift",), f"{case} 测试自身", ("test:" + case,))
              for case in LAYOUT_CASES) + (
    Rule(("script/check_change.py", "script/change_checks.py", "script/test_development_workflow.py",
          "script/dev_build.py", ".gitignore"), "开发检查或 Debug 构建入口", ("development",)),
    Rule(("build.sh", "script/project_config.sh", "script/build_and_run.sh", "script/package_app.sh",
          "script/test_build_safety.py"), "构建与安装保护", ("build", "development")),
    Rule(("script/versioning.sh", "script/test_versioning.sh"), "应用版本规则", ("version",)),
    Rule(("HERMES.xcodeproj/*", "Package.swift", "Build/Info.plist", "Build/Assets/*"),
         "构建配置、目标依赖或应用资源", ("build", "version", "cache", "layout", "network", "debug"), APP),
    Rule(("script/app_regression.py", "script/regression_compilation.py", "script/AppRegressionMain.swift", "script/test_app_regressions.py"),
         "共享回归编译与执行入口", ("cache", *APP)),
    Rule(("script/test_app_regression_cache.py",), "编译缓存失效及隔离", ("cache",)),
    Rule(("Tests/HermesLayoutTests/*",), "布局测试自身", ("layout",)),
    Rule(("Tests/HermesNetworkingTests/*",), "网络测试自身", ("network",)),
    Rule(("Tests/HermesModelRegression/*", "script/test_model_safety.py"), "模型回归自身", ("model",)),
    Rule(("Tests/HermesUIUXRegression/*", "script/test_uiux.py"), "UI/UX 回归自身", ("uiux",)),
    Rule(("Tests/HermesNativeMediaRegression/*", "script/test_native_media.py"), "原生媒体回归自身", ("native",)),
    Rule(("Tests/DownloadRegression/*", "script/test_download_regression.sh"), "下载与取消回归自身", ("download",)),
    Rule(("Tests/MediaAttributionRegression/*", "script/test_media_attribution.py"), "媒体来源归属回归自身", ("attribution",)),
    Rule(("script/test_composition_safety.py",), "合成安全回归自身", ("tool", "composition")),
    Rule(("script/test_tool_metadata_safety.py",), "元数据安全回归自身", ("metadata",)),
    Rule(("script/test_window_layout.py",), "进度和窗口布局回归自身", ("window",)),
    Rule(("script/benchmark_thumbnail_*",), "缩略图性能探针", ("layout",)),
    Rule(("script/benchmark_window_animation*",), "窗口动画性能探针", ("uiux",)),
    Rule(("script/preview_composition.swift",), "合成预览夹具", ("tool", "composition")),
    Rule(("Demos/LocationCard/*",), "位置卡共享组件 Demo", ("location", "demo-location"), ("uiux", "native")),
    Rule(("Demos/ThumbnailZoom/*",), "缩放共享几何 Demo", ("layout", "demo-zoom"), ("uiux",)),
    Rule(("Sources/Models/ImporterModel.swift", "Sources/HermesApp.swift"),
         "共享模型、队列、记录或应用生命周期", APP, ("download", *MEDIA)),
    Rule(("Sources/UIModels.swift",), "跨页面和下载器共享的媒体模型", SHARED, MEDIA),
    Rule(("Sources/Views/CollectionViews/ThumbnailGridController.swift",),
         "共享网格、选择、滚动和资源身份", ("layout",), ("uiux",)),
    Rule(("Sources/Views/CollectionViews/ThumbnailGridArrangementController.swift",),
         "网格排列、滚动锚点与缩放布局", ("arrangement",), ("layout", "uiux")),
    Rule(("Sources/Views/CollectionViews/ThumbnailGridZoomController.swift",
          "Sources/Views/CollectionViews/ThumbnailZoomOverlay.swift"),
         "缩放、叠化、角标、交接和性能专项", ("zoom",), ("layout", "uiux")),
    Rule(("Sources/Views/CollectionViews/ThumbnailZoomGeometry.swift",),
         "缩放几何、指针焦点和像素混合专项", ("geometry",), ("layout", "uiux")),
    Rule(("Sources/Views/Thumbnail/ThumbnailItemViews.swift", "Sources/Views/Thumbnail/ThumbnailCompositionEffect.swift"),
         "单元格选择、拖出、删除、角标及缩放专项", ("items",), ("layout", "uiux")),
    Rule(("Sources/Views/Thumbnail/ThumbnailService.swift", "Sources/Views/Thumbnail/SystemThumbnailProvider.swift"),
         "缩略图缓存、位图身份和缩放性能专项", ("images",), ("layout", "uiux")),
    Rule(("Sources/Views/CollectionViews/DownloadCollectionView.swift",
          "Sources/Views/CollectionViews/PairCollectionView.swift",
          "Sources/Views/CollectionViews/CompletedCollectionView.swift"),
         "页面媒体映射与原生资源动作", ("layout", "uiux", "native")),
    Rule(("Sources/Views/Other/MediaLocationCard.swift",),
         "地图位置卡布局和异步状态", ("location",), ("uiux", "native")),
    Rule(("Sources/Views/Other/MediaInspectorController.swift", "Sources/Utilities/MediaInspection.swift"),
         "检查器、元数据读取和位置状态", ("location", "uiux", "native")),
    Rule(("Sources/DownloadViews.swift", "Sources/EmptyStateViews.swift"),
         "输入、进度呈现和真实页面布局", ("window", "uiux")),
    Rule(("Sources/SettingsWindow.swift",), "设置及持久化状态", ("model", "uiux")),
    Rule(("Sources/SidebarController.swift", "Sources/Views/Other/MainWindowController.swift",
          "Sources/Views/Other/PageControllers.swift", "Sources/Views/Other/SystemWindowBackgroundController.swift"),
         "主窗口、页面、侧栏或系统背景", ("uiux",)),
    Rule(("Sources/Views/Other/NativeWindowToolbarController.swift", "Sources/Views/Other/NativePanelPresenter.swift"),
         "工具栏、面板和原生资源动作", ("uiux", "native")),
    Rule(("Sources/dydl.swift", "Sources/rndl.swift", "Sources/dwdl.swift", "Sources/DewuLogStore.swift"),
         "平台下载、原始来源、媒体验证和取消", ("network", "download", "attribution"), (*APP, *MEDIA)),
    Rule(("Sources/DownloaderHTTPCompatibility.swift", "Sources/Utilities/SubprocessRunner.swift",
          "Sources/Utilities/DouyinSourceResolver.swift", "Sources/Utilities/DewuDownloadRecoveryPolicy.swift",
          "Sources/Utilities/DewuPlaybackLogVideoExtractor.swift", "Sources/Utilities/DownloaderNetworkPolicy.swift"),
         "共享网络、恢复或子进程策略", ("network", "download"), APP),
    Rule(("Sources/tool.swift",), "合成 helper、配对、媒体字节或元数据", MEDIA),
    Rule(("Sources/LivePhotoToolRunner.swift", "Sources/PhotoLibraryImporter.swift"),
         "helper 调用或照片导入生命周期", (*APP, *MEDIA)),
    Rule(("Sources/Utilities/NativeMediaResources.swift",), "原生媒体导出和准确资源身份", ("layout", "native", "uiux")),
    Rule(("Sources/Utilities/*.swift",), "跨功能共享文件、媒体或下载工具", SHARED, MEDIA),
)


@dataclass(frozen=True)
class Plan:
    paths: tuple[str, ...]
    reasons: tuple[tuple[str, str], ...]
    checks: frozenset[str]
    final_extra: frozenset[str]
    unknown: tuple[str, ...]
    previously_checked: frozenset[str] = frozenset()


def collapse_layout(checks):
    if "layout" in checks:
        checks.difference_update(LAYOUT_GROUPS)


def make_plan(paths, *, final=False):
    selected, additional, reasons, unknown = set(), set(), [], []
    paths = tuple(sorted(set(paths)))
    for path in paths:
        # Prose never needs an app build, including Demo readmes and findings.
        if path.endswith((".md", ".txt")):
            reasons.append((path, "文档或说明；检查差异与格式"))
            continue
        rule = next((rule for rule in RULES if any(fnmatchcase(path, pattern) for pattern in rule.paths)), None)
        if rule is None:
            unknown.append(path)
            selected.update(ALL)
            reasons.append((path, "未映射路径；扩大为全部离线相关检查"))
        else:
            selected.update(rule.quick)
            additional.update(rule.final)
            reasons.append((path, rule.reason))
    collapse_layout(selected)
    extra = additional - selected
    if final:
        selected.update(extra)
        collapse_layout(selected)
        extra = set()
    return Plan(paths, tuple(reasons), frozenset(selected), frozenset(extra), tuple(unknown))


def commands(checks, python, *, previously_checked=()):
    """Group app suites and remove overlapping Swift test execution."""
    checks = set(checks)
    result = []
    for key, script in (("development", "test_development_workflow.py"), ("cache", "test_app_regression_cache.py"),
                        ("build", "test_build_safety.py"), ("version", "test_versioning.sh")):
        if key in checks:
            executable = "/bin/bash" if script.endswith(".sh") else python
            result.append((key, (executable, f"script/{script}")))
    filters = []
    if "layout" in checks:
        filters.append("HermesLayoutTests")
    else:
        cases = sorted({case for key in checks.intersection(LAYOUT_GROUPS) for case in LAYOUT_GROUPS[key]})
        if cases:
            filters.append("HermesLayoutTests\\.(" + "|".join(cases) + ")")
    if "network" in checks:
        filters.append("HermesNetworkingTests")
    if filters:
        arguments = ["xcrun", "swift", "test", "--filter", "|".join(filters)]
        if "layout" in checks:
            passed = sorted({case for key in set(previously_checked).intersection(LAYOUT_GROUPS) for case in LAYOUT_GROUPS[key]})
            if passed:
                arguments += ["--skip", "HermesLayoutTests\\.(" + "|".join(passed) + ")"]
        result.append(("swift", tuple(arguments)))
    if "tool" in checks or "composition" in checks:
        result.append(("tool", ("xcrun", "swift", "build", "--product", "tool")))
    suites = tuple(suite for suite in APP if suite in checks)
    if suites:
        result.append(("app", (python, "script/test_app_regressions.py", *suites)))
    for key, folder in (("demo-location", "LocationCard"), ("demo-zoom", "ThumbnailZoom")):
        if key in checks:
            result.append((key, ("/bin/zsh", f"Demos/{folder}/build.command", "--test")))
    for key, script in (("window", "test_window_layout.py"), ("download", "test_download_regression.sh"),
                        ("attribution", "test_media_attribution.py"), ("composition", "test_composition_safety.py"),
                        ("metadata", "test_tool_metadata_safety.py"), ("debug", "dev_build.py")):
        if key in checks:
            executable = "/bin/bash" if script.endswith(".sh") else python
            result.append((key, (executable, f"script/{script}")))
    return tuple(result)

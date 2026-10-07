# HERMES 位置卡片 Demo

版本 1.1；修改日期 2026-10-07。变更摘要：按用户后续授权接入正式信息栏；Demo 与安装版共用 MediaLocationCard，增加隐藏取消/恢复与重复刷新保护。

## 官方依据与判断

- [Apple：在 iPhone 上查看照片和视频信息（iOS 26）](https://support.apple.com/zh-cn/guide/iphone/iph0edb9c18f/26/ios/26)：官方照片信息示例中，地图底下的地点文字与地图属于一个圆角区域；文档也说明地图/地址链接可以在“地图”中查看地点。这是截图观察，不是 HIG 规定的唯一布局。
- [Apple HIG：Maps](https://developer.apple.com/design/human-interface-guidelines/maps)：地点详情应保留地图位置上下文、适应窗口大小、避免重复信息。公开 place card 是地图选择附件/弹窗/面板，不能直接等同于照片信息区域中的常驻小卡片。
- [MKReverseGeocodingRequest](https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest)：将当前坐标查询为地点。
- [MKAddressRepresentations](https://developer.apple.com/documentation/mapkit/mkaddressrepresentations)：使用 Apple 系统生成的区域地址格式，不自行拼接国家、省、市、街道。

地图使用系统 MKMapView 和 MKMarkerAnnotationView；文字、按钮、字体、颜色、换行使用 AppKit。卡片组合布局由 Demo 实现，未使用照片的私有框架，也不声称是苹果照片原版控件。圆角沿用现有 HERMES 的 10 点、地图沿用 180 点高度，正式应用原有的位置章节保持作为集成目标。

## 可检查的行为

- 地图上方、地点名称/地址下方，外层仅一个圆角容器；底部使用 AppKit 大区域分组语义填充色，深浅外观均保持视觉绑定，不在其他章节重复放置地址，不遮挡系统地图署名。
- 地点与地址完全来自 Apple 反向地理编码的同一次响应；中文/海外地址均使用系统格式。相同的标题和地址不会重复展示。
- 文字按实际宽度完整换行，没有手工截短或固定字数。右侧箭头及地图均在 Apple 地图中打开同一个原始坐标；文字支持选择与拷贝。
- 加载提示、解析失败提示及重试都在同一卡片底部；查询超过 15 秒会取消并显示重试。没有 GPS 时整个位置区域隐藏。失败示例可点“重试”使用真实服务。
- 快速切换会取消旧请求并丢弃迟到结果。地图标记始终使用输入坐标，不能被反查返回的代表点替换。成功结果仅保存在当前卡片运行内存，最多 64 个坐标。
- 国内、海外、失败、无位置信息四种样例；可以检查 280 / 320 / 400 点检查器以及系统 / 浅色 / 深色外观。样例是公共区域坐标，不读取用户媒体或 Photos 图库。

## 构建与验证

运行 `./Demos/LocationCard/build.command`，打开打印出的 `.app`。运行 `./Demos/LocationCard/build.command --test` 检查异步结果绑定、无 GPS 清理、失败状态、窄宽换行及两种外观。重新构建前退出 Demo，脚本拒绝覆盖正在运行的 Demo。

Demo 的 bundle ID 为 `com.hermes.demo.location-card`，构建只发生在本工作树 `.build/location-card-demo/`。正式 Sources、版本号、下载器、下载记录、设置和 `/Applications/HERMES.app` 均不由这个 Demo 修改。真实地图和地名需要 Apple 地图服务可用。

本机真实查询已验证国内样例返回中文地点及系统格式地址。海外样例的本次查询返回 `MKErrorDomain / placemarkNotFound`，因此保持原始地图标记并在同一卡片内显示失败提示；不以其他地点或静态地址冒充成功，也不据此断言所有海外地点都不受支持。

## 正式集成

已按用户后续明确授权接入 `Sources/Views/Other/MediaInspectorController.swift`，共享 `Sources/Views/Other/MediaLocationCard.swift`，不另留原型控件副本。坐标仍由 `MediaInspection` 从当前媒体读取，保留 Live Photo 照片位置优先及检查器缓存失效规则。隐藏检查器时取消未完成的查询，重新打开时恢复；同一坐标刷新不重启请求。地址变化会重新计算检查器文档高度。

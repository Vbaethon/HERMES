# 下载渠道回归

直接编译实际下载器与实际校验代码，不移植条件表达式，不访问桌面缓存或外部平台。

基础运行：`script/test_download_regression.sh /绝对路径/正常视频.mp4`

传入视频用于验证 `.part` 可读取、完整容器通过和截断一字节被拒绝；不传视频时跳过这部分。测试另行生成正常 PNG，覆盖空文件、HTML、JSON、伪视频、图片被冒充为视频、抖音稀疏/跨作品配对、得物视频排序后的身份配对、原始 ID 补全和 URL 参数。

真实下载回退测试，在另一个终端启动：

```sh
python3 Tests/DownloadRegression/fixture_server.py /绝对路径/正常视频.mp4 18761
script/test_download_regression.sh /绝对路径/正常视频.mp4 http://127.0.0.1:18761
```

该测试通过实际下载器接收 HTTP 200 HTML，验证拒绝后转到备用 MP4，并验证并发下载结果收集。完成后终止本地测试服务器。不会启动、退出或替换 HERMES App。

网络元数据和共享会话测试仍由 `swift test` 执行。

`Fixtures/douyin-live-four.json` 为脱敏后的真实图集响应结构，验证四组对应关系，以及去掉第二张动态后第三张不会前移错配。版本递增单独运行 `bash script/test_versioning.sh`。

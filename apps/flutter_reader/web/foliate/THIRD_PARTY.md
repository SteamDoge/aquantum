# foliate-js 来源与许可

上游：`https://github.com/johnfactotum/foliate-js`。
固定源码提交：`78914aef4466eb960965702401634c2cb348e9b1`。

John Factotum 的 MIT 许可证原文在同目录 `LICENSE`；本目录保留该许可，宿主原创代码采用的 AGPL-3.0-only 不替换它。vendor 下 zip.js 2.8.22（BSD-3-Clause）和 fflate 0.8.2（MIT）的版本由上游该提交的 package-lock.json 确认，其完整许可及 SJCL 原始声明保存在仓库根目录 `LICENSES`。

引擎为纯 ESM，在 WebView 中解析和排版 EPUB、MOBI/AZW3、FB2、CBZ；原生 Flutter 外壳提供共用阅读控制，Rust 负责导入、受管资源和位置存储。

本地修改集中在 `paginator.js`：隐藏引擎内部章节滚动条，保留原生滚动并由宿主绘制全书进度条；接入宿主 `page_effects.js` 的浏览器快照效果；处理 touchcancel 整页吸附、正文选择时不抢拖动、速度计算的零时间差。其他宿主安全策略和受管漫画适配在相邻 `reader/book_security.js` 与 `reader/managed_comic.js`。

Windows 解包文件列表与资源版本在 `lib/formats/document_engine_windows.dart`，Android 从同一套 APK 资源加载。升级或修改引擎后应更新相应资源版本，执行 `test/document_engine_test.dart`，并实际打开 EPUB/漫画复核。目录保留部分当前未启用的上游功能，不代表宿主已提供语音、网络书源等能力。

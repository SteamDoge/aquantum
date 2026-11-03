# 第三方声明与源码来源

项目原创代码为 AGPL-3.0-only；本文件不改变第三方代码、素材或组件的原有许可。

## 内嵌源代码与工程模板

| 组件 | 范围 | 原许可证/声明 |
| --- | --- | --- |
| foliate-js | `apps/flutter_reader/web/foliate`，上游固定提交 `78914aef4466eb960965702401634c2cb348e9b1` | MIT；[原文](apps/flutter_reader/web/foliate/LICENSE)、[来源与本地补丁](apps/flutter_reader/web/foliate/THIRD_PARTY.md) |
| zip.js 2.8.22 | Foliate `vendor/zip.js`，版本来自该固定提交的上游 package-lock.json | BSD-3-Clause；[原文](LICENSES/zip.js-LICENSE)；其中 SJCL 衍生实现保留 [SJCL 原始双许可证声明](LICENSES/sjcl-LICENSE.txt)，采用 BSD 分支 |
| fflate 0.8.2 | Foliate `vendor/fflate.js` | MIT；[原文](LICENSES/fflate-LICENSE) |
| Flutter | Android/Windows 工程模板和生成的插件注册文件 | BSD-3-Clause；[原文](LICENSES/Flutter-LICENSE)；模板本地适配随源码保留 |

Foliate 上游：`https://github.com/johnfactotum/foliate-js`。`apps/flutter_reader/web/LICENSE` 为保留的 Foliate MIT 声明副本，仅覆盖相应第三方部分；宿主自行编写的 `web/reader` 文件不因位于其下而改为 MIT。

## 锁定依赖

[依赖清单](LICENSES/dependencies.json)记录 Cargo 与 Dart 的解析版本、声明许可证及锁文件摘要，包括开发、构建和未交付平台的间接依赖。Registry 依赖由包管理器获取，其源码没有整体复制进本仓库；获取、修改和分发它们时仍应保留原包的声明。该清单对应当前锁文件，不代替更新依赖后的重新审查。

目前 Cargo 声明使用 MIT、Apache-2.0、BSD、ISC、Zlib、Unicode 等许可或相应可选分支；AND 条件保留所有适用义务。Dart 依赖包括 MIT/BSD/Apache 和 Linux 间接依赖 `dbus` 的 MPL-2.0（[原文](LICENSES/dbus-LICENSE)）。未在 dbus 的 Dart 源码中发现“不兼容次级许可”指定；保留 MPL 文件边界，不能把它们的原始声明替换为宿主 SPDX。

PDFium 原生库由锁定的 `pdfium_dart` 构建钩子获取，当前来源为 `bblanchon/pdfium-binaries` 的 `chromium/7811`，不作为二进制提交。其 BSD 及内含第三方声明保留在 `LICENSES/pdfium/`。Windows WebView2 Runtime 为单独安装的运行环境；不随源码重新分发微软运行时。二进制发行还须保留 Flutter 生成的 notices、PDFium 和原生插件所需声明，核对实际打包版本；本次源码推送不等于安装包发行。

## 独立插件

`plugin-sdk` 是宿主公开的 javascript-v1 消息/类型接口与打包工具。独立插件自行声明许可证，通过权限端口调用宿主，HTML 页面可选；不要求所有第三方插件统一采用 AGPL。复制宿主受许可代码、组合衍生作品等具体行为仍需按实际情况判断许可义务。示例只包含本仓库自有的最小插件源码，不附带其他独立项目、账号或访问凭据。

源码版本与本次纯许可/文档差异见根目录 `PUBLIC_SOURCE.json`。公开仓库使用独立 Git 历史；开发仓库的历史提交不随导出复制。

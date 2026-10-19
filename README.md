# 本地书架

面向 iPhone 和 iPad 的独立本地阅读器，以 Legado 的书源和功能为兼容目标，采用原生阅读界面。目前是体验版，与 Legado、Yuedu Reader 官方无关，也未获其背书；“本地书架”暂作为本项目名称，不表示已完成商标检索。

只维护一个最终版本，继续现有原生界面与 JVM 原核心兼容路线。安装包不内置书源，由用户自行导入；当前临时上传开发诊断包，供自签真机验证。

## 可以做什么

- 导入书源，搜索书籍、查看目录、阅读正文、换源和缓存章节。
- 阅读本地 TXT / EPUB，管理书架、分组、书签与笔记。
- 调整字体、字号、行距、边距、配色与翻页方式，使用系统朗读。
- 使用自己配置的 WebDAV、OPDS 和 RSS。

应用无需注册账号，不设会员或付费解锁。书源网站要求的登录、Cookie 和验证码仍然保留。

## 本轮整理

- 中文界面使用简体，去掉默认公版书库、上游账号、会员和反馈入口。
- 增加在线书籍的“导出已缓存 TXT”，标明已导出章节数量，不自动下载缺失正文。
- 增加随包的霞鹜文楷和霞鹜新致宋，继续支持导入自己的字体。
- 字体选择提供字形预览，增加紧凑、均衡、宽松三档间距预设。
- 快捷阅读面板适配大字号并提供关闭按钮，iPad 阅读区域按实际窗口尺寸重排。
- 保留用户已有书源、书库、书籍与阅读数据。

这些条目描述当前源码；已安装的旧版需要更新后才会变化。

## 现有设备与后续构建

开发诊断包通过 Actions 临时提供下载，保留一天，随包提供准确提交的源码快照和构建清单。现有 JVM 体验版需要 iOS / iPadOS 18 或更新版本；手机中已有的书源、书籍和阅读数据不删除。

build 10 已编译并核对，IPA、对应源码和清单已放入本机下载目录，见[构建记录](docs/legado-ios/native-reader-experience-build10.json)。通过 iloader 使用原 Apple ID 覆盖安装；不要先卸载旧版。首次安装和信任设置见[安装说明](docs/legado-ios/windows-install.md)。IPA 需要自行签名。“设置 → 高级 → 自续签验证”目前仅作手动连接检查和报告导出，自动续签尚未实现。

## 兼容性与边界

目前已收到 iPhone 上可搜索并打开正文的反馈，但不能保证所有书源或全部 Legado 功能完全兼容。传统规则主要走现有 JavaScriptCore；保留原引擎的 JVM 路线仍在逐步接入和验证。

复杂 JS、Java 宿主接口、登录验证、媒体源和批量正文需要分别验证；网站失效、网络限制和反爬也会影响可用性。书源数量不等于兼容通过数量。

[功能对照](docs/legado-ios/feature-comparison.md) · [无需真机的执行计划](docs/legado-ios/completion-plan.json) · [迁移进度](docs/legado-ios/migration-status.md)

所有后续构建均不内置书源，不区分个人包或亲友包。书源使用应用内手动导入；过去在本机注入私人书源的做法已停止，原文件不提交仓库、不上传构建或日志，已有设备数据不受影响。

## 开发与来源

Windows 可以整理源码和运行 JVM 测试；iOS 编译使用 Mac / Xcode 或仓库的 macOS Actions。构建说明见[开发文档](docs/legado-ios/cloud-build.md)。

阅读界面与部分服务基于 [Yuedu Reader](https://github.com/CHANG-JUI-LIN/Yuedu-reader)，兼容基准为本机锁定的 Legado 源码。保留各部分原有许可证及署名，详见 [LICENSE](LICENSE)、[源码来源锁定](docs/legado-ios/provenance-lock.json)和[字体来源与许可](Resources/ReaderFonts/ReaderFonts-provenance.json)。

本项目没有获得上游品牌素材使用许可，当前源码使用另行绘制的图标。MPL、Legado GPL 代码和 JDK 的义务仍分别核对，不把整个安装包简单视为“只有 MPL”。当前经仓库所有者授权临时上传诊断构建；许可组合及完整对应源码核验仍未完成，见[分发核对](docs/legado-ios/redistribution-notes.md)。临时上传或之后删除均不代表取得额外许可，原有许可证和署名继续保留。

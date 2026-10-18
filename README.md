# Legado iOS

面向 iPhone 和 iPad 的本地阅读器，以 Legado 的书源和功能为兼容目标，采用原生阅读界面。目前是持续完善中的体验版。

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
- 保留用户已有书源、书库、书籍与阅读数据。

这些条目描述当前源码；已安装的旧版需要更新后才会变化。

## 安装与使用

当前 JVM 体验包需要 iOS / iPadOS 18 或更新版本。

1. 在 Windows 上连接并解锁设备，打开 iloader。
2. 选择已准备好的 IPA，使用原 Apple ID 覆盖安装；更新前不要卸载旧版。
3. 打开应用。已有书源会保留，也可以手动导入 Legado 书源 JSON。

首次安装和信任设置见[安装说明](docs/legado-ios/windows-install.md)。IPA 需要自行签名，应用本身不能延长签名有效期。

## 兼容性与边界

目前已收到 iPhone 上可搜索并打开正文的反馈，但不能保证所有书源或全部 Legado 功能完全兼容。传统规则主要走现有 JavaScriptCore；保留原引擎的 JVM 路线仍在逐步接入和验证。

复杂 JS、Java 宿主接口、登录验证、媒体源和批量正文需要分别验证；网站失效、网络限制和反爬也会影响可用性。书源数量不等于兼容通过数量。

[功能对照与后续优先级](docs/legado-ios/feature-comparison.md) · [迁移进度](docs/legado-ios/migration-status.md)

私人书源只在本机加入安装包，不提交仓库或上传云端构建。

## 开发与来源

Windows 可以整理源码和运行 JVM 测试；iOS 编译使用 Mac / Xcode 或仓库的 macOS Actions。构建说明见[开发文档](docs/legado-ios/cloud-build.md)。

阅读界面与部分服务基于 [Yuedu Reader](https://github.com/CHANG-JUI-LIN/Yuedu-reader)，兼容基准为本机锁定的 Legado 源码。保留各部分原有许可证及署名，详见 [LICENSE](LICENSE)、[源码来源锁定](docs/legado-ios/provenance-lock.json)和[字体来源与许可](Resources/ReaderFonts/ReaderFonts-provenance.json)。

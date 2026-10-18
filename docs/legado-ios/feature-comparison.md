# 当前功能与 Legado 对照

更新：2026-10-18。功能基准为用户提供的 `legado-master.zip`，SHA-256 为 `724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd`。原版逐项源码位置和验收条件见 [64 项功能清单](feature-matrix.md)，本页整理当前产品取舍，不能替代逐项兼容验收。

当前已交付到 Windows 的安装包为 build 7；它通过了云端构建和静态检查，另有 Debug Simulator 的文本阅读测试。用户已确认 build 6 在 iPhone 上能看到内置书源、搜索并打开正文。**这份反馈不等于 build 7 已获真机验收，也不等于 1,331 个书源都可用。**详见 [build 7 记录](native-reader-experience-build7.json)和 [build 6 真机反馈](native-reader-experience.json)。

## 功能对照

“已有实现”表示找到实际代码，仍须按右列验收；“原版兼容待验收”表示没有证明与压缩包中 Legado 的协议、数据或脚本行为一致。这里不以菜单存在或测试数量换算完成率。

| 功能及原版清单 ID | 当前 iOS 情况 | 接下来保留或补齐什么 | 实现与证据 |
| --- | --- | --- | --- |
| 书源导入、导出、分组、编辑（`source.schema`） | 已有实现；1,331 个私人书源在本机原样打包，用户确认首次打开可见。 | 保留；验证往返导入、删除后不复活、升级保留用户修改。 | [书源存储](../../Modules/Core/BookSource/BookSourceStore.swift)、[安装与数据保护记录](migration-status.md) |
| 搜索→详情→目录→正文（`pipeline.search/info/toc/content`） | 传统规则走 JSC。用户确认 build 6 基本可读；固定响应的 Simulator 阅读闭环已通过。 | 最高优先级；保证失败可重试、切章和阅读位置稳定。 | [搜索](../../Modules/Core/BookSource/BookSourceFetcher+Search.swift)、[正文](../../Modules/Core/BookSource/BookSourceFetcher+Chapter.swift)、[UI 验证](reader-online-smoke.json) |
| 发现和分类（`pipeline.explore`） | 已有规则发现页面，尚无完整真实书源验收。 | 保留书源自己的发现入口，简化无关推荐。 | [发现请求](../../Modules/Core/BookSource/BookSourceFetcher+Discover.swift) |
| CSS、XPath、JSONPath、正则及组合规则（`rules.*`） | 已有 Swift/JSC 解析实现；它们与原版 JVM 库存在行为差异。 | 按真实失败源补齐，并继续原版固定输入对照。 | [规则解析](../../Modules/Core/RuleEngine/ModernParser/RuleAnalyzer.swift)、[传统规则迁移边界](traditional-rule-integration.md) |
| 原引擎、动态 `this/eval/Function`、E4X、Java 对象（`core.*`） | JVM/定制 Rhino 已有诊断验证；传统源产品主路径仍是 JSC。 | 保留兼容研究，不宣称所有书源已使用原核心。 | [迁移记录](migration-status.md)、[运行时真机记录](device-validation.json) |
| `mainJs` 纯 JS 源与共享状态（`source.main-js/shared-state`） | 已接入有限文本源 JVM 路径；私人源包中 `mainJs` 为 0。真实主 App 固定链路到达正文，但阻塞网络取消仍失败。 | 先解决取消与恢复，再扩大能力；不能由普通阅读反馈推断通过。 | [产品路由](../../Modules/Services/Online/LegadoMainJSSourceService.swift)、[取消故障](native-cancellation-investigation.json) |
| 五类书源：文字、音频、漫画、文件、视频（`source.five-types`） | 文字、音频、漫画已有内容分流；文件型和视频型没有证明与原版一致。JVM `mainJs` 只允许文字。 | 首先做好文字；音频/漫画独立验收；文件/视频不冒充文字成功。 | [内容类型](../../Modules/Core/BookSource/BookSource.swift)、[JVM 类型限制](../../Modules/Services/Online/LegadoMainJSSourceService.swift) |
| 批量正文（`pipeline.batch`） | 未完成压缩包原版批量协议的产品验收；多章下载不等同一次批量正文请求。 | 保留为兼容缺口。 | [原版清单](feature-matrix.md)、[传统规则迁移边界](traditional-rule-integration.md) |
| 请求方法、编码、请求头、限流（`network.requests/http-host`） | 传统源已有平台网络和同步 JS 宿主桥；JVM 有部分请求字节对照。 | 对照请求字节、重定向、异常和缓存，不能只比最终文字。 | [传统网络入口](../../Modules/Core/BookSource/BookSourceFetcher.swift)、[JSC 宿主桥](../../Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift)、[HTTP 对照](http-wire-capability.json) |
| 书源 Cookie、网页登录、验证码（`network.cookie/browser`、`login.legacy/v2`） | 已有 Cookie、浏览器与登录表单实现；新版 LoginUiV2 完整协议未验收。 | **保留**，与去掉的 App 账号无关；失效 Cookie 应允许清理、重新验证。 | [Cookie](../../Modules/Core/RuleEngine/ModernParser/CookieStore.swift)、[书源登录](../../Modules/Features/BookSource/BookSourceFormLoginView.swift)、[网页验证](../../Modules/SharedUI/Components/SourceWebLogin.swift) |
| Java 类、文件、解压、字体解混淆、加解密、锁、源事件（`host.*`、`source.events-ui`） | JSC 使用有限宿主实现和 Java 类白名单，不能当作完整 JVM；原版能力尚未全部接入。 | 按实际用到的 API 逐项补齐；不静默返回伪造成功结果。 | [Java 能力白名单](../../Modules/Core/RuleEngine/ModernParser/JS/LegadoRuntimeCapabilityRegistry.swift)、[宿主桥](../../Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift)、[原版验收清单](feature-matrix.md) |
| 书架、标签/集合、排序、阅读进度（`reader.bookshelf/groups`） | 已有原生书架及持久化；原版分组和备份数据格式未完成对照。 | 保留；优先验证重启、覆盖安装、删除与恢复不会丢数据。 | [书架](../../Modules/Features/Bookshelf/HomeView.swift)、[书库服务](../../Modules/Services/LibraryStore/) |
| 换源及目录位置匹配（`reader.change-source`） | 已有换源代码，未取得真实多源位置匹配验收。 | 保留；同名异书、不同章节数量和失效源要能安全回退。 | [阅读器换源](../../Modules/Features/Reader/ReaderView+SourceChange.swift)、[章节匹配](../../Modules/Services/Online/ChapterAlignment.swift) |
| 下载、缓存、离线阅读（`reader.cache-download`） | 已有下载队列和章节缓存；尚无用户断网、重启、连续阅读验收。 | 高优先级；区分“缓存缺失”和“正文为空”，支持失败重试。 | [离线下载](../../Modules/Services/Offline/OfflineDownloadManager.swift)、[正文缓存](../../Modules/Services/Online/ChapterCacheRepository.swift) |
| 净化替换、繁简转换（`reader.cleanup`） | 已有替换引擎和显示转换。 | 保留；默认简体界面，不改写用户书源脚本和原始正文。 | [替换引擎](../../Modules/Core/Replace/ReplaceRuleEngine.swift)、[文字转换](../../Modules/Core/Replace/TextConversion+Apply.swift) |
| 排版、字体、间距、主题、翻页（`reader.layout/page-turn`） | 已有 CoreText 阅读器、排版和交互设置；本轮源码新增中文字体，尚未在新版包验收。 | 优先改善中文字体、夜间阅读、长章稳定性、换字体后位置保持。 | [CoreText 阅读器](../../Modules/Core/ReaderCore/CoreText/)、[阅读设置](../../Modules/Features/Reader/ReaderSettingsView.swift)、[字体目录](../../Targets/Yuedu/SharedApp/ReaderFontCatalog.swift) |
| 本地 TXT、EPUB、PDF（`local.txt/epub/pdf`） | 已有统一导入入口；TXT Simulator 阅读验证通过，其他格式尚非本项目的完整验收。 | 保留；验证中文编码、目录、图片和重开位置。 | [文件导入](../../Modules/Services/LibraryStore/LocalBookImportService.swift)、[PDF](../../Modules/Core/PDF/LocalPDFArchive.swift)、[UI 验证](reader-online-smoke.json) |
| 本地 UMD、MOBI（`local.umd/mobi`） | 当前统一导入允许列表和分派中没有这两类。 | 明确列为未支持，后续按需求补齐。 | [导入格式与分派](../../Modules/Services/LibraryStore/LocalBookImportService.swift) |
| 导出 TXT | 本轮新增缓存正文导出服务及界面入口，尚未打包验收；不自动获取未下载章节。 | 保留并让入口容易找到；不完整缓存要清楚提示。 | [TXT 导出服务](../../Modules/Services/Online/CachedBookTXTExportService.swift)、[导出界面](../../Modules/Features/BookDetail/CachedBookTXTExportView.swift) |
| 书签、高亮、笔记、规则高亮（`reader.bookmarks/highlights/highlight-rules`） | 已有原生实现；与原版数据格式、处理后文字锚点未完成对照。 | 保留，去掉付费门槛；跨页选区、编辑和重开应不丢位置。 | [书签](../../Modules/Features/Reader/ReaderBookmarkListView.swift)、[批注存储](../../Modules/Core/ReaderCore/CoreText/CoreTextAnnotationStore.swift)、[规则高亮](../../Modules/Core/ReaderCore/CoreText/RegexHighlightEngine.swift) |
| 自定义字典与阅读记录（`reader.dictionary/read-records`） | 已有选区交互、阅读统计；没有证明可直接使用原版自定义字典规则。 | 保留本地统计；Legado 字典协议独立补齐。 | [选区交互](../../Modules/Core/ReaderCore/CoreText/TextSelectionInteractor.swift)、[阅读统计](../../Modules/Services/Stats/ReadingStats.swift)、[原版清单](feature-matrix.md) |
| 段评（`extension.reviews`） | 未接入并验收原版段评协议；本地段落笔记不等于网站段评。 | 延后，避免在界面冒充已有。 | [原版清单](feature-matrix.md) |
| RSS（`extension.rss`） | 已有 RSS/Atom 及 Legado RSS 解析代码，未完整对照原版。 | 保留为可选功能；“RSS 订阅”不是会员订阅。 | [RSS 存储](../../Modules/Services/RSS/RSSStore.swift)、[Legado RSS](../../Modules/Services/RSS/LegadoRSSScraper.swift) |
| 系统 TTS、HTTP TTS（`extension.tts-system/tts-http`） | 已有系统朗读及 HTTP 朗读实现，尚未完成锁屏、打断、段落跟随与原协议验收。 | 保留；先保证本地系统朗读，第三方接口由用户配置。 | [系统 TTS](../../Modules/Core/TTS/SystemTTSEngine.swift)、[HTTP TTS](../../Modules/Core/TTS/HTTPTTSEngine.swift) |
| 音频、视频、画中画、弹幕（`extension.audio/video`） | 已有有声书播放器和脚本打开视频的宿主入口；完整视频源、选集、弹幕和 PiP 对照未完成。 | 延后完整媒体扩展，避免影响文本阅读收尾。 | [音频播放器](../../Modules/Core/TTS/AudiobookPlayer.swift)、[视频宿主入口](../../Modules/Core/RuleEngine/ModernParser/JS/LegadoJSBridge.swift) |
| 书源编辑、调试、网络日志（`extension.source-editor/http-logs`） | 已有入口和实现；不是全部原版调试 API。 | 保留，错误信息要能定位阶段；分享日志应隐藏认证信息。 | [书源调试](../../Modules/Features/BookSource/)、[诊断导出](../../Modules/Services/Diagnostics/DiagnosticReportBundle.swift) |
| 备份、WebDAV（`sync.backup/webdav`） | 已有 WebDAV 及书源/书架 JSON 迁移代码；不是已经兼容 Legado 完整备份。自签本地模式关闭上游 CloudKit。 | 保留用户自有 WebDAV，优先补安全本地备份恢复。 | [WebDAV](../../Modules/Services/WebDAV/WebDAVManager.swift)、[JSON 迁移](../../Modules/Services/Migration/LegadoMigrationManager.swift)、[备份入口](../../Modules/Features/Settings/BackupSyncView.swift)、[分发模式](../../Modules/Services/Distribution/ReaderExperienceConfiguration.swift) |
| 局域网迁移、HTTP API、Web 编辑器、WebSocket、MCP（`sync.lan`、`web.*`） | 已有局域网 Web 服务，尚未证明与压缩包的完整 HTTP API/编辑器协议一致；WebSocket/MCP 未接入验收。 | 保留已有传书能力；扩展服务延后，不承诺应用挂起后常驻。 | [局域网服务](../../Modules/Services/LanServer/LanWebServer.swift)、[原版清单及 13 个 MCP 工具](feature-matrix.md) |
| 自动任务、Cron（`tasks.cron`） | 没有原版兼容验收，iOS 不能承诺 Android 式精确后台常驻调度。 | 前台补跑和系统允许的后台任务另行设计。 | [平台验收边界](feature-matrix.md) |
| 文件选择、分享、通知、外部打开（`platform.integration`） | 已有平台入口，Android Intent、路径和设备标识不能照搬。 | 保留 iOS 对应能力，逐个验证返回阅读现场。 | [统一文件导入](../../Modules/Services/LibraryStore/LocalBookImportService.swift)、[书源分享导入](../../Modules/Core/BookSource/SharedImportQueueDrainer.swift) |

## 本轮应精简的内容

这些取舍针对本地自签阅读器。当前工作区的改动要等下一次实际打包后才进入手机，不把“计划删除”写成 build 7 已删除。

| 内容 | 处理 | 原因与保留边界 |
| --- | --- | --- |
| Yuedu App 账号、注册、Apple/Google/邮箱登录、头像和账号资料 | 移除用户入口，停止相应远程会话。 | 没有本项目运营的账号服务；与书源自己的账号无关。[登录实现](../../Modules/Features/Settings/LoginView.swift)、[账号路由](../../Modules/Services/Account/AccountBackend.swift) |
| Pro 会员、购买/恢复购买、促销码、会员绑定、会员云镜像、TestFlight 资格申请 | 去掉入口与依赖，已有本地阅读能力无需会员。 | 本项目不售会员；去掉付费墙不能顺带删掉字体导入、笔记、触控区等阅读能力。[会员能力目录](../../Modules/Services/Subscription/PremiumFeature.swift)、[会员服务](../../Modules/Services/Subscription/SubscriptionStore.swift) |
| 上游账号同步、云端用户资料、上游反馈上传 | 停止自动使用，不作为本地阅读前提。 | 用户自有 WebDAV 和本地诊断导出继续保留。[账号同步](../../Modules/Services/iCloud/FirestoreSyncManager.swift)、[分发配置](../../Modules/Services/Distribution/ReaderExperienceConfiguration.swift) |
| 默认公版书库 Project Gutenberg 和青空文库 | 从默认资源库/发现/搜索移除。 | 这是 Yuedu 上游额外功能，非 Legado 必需，也不是用户提供的私人书源。不要删除已经下载的书或用户手动连接。[注册入口](../../Modules/Services/Works/SourceProviderRegistry.swift) |
| “官方模块→AI 推荐”和上游搬家提示 | 从默认首页移除。 | 与本地 Legado 阅读的主流程无关；AI 调用若以后保留，应由用户自行配置服务。[官方模块](../../Modules/Features/Library/Modules/RuleModuleSection.swift)、[资源库首页](../../Modules/Features/Library/LibraryTabRoot.swift) |
| 繁体默认文案 | 改为默认简体并补齐遗漏。 | 上游以繁体字符串作本地化键，简体译文在 `zh-Hans.lproj`；未命中时可能显示原键。不要批量转换脚本、文件名、书源 ID 或用户正文。[本地化入口](../../Targets/Yuedu/SharedApp/GlobalSettings.swift)、[简体译文](../../Resources/zh-Hans.lproj/Localizable.strings) |
| 上游商店链接、购买引导、开发/测试夹具入口 | 逐项移除或只保留内部调试使用。 | 阅读界面只保留用户能实际使用的功能。开源许可证和原作者署名继续保留。 |

公版库的实际来源可以核查：Gutenberg 目录直接使用 `www.gutenberg.org/ebooks.opds/`，见 [PublicLibrary.swift](../../Modules/Services/PublicLibrary/PublicLibrary.swift)；青空文库是日文书库，其目录清单由 `yuedureader.com/catalogs/aozora/v1/manifest.json` 提供，正文下载来自青空文库，见 [AozoraCatalogStore.swift](../../Modules/Services/PublicLibrary/AozoraCatalogStore.swift)及 [下载服务](../../Modules/Services/PublicLibrary/AozoraLibraryDownloadService.swift)。**界面是繁体，不代表这些库的正文都是繁体。**目前没有默认内置“好读”之类中文繁体书库的代码证据，不能仅凭名称猜测用户所指的某一私人书源。

本轮源码已落实：本地分发关闭 App 账号、StoreKit、上游反馈和 CloudKit；会员状态保持未购买，本地阅读能力另行开放。默认公版库隐藏，旧首页公版栏目因没有可用提供者而不发起请求；青空目录服务在本地模式只读已有缓存，即使旧书籍详情调用强制刷新也不访问上游或写检查时间。官方 AI 推荐从提供者注册和栏目选择中移除，用户自行配置的 AI 助手、模块、RSS、WebDAV 及书源网页登录继续保留。中文界面使用简体翻译。**独立品牌源码已通过 Debug Simulator 的 64 项实际验证，包括字体、缓存 TXT 与基础阅读链路；build 9 的 Release 构建及无书源检查也已通过，IPA 独立审计与新版真机验收仍待完成。**详见[当前验证记录](local-product-validation.json)和[build 9 构建证据](native-reader-experience-build9.json)。上游 SDK 源码/依赖尚未全部物理删除，不能据此声称包体已经精简。

## 能否完美兼容书源

**现在不能保证，也没有测得整体兼容率。**能导入 JSON、搜索一本书或显示正文，只证明那条实际执行链路。当前传统源仍以 JSC、SwiftSoup、ICU 等实现承接规则和 Java 宿主，与压缩包内定制 Rhino、Jsoup、Jayway JSONPath、Java 正则并不相同；Java 类白名单也不能替代任意 Java 包。原版的 E4X、对象转换、重载、作用域、动态 `this/eval/Function` 和平台 API 都要分别核对。

已有的固定输入对照仅证明相应样例。普通读书版本尚未全部切换到原解析核心；有限 `mainJs` JVM 路径还存在已记录的阻塞网络取消约 60 秒、超过 15 秒门槛且未恢复后续请求的故障，不能标为稳定通过。见 [取消调查](native-cancellation-investigation.json)。JVM 会话的 Cookie、变量和缓存也尚未完成跨进程持久化验收。

另外，源站关闭、规则过期、登录失效、验证码、付费内容、地区和网络限制，即使 Android 原版也不必然能读取。验收应分别记录“源站在原版是否可用”和“相同输入在 iOS 是否等价”，不给失效网站算作已解决或已兼容。

下一步先稳定文字阅读：简体界面、去掉账号会员、易找的导出、中文字体、缓存与重启恢复。兼容工作选择实际失败书源，在本地保存最小固定响应，对照请求字节、输出、变量、Cookie、异常和缓存副作用；私人书源、固定认证值和完整安装包继续只留本机。

## iOS 自续签研究目标

用户希望一个阅读器在首次配置后自行续签，日常不依赖电脑或其他配套 App。此项列为独立可行性验证，**当前未实现，也未承诺满足上述条件**，不另设用户版本。现成 SideStore 路径仍依赖另外安装的 LocalDevVPN；直接复制续签代码并不能解决安装通道及权限问题。[SideStore 配置要求](https://docs.sidestore.io/docs/installation/prerequisites)、[Apple 能力与签名限制](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

接入主版本前，必须先在当前免费签名、未越狱设备上证明：电脑关闭、无其他配套 App 时能够联网续签并覆盖安装自身，重开后已有书源、书籍和进度保留；再验证后台触发、失败重试及到期恢复。到期显示、提醒、打开外部工具和模拟的成功结果均不算完成自续签。系统后台任务的执行时机受 iOS 控制，不能承诺精确执行。[Apple 后台执行说明](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)

当前新增一个手动启动的只读连接探针，入口为“设置 → 高级 → 自续签验证”：限时检查本机两个固定 lockdown 入口，可导出不包含账号、配对记录及书源的报告。它不执行签名或安装；当前仍需 Xcode 编译、模拟器测试和真机验证。固定入口不可达也不能排除所有其他安装通道。具体范围、上游版本锁和后续验收见[自续签研究记录](self-renewal-research.json)。

# Legado iOS 迁移与验证记录

更新日期：2026-10-19。目标仍是锁定 Legado 源码的功能与书源兼容性，以及适合 iOS 的原生阅读体验；完整迁移尚未完成。

本轮已完成主 App 的有限 `mainJs` 文本书源接入与数据安全改造。最新数据测试通过，不等于真实 JVM 已驱动新主 App 完成阅读，也不等于用户全部书源可用。

## 当前决定：一个版本、不内置书源、临时诊断下载

只维护一个最终版本，沿现有原生界面与 JVM 原核心兼容路线继续，不区分个人或亲友构建。所有后续安装包均不内置书源，改由用户手动导入；过去在本机向 IPA 注入私人书源的做法停止。2026-10-19，用户允许开发验证阶段临时公开上传安装包，完成后清理；当前下载保留一天并附准确提交的源码快照。MPL/GPL/Classpath 组合与相应源码核验仍未完成，见[分发记录](redistribution-notes.md)。

手机中已有的书源、书籍、阅读数据及历史本地包不删除。build 10 已保存到 Windows 下载目录，可通过原 Apple ID 在 iloader 覆盖安装；不要先卸载旧版。当前名称、图标、bundle ID、网站和 44 个上游品牌/截图文件的源码清理及新包静态核对已完成，历史构建不会追溯变成新品牌；新版真机外观、运行和数据保留仍待验证。

下文保留原实验与交付事实；其中“内置”“注入”“体验包”等描述均针对历史版本，不再作为后续打包方案。已锁定的原始 JSON、哈希及用户反馈不改写。

## 新版验证与当前构建

独立品牌源码 `b160788` 的 Debug Simulator 验证已完成：配置 9 项、本地产品 41 项、分页 12 项及两项阅读 UI 用例，共 64 项实际通过，无失败或跳过。字体注册、缓存 TXT 的纯文本保真及固定书源两章阅读均有实际报告；完整六次网络请求也已复核。这只覆盖既有 JSC / CoreText 路径，不替代真机或 JVM 兼容验收，见[验证记录](local-product-validation.json)。

build 9 使用源码 `903e90a`，相关 Swift、资源、Info、工程和测试路径与上述受测版本完全一致；仅打包策略及文档有后续改动，因此不重复启动相同的 UI 验证。Release 构建已成功；另行下载并核对构建证据，确认 135 项普通 JVM 测试、23 项打包门槛和源码／成品无书源检查通过，见[build 9 记录](native-reader-experience-build9.json)。公开仓库的 IPA 上传已跳过，没有取得或独立审计 IPA，也没有新版真机验收。

自续签另加手动只读探针：前两次构建的编译问题已修正并保留原记录。源码 `97d9f0f` 的[独立模拟器重测](https://github.com/zhoujianjia/legado-ios/actions/runs/39146602853)已实际通过 8 项服务测试和 1 项界面测试，零失败／跳过；下载后逐项核对了原始结果、源码哈希、截图与辅助功能文本。模拟器上的两个固定入口均超时，页面仍标“尚未验证”；这不是真机通道结论。探针不执行签名或安装，真机连接、覆盖安装、数据保留和后台续签均未验证，见[研究记录](self-renewal-research.json)。

源码 `594fd21` 的 build 10 已通过 Release 真机目标构建，并下载核对实际无书源 IPA、两个字体及许可、13 个原生模块、39 个导出和普通 JAR；云端 135 项 JVM 测试零失败／跳过。随附源码 ZIP 的 2,649 个文件逐字节匹配该提交，不含本机未提交研究或私人书源。IPA、源码、清单与说明已保存到 `C:\Users\ZJJ\Downloads`，见[build 10 记录](native-reader-experience-build10.json)。此轮临时公开产物保留一天；本包仍需自行签名，尚无 build 10 真机验收，也尚未实现自动续签。

2026-10-19 在暂缓真机测试期间，后续源码保留了未接入阅读路由的原 `AnalyzeRule` 协调器切片，修复同名文本／二进制缓存、块状 JS 库分类及关闭后的宿主调用；完整桌面回归 153 项通过，见[协调器记录](original-rule-coordinator-port.json)。原版有状态观察已独立冻结，并用[可重复运行工具](../../scripts/legado-ios/stateful-port-reference/README.md)实际重放 47 次调用：46 个返回值、9 次状态修改和 112 个前后状态快照一致；一次异常的两处原文仍有脚本编号差异，未计为全部兼容。见[完整对照记录](stateful-port-reference/2026-10-19/record.json)。另补齐 37 份固定来源的运行时声明材料并接入统一打包校验，见[材料与边界](runtime-notices.md)及[本地验证](runtime-notices-validation.json)。[集成模拟器验证](native-cancel-task-trace.json)已完成：当前普通核心的 157 项 JVM 测试和 4 项诊断读取测试通过；主 App 已构建并到达正文及缓存阅读，但取消仍耗时 60.207 秒、超过 15 秒门槛，唯一产品用例失败。新增观测确认任务和网络取消调用已命中，对端也快速关闭连接；本地正文读取仍等到超时，原 JNI 返回 TIMEOUT。第七次恢复请求未尝试，仍需调查底层等待。没有生成新版 IPA，自动续签也未实现。已交付 build 10 的字节及其历史验收范围保持原记录。

## 历史本地体验包：3.0.0 build 7

build 7 修复首页 `hasMoreRule=false` 未传递导致多余搜索请求的问题。云端 Release 构建与独立静态审计已通过；另行 Debug Simulator 的配置、分页、TXT 和书源阅读共 21 项全过，固定书源链路仅有六个必要请求，均为 200，两章正文和返回书架已核对。

完整 1,331 源已在 Windows 本机原样加入 [LegadoReader-build7-with-sources.ipa](/C:/Users/ZJJ/Downloads/LegadoReader-build7-with-sources.ipa)；原 18,256 条目内容和权限均保持，源文件和完整包未上传。具体来源、哈希和验证边界见 [build 7 证据](native-reader-experience-build7.json)。build 7 尚未签名和真机运行，不继承下方 build 6 的用户验收。传统源仍使用现有 JSC，完整 Legado 复刻尚未完成。

## 历史真机反馈：3.0.0 build 6

源码 `ac2ece6728053790d68b73d1dfc5d96c3a16d1cc` 的[主 App 构建 run 39099984816](https://github.com/zhoujianjia/legado-ios/actions/runs/39099984816) 已成功。独立静态审计核对了 unsigned iOS 18+ IPA、普通 JAR 的许可证和测试资源排除、13 个模块的全部原文件及 39 个原生导出；构建证据另含 121 项 JVM 测试，失败、错误及跳过均为 0。

完整 1,331 源已在本地按原字节注入，产生独立的新 IPA 哈希；云包原有 18,256 个条目的内容和 ZIP 权限字段均未变化。两份 IPA、artifact、审计及注入清单的哈希见[当前体验版证据](native-reader-experience.json)。旧包中 TLS 测试资源导致的审计失败记录保持原样。

2026-10-18，用户确认这份本地 IPA 在 iPhone 上“能看到书源，并能搜索打开正文”。据此记录首次导入后的基本真机阅读闭环通过；证据类型为用户反馈，未取得独立设备日志、逐源结果、重启恢复或离线阅读报告。该包的有限 `mainJs` 纯文本路径已接入 JVM，传统规则仍走现有 JSC；本地源包的 `mainJs` 数量为 0，因此这次反馈不能证明 JVM 路径或全部 1,331 源兼容。原静态审计标志及历史原始报告保持不变，新增反馈单独记录在[当前体验版证据](native-reader-experience.json)的 `userReportedDeviceAcceptance`。

另一次 `0965fb2` 的真实主 App Simulator 用例已执行搜索、详情、目录、两章 JVM 正文及实际缓存阅读器 XHTML，但取消耗时约 60.1 秒，超过 15 秒门槛；第七次恢复请求未执行，整例仍失败。只读 Darwin 观测与固定 JDK 源码确认了后台线程可屏蔽 `SIGIO`，尚不足以确定取消延迟的根因。该失败原记录保持不变。

随后 `aab2777` 的独立 [Probe 回归 run 39104510283](https://github.com/zhoujianjia/legado-ios/actions/runs/39104510283) 已在 iOS Simulator 实际通过：原引擎 25 项及 JavaBeans、interop 28 项、TCP、TLS 4 项、HTTP wire 7 次和 CPU 2 项均通过，wire 与原 Android 固定链路比较为零差异。C 阶段日志记录了 3 个原生线程上共 31 次 JNI 调用：每次进入时 `SIGIO` 均被屏蔽，原 JDK handler 初始化、解除屏蔽和恢复 API 的返回码均为 0；没有独立逐位测量恢复后的完整掩码。13 个模块、39 个导出、来源提交和运行 PID 也已核对。这是包含引擎测试的独立诊断 JAR 回归，不能替代普通 Reader JAR 或主 App 的阻塞 HTTP 正文取消验收。主 App 仍须按原 15 秒取消门槛及 45 秒操作期限完成取消与恢复请求，真机和完整兼容验收保持待定。报告及审计哈希见[取消调查记录](native-cancellation-investigation.json)。

同一提交的真实[主 App 重测 run 39104345271](https://github.com/zhoujianjia/legado-ios/actions/runs/39104345271) 仍失败：指定的 1 例已运行，搜索、详情、目录、两章 JVM 正文和缓存阅读器 XHTML 再次到达；实际仅有 5 个完整响应及第 6 个暂停正文响应，第 7 个恢复请求未执行。取消耗时 60.193 秒，仍超过原门槛。普通 JAR、主程序的 39 个导出及附件中的完整提交号均已核对。11 次 JNI 调用的阶段记录显示，实际暂停执行线程已在调用前解除 `SIGIO` 屏蔽并在返回后恢复；另一个线程上的取消调用仅用 12.686 毫秒返回，但这不能证明任务 ID 命中或实际触发 `Call.cancel`。该重测没有解决正文取消，不能继承独立 Probe 的通过结论。

这次诊断已保留原始附件、请求、阶段日志和清理结果；Simulator 的 `data/Library/Logs` 链接路径被采集器安全拒绝，因此没有取得该路径下的崩溃报告，不能据此声称不存在报告。下一次取消调查先观测任务匹配、取消返回值及 `Call.cancel` 的真实调用链，再决定是否检查原生阻塞；本次不继续修改信号掩码或重建 JVM。

## 本轮已实现

| 范围 | 当前实现及验证边界 |
| --- | --- |
| `mainJs` 数据保留 | 单对象、数组和 `bookSources` 包装导入，编辑、导出、落盘与重载保留原脚本文本；空白及 Unicode 不被改写。包装对象先按形状展开，损坏包装不能变成一个默认空书源。大数组直接解码，不先构造完整 `Any` 树再重编码。 |
| 主 App 路由 | `mainJs` 文本源先走独立 JVM 会话接口，覆盖搜索、详情、目录、正文；不要求声明式 `searchUrl`。不支持的宿主能力或结果类型明确报错，不静默切换到 JSC。真实原生完整链路仍待独立验证。 |
| 上下文与会话 | 原始书籍／章节上下文可跨 App 数据存储恢复；书源编辑触发旧会话失效。排队、取消、超时、隔离等已有定向回归。本轮测试注入假执行器，不能据此证明 JNI 或原引擎行为。书源级 JVM Cookie、变量和缓存尚未跨进程持久化。 |
| 正文与原生阅读器 | `mainJs` 纯文本按既有契约保存为权威文本包，不伪造原始 HTML 或声称不存在的 XHTML 文件。真实 `OnlineChapterContentService.payload(.cacheOnly)` 从已落盘正文构建转义 XHTML；测试验证正文、第二段、转义、跨实例恢复与无额外执行器调用。 |
| 历史内置书源安装 | 当时的资源及清单读取、哈希和解码在现有工作队列执行。首次仅追加缺失 URL，保留已有记录的身份、规则、分组及启用配置；同一版本完成后，用户删除的源不会因重启恢复。日志与持久标记区分失败和成功，写盘失败不标完成。后续包不再携带资源，不以此继续内置书源。 |
| 库文件保护 | 读入失败不能冒充空库，不清空内存或覆盖原文件；失败期间阻止后续保存，成功重载后解除保护。中断恢复使用安装事务标记，遇到无法安全判断的用户修改停止自动导入。临时测试目录默认不自动安装资源。 |

传统规则源目前仍使用 Yuedu 的 JSC 路线。JVM 的有限 `DeclarativeSource` 已接入非 URL 标量选择与静态替换，28 条结果同原版 Android 比较为零差异；完整桌面回归为 135 项唯一测试、无失败／错误／跳过。这不代表原版 `AnalyzeRule`／`AnalyzeUrl` 已完整迁移，新片段尚未在 iOS JVM 上运行，也未进入当前已交付 build 6。依赖边界和后续链路见[传统规则接入清单](traditional-rule-integration.md)，逐项证据见[标量片段移植比较](scalar-selector-port.json)。

## 最新实际测试：21＋30

源码提交：`0a03309ffef09ff0150a59ed4ef075e3b7f803ef`。
[数据云测 run 39098846197](https://github.com/zhoujianjia/legado-ios/actions/runs/39098846197) 两个 job 均成功；独立下载 artifact 后另行核对 ZIP 字节数／SHA、原始 XML、逐例日志与 xcresult 汇总。

| 测试 | 实际结果 | 范围 |
| --- | --- | --- |
| Runtime interface，job `117590774078` | 21 个唯一 XCTest 通过；失败、错误、跳过均为 0 | Swift 接口、宿主头字段／字节、取消与诊断等；`LEGADO_RUNTIME_SOURCE_ONLY=1`，无 JVM payload。 |
| App source data，job `117590774212` | 30 个唯一用例通过；失败、跳过、预期失败均为 0 | 6 项脚本保留＋11 项安装／恢复保护＋13 项注入假执行器的产品链路。 |

30 项的逐例开始／通过记录与原始 xcresult summary 的 `totalTestCount=30`、`passedTests=30` 一致。测试结果明确记录 `jvmIntegratedIntoReading=false`、`realBookSourcesValidated=false`、`deliveredIPAExecuted=false`、`deviceValidationPassed=false`。

| 可复核证据 | 标识与 SHA-256 |
| --- | --- |
| Runtime artifact | `legado-reader-runtime-interface-tests`，ID `12125857022`，2,295 字节；`838ffdc0ac87ca24fac5fcc53c0387572f905e40be22b8b7e42edff80906688e` |
| Runtime 原始 XML | `runtime-swift-tests.xml`；`9109c6080ae008d98ade4a0e3cc647ed2def1c77dd5497c69985614f95fab824` |
| Source-data artifact | `legado-reader-source-data-tests`，ID `12125879790`，1,322,419 字节；`dda5203f5d9a777bc90e60764f8e258a7f58ed53905567ee0c0491b9b0d56510` |
| 原始 xcresult 汇总 | `source-data-summary.json`；`1f6213241ae9a74cb54a14c6332b219778918bb6b0579828930946fd21b131e0` |
| 绑定源码的测试结果 | `source-data-result.json`；`cf1f837a1e25f7cdd2f38b8b5aca3ea2d88506986efd41f9c29d41b127f15dff` |

原始日志、XML、完整 xcresult、汇总与独立审计保存在本地忽略目录 `.build/cloud-evidence/run-39098846197/`。本轮没有修改历史原始审计 JSON，也没有把数据测试提升为 G1–G5 的新真机证据。

## 历史记录：完整书源曾仅在本地注入

此前用户的完整资源以原始字节加入个人体验包，没有上传公开仓库、云端构建、Actions artifact 或日志。这一打包做法已停止；后续包均不内置任何书源，原文件、手机已有源和历史包保持，不删除也不再注入。这里保留当时非内容性的校验信息：

- 源数量：1,331；原文件大小：8,669,535 字节。
- 原文件 SHA-256：`4427e33c22d884d0fbaaa17fdbb1c580e6dfd141de5bde0b954c61bef61ced9b`。
- `mainJs` 源数量：0。**这不代表无 JavaScript**：传统规则、URL、header 等仍可包含脚本，不能由此推断兼容率。

过去的流程先在云端生成不含私人书源的未签名主 App，再在 Windows 使用[原本地资源注入工具](../../scripts/reader-experience/bundle-local-sources.py)加入完整资源及版本／哈希清单，最后签名安装。当时工具校验了输入 IPA 与云端构建清单的 SHA、大小和源码戳；注入后逐项验证其他条目的内容与权限未变，并单独记录新 IPA 哈希。这是历史过程，不是后续操作指引。

当时本地包的资源清单使用 `schemaVersion=1`、内容哈希派生版本和完整 SHA；App 只在显式本地体验模式且资源存在时安装。资源不存在不自动填充库；资源存在但校验失败会保留诊断，不假装成功。

历史注入工具及小型合成安装回归保留，用户对 build 6 可见书源、可搜索并打开正文的反馈保持原边界。首次导入性能、逐源可用性和兼容率尚未测量，源文件曾包含在包中不等于全部源已通过兼容验收。

## 仍待完成的验收

| 项目 | 当前边界 |
| --- | --- |
| 新主 App 的真实原生链路 | 使用实际 JNI／JVM／原引擎完成导入 → 搜索 → 详情 → 目录 → 正文 → 原生阅读，以及关闭重开、缓存恢复与错误处理，尚未通过。 |
| 新主 App 的真机阅读 | 用户已确认 build 6 在 iPhone 上可见内置源、能搜索并打开正文。该确认覆盖 JSC 路径的基本阅读闭环；重启／离线／长时间阅读及 JVM 路径仍待验收。21＋30 source-only／假执行器测试和历史 Probe 不替代这些验收。 |
| 完整 1,331 源 | 尚无逐源可用性或兼容率报告；传统规则主体仍待迁移和 Android 对照。 |
| 原版兼容与稳定性 | 新链路仍需比较请求字节、输出、变量、Cookie、异常与缓存副作用，并完成浏览器、并发、持续运行和性能测试。历史 G3–G5 的部分覆盖维持原边界。 |
| 全功能迁移 | [64 域功能矩阵](feature-matrix.md)仍是验收清单；媒体、文件格式、登录、字体、备份同步、自动任务、MCP 等不能由本轮文本链路测试推定完成。 |

下一步在同一个版本内完善实际阅读交互，并按传统规则清单继续 JVM 原核心接入和 Legado 对照。传统源当前仍走 JSC，这是迁移现状，不是另立一个发行版本；原有 1,331 源没有 `mainJs`，也不以更多独立 Probe 替代它们的兼容工作。`mainJs` 主链路的阻塞正文取消与恢复仍待解决，真机证据另行取得。后续构建不内置书源，开发诊断包按本次授权临时上传，兼容性、数据安全和许可核验边界保持不变。

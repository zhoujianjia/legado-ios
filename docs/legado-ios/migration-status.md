# Legado iOS 迁移与验证记录

更新日期：2026-10-18。目标仍是锁定 Legado 源码的功能与书源兼容性，以及适合 iOS 的原生阅读体验；完整迁移尚未完成。

本轮已完成主 App 的有限 `mainJs` 文本书源接入与数据安全改造。最新数据测试通过，不等于真实 JVM 已驱动新主 App 完成阅读，也不等于用户全部书源可用。

## 本轮已实现

| 范围 | 当前实现及验证边界 |
| --- | --- |
| `mainJs` 数据保留 | 单对象、数组和 `bookSources` 包装导入，编辑、导出、落盘与重载保留原脚本文本；空白及 Unicode 不被改写。包装对象先按形状展开，损坏包装不能变成一个默认空书源。大数组直接解码，不先构造完整 `Any` 树再重编码。 |
| 主 App 路由 | `mainJs` 文本源先走独立 JVM 会话接口，覆盖搜索、详情、目录、正文；不要求声明式 `searchUrl`。不支持的宿主能力或结果类型明确报错，不静默切换到 JSC。真实原生完整链路仍待独立验证。 |
| 上下文与会话 | 原始书籍／章节上下文可跨 App 数据存储恢复；书源编辑触发旧会话失效。排队、取消、超时、隔离等已有定向回归。本轮测试注入假执行器，不能据此证明 JNI 或原引擎行为。书源级 JVM Cookie、变量和缓存尚未跨进程持久化。 |
| 正文与原生阅读器 | `mainJs` 纯文本按既有契约保存为权威文本包，不伪造原始 HTML 或声称不存在的 XHTML 文件。真实 `OnlineChapterContentService.payload(.cacheOnly)` 从已落盘正文构建转义 XHTML；测试验证正文、第二段、转义、跨实例恢复与无额外执行器调用。 |
| 内置书源安装 | 资源及清单读取、哈希和解码在现有工作队列执行。首次仅追加缺失 URL，保留已有记录的身份、规则、分组及启用配置；同一版本完成后，用户删除的源不会因重启恢复。日志与持久标记区分失败和成功，写盘失败不标完成。 |
| 库文件保护 | 读入失败不能冒充空库，不清空内存或覆盖原文件；失败期间阻止后续保存，成功重载后解除保护。中断恢复使用安装事务标记，遇到无法安全判断的用户修改停止自动导入。临时测试目录默认不自动安装资源。 |

传统规则源目前仍使用 Yuedu 的 JSC 路线。JVM 中的有限 `DeclarativeSource` 和尚未接入的静态替换内核，不代表原版 `AnalyzeRule`／`AnalyzeUrl` 已迁移；依赖边界、已知 JSONPath 差异和首批原版对照输入见[传统规则接入清单](traditional-rule-integration.md)。

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

## 完整书源只在本地注入

用户的完整资源保持原始字节，不删减、不改写，也不上传公开仓库、云端构建、Actions artifact 或日志。这里只记录非内容性的校验信息：

- 源数量：1,331；原文件大小：8,669,535 字节。
- 原文件 SHA-256：`4427e33c22d884d0fbaaa17fdbb1c580e6dfd141de5bde0b954c61bef61ced9b`。
- `mainJs` 源数量：0。**这不代表无 JavaScript**：传统规则、URL、header 等仍可包含脚本，不能由此推断兼容率。

构建流程先在云端生成不含私人书源的未签名主 App，再在 Windows 使用[本地资源注入工具](../../scripts/reader-experience/bundle-local-sources.py)加入完整资源及版本／哈希清单，最后签名安装。工具校验输入 IPA 与云端构建清单的 SHA、大小和源码戳；注入后逐项验证其他条目的内容与权限未变。注入会产生新的 IPA 哈希，必须和原云端包分别记录。

本地包的资源清单使用 `schemaVersion=1`、内容哈希派生版本和完整 SHA；App 只在显式本地体验模式且资源存在时安装。资源不存在不自动填充库；资源存在但校验失败会保留诊断，不假装成功。

注入工具及小型合成安装回归已具备。完整资源进入最新 IPA 后的安装、首次导入性能和真实站点可用性，仍须以匹配包的实际报告验证；源文件包含在包中不等于源已通过兼容验收。

## 仍待完成的验收

| 项目 | 当前边界 |
| --- | --- |
| 新主 App 的真实原生链路 | 使用实际 JNI／JVM／原引擎完成导入 → 搜索 → 详情 → 目录 → 正文 → 原生阅读，以及关闭重开、缓存恢复与错误处理，尚未通过。 |
| 新主 App 的真机阅读 | 本轮 21＋30 是云端 source-only／假执行器测试；新版主 App 自签安装后的真实阅读仍待验收。历史独立 Probe 的 G1/G2 成功不能替代此项。 |
| 完整 1,331 源 | 尚无逐源可用性或兼容率报告；传统规则主体仍待迁移和 Android 对照。 |
| 原版兼容与稳定性 | 新链路仍需比较请求字节、输出、变量、Cookie、异常与缓存副作用，并完成浏览器、并发、持续运行和性能测试。历史 G3–G5 的部分覆盖维持原边界。 |
| 全功能迁移 | [64 域功能矩阵](feature-matrix.md)仍是验收清单；媒体、文件格式、登录、字体、备份同步、自动任务、MCP 等不能由本轮文本链路测试推定完成。 |

下一步优先取得新主 App 的真实原生链路及匹配真机证据，再按传统规则清单逐步接入和对照；不降低现有兼容性或数据安全门槛。

# 传统书源核心：最小接入边界

此文是源码边界核对与后续验证输入，不表示传统规则已经接入原生阅读流程，也不改变现有验收门槛。

唯一原版基准为 `F:/legado-master.zip`，SHA-256：
`724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd`。
下述原版行号按 ZIP 内原始 UTF-8 文本计算，路径均相对于 `app/src/main/java/io/legado/app/`。
Android 原版基准只取该源码档案；必要的既有 Hutool 5.8.22 算法另按官方标签保存来源，未读取或输出私人书源内容。

用户提供的书源统计为 1,331 项、0 项 `mainJs`。**没有 `mainJs` 不代表没有 JavaScript**：传统书源的 URL、header 和各字段规则仍可包含 JS。尚不能据此推断任何兼容率。

## 已有实现与缺口

| 部分 | 当前事实 |
| --- | --- |
| 六个底层解析文件 | `jvm/src/main/kotlin/io/legado/app/model/analyzeRule/` 已有 `RuleAnalyzer`、`AnalyzeByJSoup`、`AnalyzeByXPath`、`AnalyzeByJSonPath`、`AnalyzeByRegex`、`SourceHtmlParser`。原始文件及 SHA 存于 `vendor/manifest.json`。 |
| `DeclarativeSource` | 是有限编排原型；支持部分静态请求及 CSS/XPath/JSONPath/正则。非 URL 标量字段的显式 `@CSS:`／`@XPath:`／`@Json:` 选择器已接入有限 `##` 替换；URL、元素／列表及动态规则仍明确拒绝，动态 URL 也未迁移。 |
| `StaticRuleReplacement`／`StaticScalarSelectorRule` | 原静态替换内核经新的有限标量 helper 接入 `DeclarativeSource`；保留 nullable 结果、替换及末尾 HTML4 unescape 顺序。完整 `AnalyzeRule` 尚未迁移，主 App 传统源仍走 JSC。 |
| `SourceJavaHost` | 是有限宿主适配器；部分 `java.get/head/post`、动态 header/URL、proxy 等明确返回 unsupported，不能替代原版全部 `JsExtensions`。 |

上述仓库路径均以 `Packages/LegadoRuntime/` 为前缀。现有 `DeclarativeSourceTest` 仅证明固定 CSS 四步链路、几个底层解析调用及 unsupported 错误，不证明真实书源可用。

当前执行顺序统一见 `completion-plan.json` 的 `execution.stepByStep`：C1 至 C5 依次推进原规则与请求、状态与登录、WebBook 编排、普通 JAR／JNI／App 唯一入口，以及核心对照和重启离线阅读。C1 本轮已接通动态 header、初始登录域、相对 URL、请求选项及执行错误边界；实际 114 项 Windows JVM 方法（新增18＋既有96）和普通 JAR／smoke 通过。历史 82／44／38 项与方法内的 140／40 组向量均不累加为本轮方法数。完整 WebBook、持久化、browser/proxy/media/rate-limit 与 App／JNI 路由仍未完成；见 `core-original-url-options-step.json`。此前阶段证据保留在 `core-renewal-url-signature-step.json` 等历史记录。

## 原版文件与关键方法

| 文件 | 方法／原版行号 | 最小职责 |
| --- | --- | --- |
| `model/analyzeRule/AnalyzeRule.kt` | `setContent` 104；`getStringList` 205/212；`getString` 302/315；`getElement` 387；`getElementsRaw` 422；`getElements` 453 | 内容类型、模式选择、列表与标量结果、URL／HTML 转换。 |
| 同上 | `splitSourceRule` 593；`SourceRule` 647；`makeUpRule` 776；`replaceRegex` 544 | JS 与选择器分段、`@put/@get`、内嵌表达式、捕获组与 `##` 替换。 |
| 同上 | `put/get` 856/875；`evalJS` 896；`compileScriptCache` 938 | 变量作用域、宿主绑定、共享状态、解释执行及缓存。 |
| `model/analyzeRule/AnalyzeUrl.kt` | `initUrl` 175 → `analyzeJs` 188 → `replaceKeyPageJs` 216 → `analyzeUrl` 248；`encodeParams` 333 | URL 执行顺序、页码分支、内嵌 JS、URL options、编码。 |
| 同上 | `evalJS` 395；`getStrResponseAwait` 454；`UrlOption` 829 | URL JS 绑定、请求及响应行为、header/body/charset/timeout 等配置。 |
| `model/analyzeRule/AnalyzeUrlNetworkOptions.kt` | `parseRequestTimeoutMillis` 12；`parseBooleanOption` 25；`buildScopedDns` 50；`buildRequestClient` 86 | timeout、重定向、DNS、代理配置与实际客户端派生。 |
| `model/analyzeRule/RuleDataInterface.kt`、`RuleData.kt` | 变量接口；`putBigVariable/getBigVariable` | 书／章节等规则数据和大变量，不能无条件合并进一个 source 字典。 |
| `model/webBook/BookList.kt` | `analyzeBookList` 35 | 搜索／发现列表到书籍数据。 |
| `model/webBook/BookInfo.kt` | `analyzeBookInfo` 28/48 | 详情规则与书籍字段更新。 |
| `model/webBook/BookChapterList.kt` | `analyzeChapterList` 36/188 | 目录、章节身份、顺序及后续目录页。 |
| `model/webBook/BookContent.kt` | `analyzeContent` 41/222；`analyzeContentBatch` 283 | 正文净化、后续内容页及批量正文。 |
| `model/webBook/WebBook.kt` | `searchBookAwait` 53；`getBookInfoAwait` 202；`getChapterListAwait` 297；`getContentAwait` 395 | 将 URL 请求、响应和上述业务解析串联。 |

## 依赖边界

- 底层选择器可留在 JVM 内：当前锁定 `jsoup:1.23.2`、`JsoupXpath:2.5.3`、`json-path:3.0.0`、Java 正则与现有定制 Rhino。`SourceHtmlParser` 需保留旧书源 `<a/>` 自闭合 DOM 行为，CSS 与 XPath 使用同一构造方式。
- `AnalyzeRule` 还依赖 `BaseSource`、`BaseBook/Book/BookChapter`、`RuleDataInterface`、`AppPattern`、`NetworkUtils`、Gson、`commons-text` 的 HTML unescape、缓存及共享 JS scope。只剥离 Android 注解和 `TextUtils` 不能完成这一层迁移。
- JS 绑定须按原方法保留类型与可见性：`java/cookie/cache/source/book/result/baseUrl/chapter/chapters/title/src/nextChapterUrl/rssArticle/fromBookInfo`；URL 执行还绑定 `page/key/speakText/speakSpeed/infoMap`。Java 对象不能提前全部 JSON 化而改变方法、重载与集合语义。
- 原版 `evalJS` 为每次执行创建 bindings，再接入书源共享 scope／global-state key；不可将所有调用改成一个可变全局字典。取消、超时和会话隔离仍需原有门槛。
- `JsExtensions.kt` 还引用浏览器、登录、文件、压缩、字体、刷新与 Android UI。应明确划出 iOS 宿主接口，逐项验证；未迁移能力必须显式报错，不能以空值或吞异常冒充成功。
- `AnalyzeUrl` 的字符集、query/form 字节、动态 header、`bodyJs`、Cookie、登录头域、重试、重定向与 DNS 都影响请求。现有 `URI.resolve` 与 `{{key}}/{{page}}` 字符串替换不足以替代原执行顺序。

## JSONPath 默认错误策略的有限修复

原 `AnalyzeByJSonPath.kt` 的三处 catch（原版 53–54、90–91、140–141 附近）使用：

```kotlin
onError?.invoke(e) ?: e.printOnDebug()
```

移植版此前改为无 handler 时直接 `throw e`，导致缺失路径或无效表达式阻止 `||` 后备分支。本次只修复这三处 catch：存在 handler 时仍交由 handler 处理；未传 handler 时记录可控制的 JUL `FINE` 日志并继续原有结果收尾和组合流程。显式 handler 抛出的异常保持同一对象向上传播，JSON 构造失败仍抛出；没有增加通用空值兜底，也没有改变 `&&/%%`、类型转换或元素归一化。

新增 5 项聚焦 JVM 测试覆盖三个 helper 入口的缺失／无效路径、`||` 后备、真实异常类型、显式 handler 与可关闭的日志、同一异常对象传播，以及坏 JSON 构造失败。Windows JDK 21 完整回归实际执行 126 项唯一测试，失败、错误和跳过均为 0；普通 `runtimeJar` 组装及产品 JAR 审计通过，新测试类、冻结 golden、TLS fixture、JUnit／Hamcrest 均未进入普通包。此次修改尚未在 iOS JVM 上执行，既有 Core 探针通过记录不能作为本次新日志分支的运行证明。
其余可见适配包括去除 `@Keep`，XPath 的 `TextUtils.join` 改为 `joinToString`；原 `RuleAnalyzer` 与 `SourceHtmlParser` 的文本逻辑保持一致。

## 已取得的原版 JSONPath 公开入口基准

源码 `af082b2a9c185aa617b84f8849988d6ca1712da6` 的 [Android run 39106937770](https://github.com/zhoujianjia/legado-ios/actions/runs/39106937770) 已成功。独立测试针对 12 个固定 JSON 字符串，分别调用原 `AnalyzeRule.getString(rule, false)`、`getStringList(rule)` 和 `getElements(rule)`，每次新建实例，共记录 36 次原始观测：36 次返回、0 次 API 异常、0 次构造或采集失败。原 Application、minSdk 26、API 35、run UUID、全部 2,747 个原文件以及 3 个解析文件 SHA 均已核验；原 instrumentation XML 为 1 项执行，失败、错误和跳过均为 0。

原报告的 17,043 字节已原样冻结为 [android-jsonpath-public-golden.json](../../Packages/LegadoRuntime/jvm/src/test/resources/fixtures/android-jsonpath-public-golden.json)，SHA-256 为 `8563213d759975f4b7857757e7ee784da7e49e4eb4a5825b681f4d9421ec2c98`。run、archive、三个源码、输入、harness、原 XML 和独立审计的哈希，以及完整 36 条观测见 [JSONPath 公开入口证据](jsonpath-public-reference.json)。原 18 项静态替换基准和 mainJs 基准保持不变。

本组原版结果确认：缺失路径和无效表达式返回空结果，`||` 的缺失／无效前分支不会阻止后备值；混合列表在 `getElements` 中去除 null、保留数字／布尔／对象类型；不等长 `%%` 在列表入口按首列表长度交错，标量入口返回空串；合法 filter 内的 `&&` 未被拆成外层组合。`getStringList` 会将混合值转为字符串，这与元素入口的类型保留不同。

这些是原版公开 API 的实测结果，**不构成 36 项 port 零差异**。本次聚焦测试只将缺失／无效路径的 `||` 后备两个 case 在 `getString` 与 `getStringList` 的 4 条非空结果同原观测比较，值与 Java 结果类型均一致；这些结果不需要公开入口额外归一化。其余 32 条没有进行 port 比对，尤其不能将底层 helper 的可空结果或混合列表直接等同于公开 API。原 `AnalyzeRule` 在公开入口还包含 null／元素收尾处理，不能用比较器静默补值或归一化 helper 输出来宣称一致。本次仅修复上述三处生产 catch，没有迁移完整 `AnalyzeRule`，也没有读取私人书源；iOS、真机、G4、完整书源兼容及全功能验收均保持未通过。

## 已验证的有限标量选择与替换

原版 [Android run 39111502457](https://github.com/zhoujianjia/legado-ios/actions/runs/39111502457) 针对 14 个固定输入，分别执行 `AnalyzeRule.getString(rule, false)` 和默认 `getString(rule)`，实际取得 28 条 String 结果，0 项 API 异常或采集失败。原 XML 的 1 项测试通过且无跳过；六个原解析文件、全部 2,747 个源码快照、输入和 run UUID 已核对。20,226 字节原报告逐字节冻结为 [android-scalar-selector-golden.json](../../Packages/LegadoRuntime/jvm/src/test/resources/fixtures/android-scalar-selector-golden.json)，SHA-256 为 `f7f56a6ebeeb381d997335230f6030cb730130e7669887bc7e0130e7e592c3b7`；完整来源见[原版观测记录](scalar-selector-reference.json)。

实现提交 `a46bcb644a9f6947568e2c6076c61f215d79db0a` 只开放非 URL 标量字段中有非空选择器、非空 pattern 的显式 `@CSS:`／`@XPath:`／`@Json:` 片段。规则外层按原逻辑 ASCII trim，选择器单独 trim，pattern／replacement 不另行 trim。CSS 前缀继续交原 helper 决定模式；CSS 缺失返回 null 时跳过替换，XPath／JSON 的非 null 空串仍执行 `^$` 替换，最后才按开关进行一次 HTML4 unescape。使用原版 `commons-text:1.13.1`，其实际 POM 引入 `commons-lang3:3.17.0`；两个库的版本、四份原 LICENSE／NOTICE、当前依赖图和严格校验信息见[依赖来源](../../Packages/LegadoRuntime/vendor/scalar-rules/manifest.json)。原版 Android 完整 resolved graph 未测量，不把外部 Maven 哈希归为用户 ZIP 提供。

Windows JDK 21 已逐条严格比较上述 28 条 String 和 Java 类型，差异为 0，未在比较器中 trim、补空或投影结果；上下文使用真实 String／Element／JXNode。9 项新增测试同时验证 URL／列表／动态规则拒绝、复杂 CSS 模式、异常边界，以及四个既有业务入口中的非 URL 替换和四次固定宿主请求。完整回归为 135 项唯一测试，失败、错误、跳过均为 0。普通与 opt-in JAR 分别组装，普通包中无新测试类、golden、JUnit 或 TLS fixture；新增依赖的类、版本信息、许可证和 provenance 字节也已核对。[移植比较记录](scalar-selector-port.json)保留对应源码及原始 XML／包哈希。

隐式模式、URL 处理、元素／列表变形、空选择器／pattern、JS／状态指令和捕获列表不属于这次片段。此修改尚未在 iOS JVM 上执行，未进入已交付 build 6，也未将主 App 的传统源改路由到 JVM；不能据此声称全部 1,331 源、完整 `AnalyzeRule`／`AnalyzeUrl` 或 G4 已通过。

## 后续可独立验证的链路

1. **静态完整阅读链路**：固定响应的搜索 → 详情 → 目录 → 正文，分别使用 CSS、XPath、JSONPath、正则；覆盖 `&&/||/%%`、索引、`text/textNodes/html`、`##` 替换、实体、重定向基址和相对 URL。保留原 selector → 结果转换 → 替换的顺序，不能只测单个 helper。
2. **传统规则中的 JS 与状态**：同一链路加入字段 `@js:`、`{{…}}`、`@put/@get`、捕获组、Java 字符串／集合；覆盖 URL JS、页码分支、动态 header 和 POST 编码。记录每步变量、Cookie、异常和缓存变化，验证并发会话隔离。
3. **原业务编排**：目录分页／重复章节、正文 `nextContentUrl`／净化、登录和浏览器取消；再进入批量正文、字体及扩展功能。前两步通过不能替代这些范围。

优先复用 ZIP 中已有测试的输入（以下路径相对于 `app/src/`）：

- `androidTest/java/io/legado/app/model/webBook/SourceContentCompatibilityTest.kt`：文本节点、替换、JS/Base64、章节身份及目录显示顺序。
- `test/java/io/legado/app/model/analyzeRule/AnalyzeRuleElementsNormalizationTest.kt`：元素结果归一化。
- `test/java/io/legado/app/model/analyzeRule/AnalyzeByJSoupDomTest.kt`：DOM／选择器兼容行为。
- `test/java/io/legado/app/model/analyzeRule/AnalyzeUrlLoginHeaderContractTest.kt`、同目录的 `AnalyzeUrlNetworkOptionsTest.kt`：登录头域与网络选项。

每组均以锁定 Android 原实现产生 golden，再比较 iOS JVM 的请求字节、完整输出、变量、Cookie、异常与缓存变化。新建合成向量应标明来源和覆盖范围，不能把相同自制 helper 的两次输出当作原版一致性证明。

## 未接入阅读路由的原协调器切片

原 `AnalyzeRule` 协调器及有限 Java 实体接口目前保留在独立的 JVM 切片中，普通 JAR 会包含这些类；`DeclarativeSource`、`mainJs` 和主 App 的传统规则阅读路由没有调用该协调器。缓存和大变量仍由显式 `RuleEnvironment` 提供内存存储，不代表 Android 的 Room／文件持久化，也不是完整实体 ABI。

2026-10-19 新增三项回归，先在旧实现取得三项实际失败，再验证最小修复：字符串与二进制缓存保留原版独立 key 空间；只有解析成功的 JSON map 才按未支持的 map 库处理，合法块状 inline JS 正常执行；关闭协调器后，其宿主调用不能进入仍开放的共享环境。前两项依据锁定原源码行为，第三项验证移植层生命周期约定，均不是本次新采集的 Android golden。

Windows JDK 21 本轮强制执行完整 JVM 回归，实际为 18 份 XML、153 个唯一测试方法，失败／错误／跳过均为 0；原协调器测试类包含 18 个方法，其中已有两项继续循环比较冻结的 28 条标量和 36 条 JSONPath 原版观察值。原始红／绿日志和 XML 保存在本地忽略目录 `.build/traditional-coordinator-review/`，没有将其他状态语料自动算作本切片通过。

有状态原版语料的 port 对照、全局 scope 创建锁的并发与取消、持久化、`AnalyzeUrl`、Cookie／浏览器、批量正文及完整实体接口仍需独立验收。以上桌面回归不证明 iOS 执行、真实书源或全功能兼容，也没有改变当前阅读路由。

该切片及三修复已固定在提交 `4e0df35`，源码、红绿回归、普通 JAR 与 153 项桌面测试的对应关系见[协调器记录](original-rule-coordinator-port.json)。

此前成功取得的原版有状态观察现已另行冻结：14 个场景共 56 个有序步骤，其中 47 次公开 API 调用实际为 46 次返回、1 次普通异常；原对象在场景内持续复用。原始报告、单项 instrumentation XML、全部 2,747 个源码及 19 项显式输入针点已复核，见[原版观察记录](traditional-stateful-reference.json)。这些结果提供后续对照基准，尚未计为该移植协调器的零差异通过。

后续源码 `c47169d` 修复了移植层环境级锁覆盖脚本初始化的问题：慢库初始化不再阻塞不同 key 的库或 CryptoJS scope，同键仍串行，创建锁登记在 finally 清理，关闭后拒绝发布。旧实现已观察到一项跨库超时；修复后的 6 项并发／生命周期回归及既有 18 项协调器测试通过，云端完整 JVM 回归为 163 项。使用该提交普通 JAR 重放原有 47 次调用，46 个返回值、9 次修改和 112 个状态快照均精确匹配，仍保留相同两处异常脚本编号差异。完整证据见[本轮记录](sdk-and-rule-scope-validation.json)。同键等待取消、同一 AnalyzeRule 实例并发、iOS 协调器执行、AnalyzeUrl 和产品传统规则路由仍未验收；此次没有改变书源状态隔离或共享环境生命周期。

2026-10-20，按“先做自签和核心、其余未完成并暂缓、暂不做真机验证”的新范围，新增显式 task-bound 的 `ProductionRulePlatform`。保留的原协调器现在可以通过 `LegadoRuntime.originalRuleEnvironment(task)` 复用同一个任务、截止时间、会话及现有 JVM HTTP 客户端，执行当前已支持的静态请求；返回原 `StrResponse`、OkHttp 响应及重复头字段。未支持的动态 URL／选项继续明确报错，不另建请求解析器或 Swift 回退。环境关闭会拒绝晚结果；它不承诺立即中止已经运行的宿主调用，调用仍受原任务截止时间约束。

本段实际 Windows JDK 21 回归为新增 8、原协调器 18、现有 HTTP 12，共 38 方法／38 执行，失败、错误和跳过均为零；普通 `runtimeJar`／`runtimeSmoke` 也已通过。原先 37 项记录保留。此工厂仍供后续原流程显式接入，尚未新增运行时 operation 或切换 App 传统源入口；完整 `AnalyzeUrl`／`WebBook`、源状态及登录宿主仍未完成。它不构成 iOS／JNI／真实书源或完整兼容验收。

历史源码 `20f4cd6` 的 URL 首段保留原 `@js/<js>` → `{{…}}` → 页组选项顺序和 `@result`，原 `RuleAnalyzer` 使用第一个结束分隔符的 String 重载；没有自行改为平衡括号。嵌套 `java.ajax/connect` 按原版保留空 key/page/book/baseUrl 默认值，绑定真实原 Java 对象和 inline jsLib，复用同一任务、Rhino、HTTP、Cookie、绝对截止和取消。测试实际覆盖 CPU 脚本截止、caller 取消、环境关闭拒绝晚结果，以及普通 mainJs 动态 URL 仍拒绝。独立审查发现并修复了脚本可见 URL 绕过入口和嵌套 unsupported 被转换为正文的问题。

原 ZIP 两个方法通过合成构造/eval 接缝做 140 组差分，未执行完整 Android 构造器。该历史切片借助 SourceJavaHost，在 URL 展开后准备 source/login header，登录域检查及相对 URL 基址也未恢复原初始化顺序；动态 header、`option.js/bodyJs`、完整请求选项、WebBook、持久状态和 App 阅读接入均待完成。82 方法包含原 44、Rhino 25、互操作 4 和新 URL 9；普通 JAR 未包含项目测试类或 JUnit。这些结果证明当前有限桌面接线，不构成 iOS、完整书源或自动续签通过。

2026-10-20 请求选项接线已将 header 初始化放回 URL 脚本之前：source 自己的 java/source/sourceApi/baseUrl 绑定、初始 mUrl/baseUrl 的登录域判断、显式头（含空对象）整体替换、URL option header 覆盖均依原顺序执行。相对 URL、option.js/bodyJs、XML 前缀、原 query/form/escape 编码、DNS、超时和重定向已进入同一请求链；原 mainJs 和新原规则请求复用一个响应执行器，不另建 HTTP 或状态所有者。实际 114 方法、普通生产 JAR 与 smoke 均通过，JAR 中项目测试类/JUnit 泄漏为 0。

本轮更正前一段合同说明的两处过宽结论：原 `AnalyzeRule` 单参数 `ajax` 会传 `book`，`JsExtensions.ajax/connect`（含 timeout 重载）默认不继承 book；原 catch 只包 `getStrResponse` 执行，构造 URL 的 JS 异常会逸出。现已按原边界接线并增加真实回归。供后续 WebBook 的显式 requestUrl 同样让执行异常逸出，保留其登录/错误处理机会。历史82项结果只证明当时的输入，原始证据不改写，也不据此扩大当前兼容结论。

独审还修复了 header 共用库等待丢失取消、toJSON/getter 吞 typed unsupported、表单开头空字段、Unicode字符流编码、IP 分类及 null proxy 移除。新的18方法包含真实 loopback 请求、取消/关闭、异常和原对象绑定；原 ZIP 方法与 Hutool 标签向量的对照范围在新记录中逐项列明。完整 WebBook、持久状态、浏览器/代理/媒体/限流及普通 JNI/App 阅读入口仍未接齐，未进行 Android、iOS、真实站点或真机验收。

# 传统书源核心：最小接入边界

此文是源码边界核对与后续验证输入，不表示传统规则已经接入原生阅读流程，也不改变现有验收门槛。

唯一原版基准为 `F:/legado-master.zip`，SHA-256：
`724dedcac2427cd1f02ca00af1eab7156146e6d9d3141ca4c92042d04ed7bcdd`。
下述原版行号按 ZIP 内原始 UTF-8 文本计算，路径均相对于 `app/src/main/java/io/legado/app/`。
本次只读取该源码档案及仓库代码，未读取或输出私人书源内容。

用户提供的书源统计为 1,331 项、0 项 `mainJs`。**没有 `mainJs` 不代表没有 JavaScript**：传统书源的 URL、header 和各字段规则仍可包含 JS。尚不能据此推断任何兼容率。

## 已有实现与缺口

| 部分 | 当前事实 |
| --- | --- |
| 六个底层解析文件 | `jvm/src/main/kotlin/io/legado/app/model/analyzeRule/` 已有 `RuleAnalyzer`、`AnalyzeByJSoup`、`AnalyzeByXPath`、`AnalyzeByJSonPath`、`AnalyzeByRegex`、`SourceHtmlParser`。原始文件及 SHA 存于 `vendor/manifest.json`。 |
| `DeclarativeSource` | 是有限编排原型；支持部分静态请求及 CSS/XPath/JSONPath/正则。明确拒绝字段 `@js:`、`<js>`、`<webJs>`、`##`、`@put:`、`@get:`、`{{…}}`，动态 URL 也未迁移。 |
| `StaticRuleReplacement` | 只覆盖空选择器静态标量替换，明确未连接 `DeclarativeSource`。不能据此声称完整 `AnalyzeRule` 已迁移。 |
| `SourceJavaHost` | 是有限宿主适配器；部分 `java.get/head/post`、动态 header/URL、proxy 等明确返回 unsupported，不能替代原版全部 `JsExtensions`。 |

上述仓库路径均以 `Packages/LegadoRuntime/` 为前缀。现有 `DeclarativeSourceTest` 仅证明固定 CSS 四步链路、几个底层解析调用及 unsupported 错误，不证明真实书源可用。

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

## 已确认的 JSONPath 行为差异

当前 `AnalyzeByJSonPath.kt` 的三处 catch（原版 53–54、90–91、140–141 附近）将：

```kotlin
onError?.invoke(e) ?: e.printOnDebug()
```

改为无 handler 时直接 `throw e`。这会改变找不到路径／无效表达式与组合规则的失败、返回及 fallback 行为。
这是一项已知差异；不能仅因正常路径测试通过就忽略，也不能用 `try?`、返回空库或通用空字符串掩盖。须加入原 Android 对照负例，明确比较结果和异常后再决定保持原行为的适配方式。
其余可见适配包括去除 `@Keep`，XPath 的 `TextUtils.join` 改为 `joinToString`；原 `RuleAnalyzer` 与 `SourceHtmlParser` 的文本逻辑保持一致。

## 首批可独立验证的链路

1. **静态完整阅读链路**：固定响应的搜索 → 详情 → 目录 → 正文，分别使用 CSS、XPath、JSONPath、正则；覆盖 `&&/||/%%`、索引、`text/textNodes/html`、`##` 替换、实体、重定向基址和相对 URL。保留原 selector → 结果转换 → 替换的顺序，不能只测单个 helper。
2. **传统规则中的 JS 与状态**：同一链路加入字段 `@js:`、`{{…}}`、`@put/@get`、捕获组、Java 字符串／集合；覆盖 URL JS、页码分支、动态 header 和 POST 编码。记录每步变量、Cookie、异常和缓存变化，验证并发会话隔离。
3. **原业务编排**：目录分页／重复章节、正文 `nextContentUrl`／净化、登录和浏览器取消；再进入批量正文、字体及扩展功能。前两步通过不能替代这些范围。

优先复用 ZIP 中 `app/src/test/java/io/legado/app/` 的现成输入：

- `model/webBook/SourceContentCompatibilityTest.kt`：文本节点、替换、JS/Base64、章节身份及目录显示顺序。
- `model/analyzeRule/AnalyzeRuleElementsNormalizationTest.kt`：元素结果归一化。
- `model/analyzeRule/AnalyzeByJSoupDomTest.kt`：DOM／选择器兼容行为。
- `model/analyzeRule/AnalyzeUrlLoginHeaderContractTest.kt`、`AnalyzeUrlNetworkOptionsTest.kt`：登录头域与网络选项。

每组均以锁定 Android 原实现产生 golden，再比较 iOS JVM 的请求字节、完整输出、变量、Cookie、异常与缓存变化。新建合成向量应标明来源和覆盖范围，不能把相同自制 helper 的两次输出当作原版一致性证明。

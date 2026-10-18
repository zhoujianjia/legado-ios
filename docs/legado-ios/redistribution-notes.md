# 再分发与许可记录

审计日期：2026-10-18。审计起点为 `5a272190fda65fa7ebababc919f0399c71f2b459`，品牌清理已在 `b1607881a27135b06d6945af380a19f22dbe1daf` 完成。本文记录实际文件和待办，**不是法律许可证明，也不能保证零法律风险**。许可组合和对应源码义务尚未完成核验，当前暂不分发任何安装包。

用户已决定只维护一个最终版本，继续现有原生界面与 JVM 原核心兼容路线，不拆分个人与亲友构建。今后安装包均不内置书源，由用户自行导入。手机已有书源、书籍及历史本地包不删除；过去的本地书源注入是历史做法，已停止。

逐文件哈希、来源、已编译类样本、截图路径及未解决项见 [机器清单](redistribution-inventory.json)。本次审计未修改任何原许可头、`LICENSE`、`LICENSING.md`、`TRADEMARKS.md`、`NOTICE` 或 Git 历史。

## 个人使用、亲友分享、公开源码与 IPA

| 场景 | 实际含义与处理 |
| --- | --- |
| 只在自己的设备自签使用 | 私下使用、修改通常不触发向公众提供源码的义务；仍应保留收到的许可、来源及声明。自签不等于已经获准公开发行。[Mozilla FAQ Q5–Q6](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)、[GNU FAQ：私下修改](https://www.gnu.org/licenses/gpl-faq.en.html#GPLRequireSourcePostedPublic) |
| 公开 fork 源码 | 已是向他人提供副本，需要保留受覆盖文件的许可和署名，标明第三方分区；公开仓库中的图标、截图也需要单独处理。不能因代码免费而推定品牌免费。[MPL 2.0 §2.3、§3.1、§3.4](https://www.mozilla.org/en-US/MPL/2.0/) |
| 小范围给亲友安装 | 当前同样暂停。若未来恢复，也是向他人提供副本，接收者需要许可及相应源码获取方式；不能拿“免费、几个人”当作许可豁免。这不构成另一种产品或构建路线。 |
| 公开 IPA 或 Actions artifact | 属于可执行物再分发；未签名并不能免除义务。应给接收者提供与该二进制准确对应的受覆盖源码、改动和构建资料，并落实各许可要求；仓库链接指向持续变化的 `main` 不足以证明对应关系。[MPL 2.0 §3.2](https://www.mozilla.org/en-US/MPL/2.0/)、[GNU FAQ](https://www.gnu.org/licenses/gpl-faq.en.html) |

给另一个人安装或开放下载，也不能仅因人数少而自动当成纯粹自用。是否收费与是否分发是两回事。此前的公开 fork 和云端 artifact 已经存在，改成私有、换名字或删除当前文件均不能证明之前的副本不存在。

## 当前实际许可分区

| 材料 | 查到的依据 | 当前边界 |
| --- | --- | --- |
| Yuedu 原生界面及本 fork 对原文件的修改 | 已从锁定提交 `409b82c731393bcbf8aa1233976c7ef482ec764e` 取得 `LICENSE`、`LICENSING.md`、`TRADEMARKS.md`、`NOTICE`，四个文件均与本机原始字节相同。根许可为 MPL-2.0。 | 继续保留 MPL、版权和例外许可。`LICENSING.md` 对历史 MIT 的截止提交是 `87ffc527…`，不能把当前锁定版本整体当成 MIT。[本地说明](../../LICENSING.md)、[历史 MIT 文本](../../LICENSES/MIT.txt) |
| 已进入普通 JVM 源集的 Legado 文件 | `legado-master.zip` SHA 与锁定值一致；原版 `LICENSE` 为 GPL 第 3 版文本，已保留在 [vendor/LICENSE](../../Packages/LegadoRuntime/vendor/LICENSE)。36 个有原版清单对应的普通源码文件均已跟踪。 | 其中 24 个未见独立许可头，暂按归档 GPLv3 默认范围管理，`only/or-later` 和个别文件权属仍需核实；10 个 Java 文件有明确 MPL-2.0 头；另 2 个见下一行。不能用根 MPL 覆盖它们。[来源清单](../../Packages/LegadoRuntime/vendor/manifest.json) |
| `RhinoWrapFactory.kt`、`RhinoClassShutter.kt` | 两个原版及当前文件都保留 Oracle 的 GPL-2.0-only 和 Classpath 例外头。 | 必须单独保留 GPLv2、适用例外和修改来源，不统一改成 GPLv3；例外只按实际授权范围判断。[WrapFactory](../../Packages/LegadoRuntime/jvm/src/main/kotlin/com/script/rhino/RhinoWrapFactory.kt)、[ClassShutter](../../Packages/LegadoRuntime/jvm/src/main/kotlin/com/script/rhino/RhinoClassShutter.kt) |
| 新增静态替换/标量选择片段 | [StaticRuleReplacement](../../Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/StaticRuleReplacement.kt) 和 [StaticScalarSelectorRule](../../Packages/LegadoRuntime/jvm/src/main/kotlin/io/yuedu/legado/StaticScalarSelectorRule.kt) 已在注释标出原版来源与 GPLv3 许可。 | 不能仅因移动文件、改名或用 Swift/JNI 包装就认定已经脱离原许可。新 `original-rule` 协调器仍为未提交工作，不混入已交付版本的结论。 |
| 定制 `htmlunit-core-js 5.3.0-legado.4` | [SOURCE.md](../../Packages/LegadoRuntime/vendor/licenses/htmlunit-core-js/5.3.0-legado.4/SOURCE.md) 锁定包装/Rhino 提交、JAR SHA、差异和构建命令。引擎正文为 MPL-2.0，并有第三方声明。 | POM 的 Apache-2.0 声明不能替代引擎实际许可。已保存的说明/差异不等于完整对应源码闭包已验证。[原引擎许可说明](../../Packages/LegadoRuntime/vendor/licenses/htmlunit-core-js/5.3.0-legado.4/LICENSE-core-js.txt) |
| OpenJDK Mobile、ios-tools、libffi | [运行时锁定](../../scripts/legado-ios/runtime-lock.json) 和 [构建脚本](../../scripts/legado-ios/build-zero.sh) 保留精确提交、补丁及许可复制步骤。历史原生样本的 `LICENSE` 为 GPLv2，`ADDITIONAL_LICENSE_INFO` 明确只有特定文件适用 Classpath 例外；libffi 有独立许可。 | 公开包仍须核查实际静态链接对象和 13 个模块的许可、例外、补丁和对应源码。**不能把 JDK 的例外扩展给 Legado GPLv3 代码。**[GNU Classpath 例外说明](https://www.gnu.org/software/classpath/license.html) |
| 新增字体与其余第三方依赖 | 两种字体有 [来源与哈希](../../Resources/ReaderFonts/ReaderFonts-provenance.json)：霞鹜文楷轻便版为 OFL，霞鹜新致宋附 IPA Font License。依赖版本另见 [Dependencies](../../Technotes/Dependencies.md) 和各 vendor 清单。 | 保留各自文本及传递依赖声明。此次没有完成所有字体、样书、封面、数据、SDK 和传递依赖的权利审查，不能把此表当完整 SBOM 或授权证书。 |

已直接查看本机 build 7 IPA 内的普通 `legado-runtime.jar`，确认 `AnalyzeByJSonPath`、`RhinoScriptEngine`、`StaticRuleReplacement` 及引擎类真实存在，同时有 Legado GPL 和 HtmlUnit/Rhino 许可记录；没有读取私人书源内容。这说明问题已涉及二进制，不能仅说“GPL 文件只是开发参考、不参与发行”。哈希和类路径在机器清单中。

## MPL 与 GPL 的组合尚未解决

MPL §3.3 和 Mozilla 指南允许在满足条件时与 GPL 构成较大作品，包括检查是否带有不兼容次级许可的声明，并履行所涉及许可的分发条件。这是可研究的合规路径，**不是看见 MPL-2.0 就自动获准把整个工程换成 GPL，也不是允许把 GPL-only 代码直接粘入需要继续以 MPL 提供的原文件。**[Mozilla 组合指南](https://www.mozilla.org/en-US/MPL/2.0/combining-mpl-and-gpl/)

当前应用把原生界面、JNI、静态 JVM 和解析 JAR 一起打包，接口深入交换执行状态。仅有“不同文件、不同语言、JAR、动态调用或 JNI”不能证明是无关程序的简单聚合。作品边界、MPL 次级许可条件、GPLv2+例外分区以及完整二进制的许可方案仍未确定；本次不宣布组合一定合法或一定不合法。[GNU FAQ：聚合与组合](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation)

可完成的措施是逐文件保留原许可分区，列出修改和来源，锁定每个发行提交，提供与该提交对应的源码、依赖源获取记录、JDK/引擎补丁及自签构建安装说明。只有许可文本和 SHA 清单并不能代替相应源码义务。若要继续公开发行含 GPL 的完整包，应在这个具体材料包上审查整体方案；不能通过删署名或重写 `LICENSE` 绕过。

## 品牌与图片清理

上游 [TRADEMARKS.md](../../TRADEMARKS.md) 将名称、特定“閱讀”字标、图标、Logo、截图和宣传图与代码许可分开，并要求公开修改版使用独立名称、图标与 bundle ID。准确的来源致谢可以保留，不应删掉真实作者和 [NOTICE](../../NOTICE)。

当前树已完成独立名称、几何绘制图标、10 处 bundle ID、分享扩展和网站说明替换，并保留生成脚本及 [品牌来源记录](../../Resources/Branding/brand-assets.json)。旧 Logo、YueduAppIcon 和三张旧 AppIcon 对应的 10 个文件已移除，路径/哈希记在 [移除记录](../../Resources/Branding/removed-upstream-assets.json)。清单不是商标检索结果，独立图案或名称也不自动等于完成商标核查；当前源码的变化还需通过后续构建核实。

上游 UI 截图/动画 34 个也已从当前树移除：`docs/demo/` 10 个、`docs/performance/20260907-comment-bubbles/` 8 个、`docs/browser-layout/` 16 个，逐项哈希见 [截图移除记录](../../Resources/Branding/removed-upstream-screenshots.json)。与品牌资源合计完成 44 个文件的当前树清理；历史审计机器清单保留采集时状态，不追改原证据。**不包含 EPUB 回归夹具里的测试 Logo/标记图片。**启动图叠层使用用户自己选择的图片，本轮未发现必须保留的默认上游启动海报。

Git 历史、已下载 IPA 和既有云端 artifact 没有被重写或删除。当前树清理完毕也不证明旧版本可继续公开；应逐个处理旧分发入口，必要时与权利人确认，不自动清理用户历史数据。

## 未来恢复分发前仍需完成

1. 完成 MPL/GPL/Classpath 分区和整体再分发方案；保留全部原许可与修改归属。
2. 以实际 IPA 哈希对应不可变源码提交，补齐引擎、JDK 及修改的来源/构建/安装资料；复核二进制里的声明，不只查看仓库。
3. 核实新构建实际采用已完成的品牌、bundle ID 和资源清理，并单独处置历史 artifact/旧下载入口；不得宣称获得上游官方支持。
4. 补全传递依赖、字体、数据、样书/封面等清单；所有后续安装包均不内置书源，私人源和固定认证值不进入源码、包或日志。已有设备数据与历史本地包保持，不据此新增注入流程。

目前继续同一个版本的 Legado 兼容开发与已有设备试读，暂不分发。独立品牌清理已经完成，MPL/GPL/Classpath 组合及相应源码义务仍待核验，后续是否恢复分发另行决定。

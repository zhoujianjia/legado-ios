# 固定书源状态用例的 JVM 对照工具

对原 Android 观测的同一组公开输入重放：14 场景、56 个有序步骤、47 次公开 API 调用。它不接入阅读路由，也不修改产品代码。

需要 Python 3.10+、Git、JDK 21、Gradle 8.14.3。临时工程使用 Kotlin 2.4.20；`--offline` 要求依赖已在 Gradle 缓存中，不传时允许 Gradle 下载构建依赖。仅传入明确选择的普通 runtime JAR，不构建主项目。

从仓库根目录运行（把占位路径和 SHA 替换为本次测量的实际值）：

```text
python scripts/legado-ios/stateful-port-reference/run.py --runtime-jar PATH_TO_ORDINARY_JAR --runtime-jar-sha256 JAR_SHA256 --runtime-source-commit SOURCE_COMMIT --output-dir .build/stateful-port-reference/UNIQUE_RUN --gradle PATH_TO_GRADLE --java-home PATH_TO_JDK21 --offline
```

`--output-dir` 必须是仓库 `.build` 下全新目录；已存在时直接拒绝，不删除或覆盖旧证据。JAR SHA 为每次显式输入，不是永久固定值。原 harness、输入 fixture、Android 原始观测仍按源码中的 SHA 锁定。

工具检查 JAR 内 `original-rule` provenance 与指定 Git 提交的 manifest 和全部 `portedSources` 字节一致，核资源/许可证哈希并排除 JUnit、工程测试类和测试 fixture。独立 JVM 进程核公开类从输入 JAR 加载，类字节与该 JAR 一致。它不以来源声明代替 Android/iOS 行为验收。

`harness-adaptations.patch` 是原 Android harness 的完整适配 diff：仅替换 Android 启动/输出入口、显式注入每场景的 `RuleEnvironment`、替换平台清理接口并关闭 port 对象。`ScenarioState`、`typed`、异常观测、原始规则和顺序调用保持原观测逻辑。生成的 diff 与该文件必须完全相同才编译。

输出包含原始 `port-observed.json`、逐字段 `full-raw-differences.json`、`measurement-result.json`、来源与类加载证据、生成的 harness/diff 和编译/运行日志。所有原始字符串、数字 Java 类型、异常及 cause、变量序列化、真实节点 HTML、mutation 和对象存活证据均保留。不同进程的 identityHashCode 与平台元数据会单独标记，但不会从完整 raw diff 删除。任何异常消息差异仍计为不一致，不 trim、不更换脚本编号、不补缺失字段。

进程退出 0 表示测量和差异报告生成完成；请检查 `acceptance.allDeclaredAPICallsRawMatch`，不能将测量完成等同于兼容通过。`compatibilityValidationPassed`、iOS、真机、G4 和全功能验收始终保持 false。

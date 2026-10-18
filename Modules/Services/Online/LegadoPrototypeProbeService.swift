import Foundation
import LegadoRuntime

struct LegadoPrototypeProbeReport: Sendable {
    let available: Bool
    let bridgePresent: Bool
    let issues: [String]
    var completedSteps: [String] = []
    var elapsedMilliseconds: Double?
}

/// The first migration gate is deliberately independent of production source sessions.
/// It shares the process runtime with the reading service, using its own source session.
/// Opening Settings never starts a JVM.
actor LegadoPrototypeProbeService {
    func inspect() -> LegadoPrototypeProbeReport {
        SourcePerfTrace.span("legado.prototype.inspect", "main=\(Thread.isMainThread)") {
            let diagnostics = LegadoRuntime.diagnose(configuration: .bundled())
            return LegadoPrototypeProbeReport(
                available: diagnostics.available,
                bridgePresent: diagnostics.nativeBridgePresent,
                issues: diagnostics.issues
            )
        }
    }

    func run() async throws -> LegadoPrototypeProbeReport {
        let started = SourcePerfTrace.now
        var report = inspect()
        guard report.available else {
            throw LegadoRuntimeError(code: "missing_runtime", message: report.issues.joined(separator: "\n"))
        }
        let executor = try await LegadoRuntimeProcess.shared.executor()
        let session = try await executor.createSession(sourceJSON: Self.fixtureSource)
        do {
            report.completedSteps.append("Legado 工作階段")
            let search: [FixtureBook] = try await execute(
                executor, session: session, operation: "search", request: SearchRequest(key: "本地驗證", page: 1)
            )
            guard let book = search.first, book.name == "本地驗證" else { throw Self.mismatch("search") }
            report.completedSteps.append("Legado 搜索")
            let details: FixtureBook = try await execute(
                executor, session: session, operation: "details", request: BookRequest(book: book)
            )
            guard details.bookUrl == book.bookUrl else { throw Self.mismatch("details") }
            report.completedSteps.append("Legado 詳情")
            let chapters: [FixtureChapter] = try await execute(
                executor, session: session, operation: "toc", request: BookRequest(book: details)
            )
            guard let chapter = chapters.first, chapters.count == 2 else { throw Self.mismatch("toc") }
            report.completedSteps.append("Legado 目錄")
            let content: String = try await execute(
                executor, session: session, operation: "content",
                request: ContentRequest(chapter: chapter, book: details, nextChapterUrl: chapters[1].chapterUrl)
            )
            guard content == "本地正文：第一章" else { throw Self.mismatch("content") }
            report.completedSteps.append("Legado 正文")
            let xml: String = try await execute(
                executor, session: session, operation: "evaluate",
                request: ScriptRequest(script: "var probeXml = <root><item>ok</item></root>; probeXml..item.toString();")
            )
            guard xml == "ok" else { throw Self.mismatch("E4X") }
            report.completedSteps.append("Legado E4X 語義")
            try await executor.close(session: session)
        } catch {
            do { try await executor.close(session: session) }
            catch { AppLogger.parse("Legado prototype session cleanup failed: \(error.localizedDescription)") }
            throw error
        }
        try Task.checkCancellation()
        report.elapsedMilliseconds = (SourcePerfTrace.now - started) * 1000
        SourcePerfTrace.record("legado.prototype.pipeline", "main=\(Thread.isMainThread) steps=\(report.completedSteps.count)", since: started)
        return report
    }

    private func execute<Request: Encodable, Value: Decodable>(
        _ runtime: LegadoRuntime, session: LegadoSourceSession, operation: String, request: Request
    ) async throws -> Value {
        try Task.checkCancellation()
        let requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = try await runtime.execute(session: session, operation: operation, requestJSON: requestJSON)
        return try JSONDecoder().decode(ResultEnvelope<Value>.self, from: Data(response.utf8)).result
    }

    private static func mismatch(_ stage: String) -> LegadoRuntimeError {
        LegadoRuntimeError(code: "fixture_mismatch", message: "Local fixture mismatch at \(stage)")
    }

    private struct ResultEnvelope<Value: Decodable>: Decodable { let result: Value }
    private struct FixtureBook: Codable { let bookUrl: String; let name: String; let author: String }
    private struct FixtureChapter: Codable { let chapterUrl: String; let title: String }
    private struct SearchRequest: Encodable { let key: String; let page: Int }
    private struct BookRequest: Encodable { let book: FixtureBook }
    private struct ContentRequest: Encodable { let chapter: FixtureChapter; let book: FixtureBook; let nextChapterUrl: String }
    private struct ScriptRequest: Encodable { let script: String }

    // A synthetic, network-free source exercises the actual mainJs entry points.
    // This is a smoke gate, not evidence of compatibility with every real source.
    private static let fixtureSource = #"""
    {
      "bookSourceUrl":"https://legado-prototype.invalid",
      "bookSourceName":"Local runtime probe",
      "mainJs":"var config = {name:'Local runtime probe'}; function search(key,page){return [{bookUrl:'fixture:book',name:key,author:'Fixture'}]}; function getBookInfo(book){return book}; function getChapters(book){return [{chapterUrl:'fixture:1',title:'第一章'},{chapterUrl:'fixture:2',title:'第二章'}]}; function getContent(chapter,book,nextChapterUrl){return '本地正文：'+chapter.title};"
    }
    """#
}

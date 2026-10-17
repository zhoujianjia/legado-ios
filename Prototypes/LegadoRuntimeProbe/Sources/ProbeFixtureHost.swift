import Foundation
import LegadoRuntime

/// All responses are synthetic; this host deliberately has no network implementation.
actor ProbeFixtureHost: LegadoPlatformHost {
    private var captures: [[String: String]] = []
    private var readiness: [String: AsyncStream<Bool>.Continuation] = [:]
    private let base = "https://fixture.invalid"

    func reset() { captures.removeAll() }
    func capturedRequests() -> [[String: String]] { captures }
    func cancellationSignal(taskID: String) -> AsyncStream<Bool> {
        let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        readiness[taskID] = pair.continuation
        return pair.stream
    }
    func executionEnded(taskID: String) {
        readiness.removeValue(forKey: taskID)?.finish()
    }
    func cancel(taskID: String) async {}

    func dispatch(_ request: LegadoHostRequest) async throws -> String {
        guard request.operation == "http.request" else {
            throw LegadoRuntimeError(code: "PROBE_UNSUPPORTED_HOST", message: request.operation)
        }
        struct Input: Decodable { let url: String; let method: String?; let headers: LegadoHTTPHeaders?; let bodyBase64: String? }
        let input = try JSONDecoder().decode(Input.self, from: Data(request.requestJSON.utf8))
        guard input.url.hasPrefix(base + "/") else { throw failure("Unexpected fixture URL: \(input.url)") }
        let path = String(input.url.dropFirst(base.count))
        captures.append(["url": input.url, "method": input.method ?? "GET", "bodyBase64": input.bodyBase64 ?? "",
                         "cookie": input.headers?.entries.first(where: { $0.name.lowercased() == "cookie" })?.value ?? "",
                         "authorization": input.headers?.entries.first(where: { $0.name.lowercased() == "authorization" })?.value ?? ""])
        let text: String
        var headers: [String: Any] = [:]
        switch path {
        case "/login":
            guard input.method == "POST", let encoded = input.bodyBase64,
                  Data(base64Encoded: encoded) == Data("name=reader&password=%E4%B9%A6".utf8) else {
                throw failure("Login request bytes differ from fixture")
            }
            text = "ok"; headers["Set-Cookie"] = ["sid=fixture; Path=/; HttpOnly"]
        case "/search?key=%E4%B9%A6&page=1":
            guard input.headers?.entries.first(where: { $0.name.lowercased() == "cookie" })?.value == "sid=fixture",
                  input.headers?.entries.first(where: { $0.name.lowercased() == "authorization" })?.value == "Bearer fixture" else {
                throw failure("Source login/Cookie state was not preserved")
            }
            text = "{\"books\":[{\"name\":\"Fixture\",\"bookUrl\":\"\(base)/book/1\"}]}"
        case "/book/1": text = "<p id='intro'>Introduction</p><a id='toc' href='/toc/1'>TOC</a>"
        case "/toc/1": text = "[{\"index\":0,\"title\":\"One\",\"url\":\"\(base)/chapter/1\"},{\"index\":1,\"title\":\"Two\",\"url\":\"\(base)/chapter/2\"}]"
        case "/chapter/1": text = "第一章\ncontent one"
        case "/chapter/2": text = "第二章\ncontent two"
        case "/cancel-ready":
            if let signal = readiness.removeValue(forKey: request.taskID) { signal.yield(true); signal.finish() }
            text = "ready"
        default: throw failure("No fixture for \(path)")
        }
        let response: [String: Any] = ["status": 200, "url": input.url, "headers": headers, "bodyBase64": Data(text.utf8).base64EncodedString()]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    }
    private func failure(_ text: String) -> LegadoRuntimeError { LegadoRuntimeError(code: "PROBE_FIXTURE_MISMATCH", message: text) }
}

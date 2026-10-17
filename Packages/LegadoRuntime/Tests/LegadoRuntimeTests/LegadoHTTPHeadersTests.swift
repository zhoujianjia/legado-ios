import Foundation
import XCTest
@testable import LegadoRuntime

@MainActor final class LegadoHTTPHeadersTests: XCTestCase {
    func testOrderedHeaderRoundTripKeepsNamesValuesOrderAndDuplicates() throws {
        let json = #"[{"name":"Connection","value":"close"},{"name":"Keep-Alive","value":"300"},{"name":"connection","value":"Keep-Alive"}]"#
        let headers = try JSONDecoder().decode(LegadoHTTPHeaders.self, from: Data(json.utf8))
        XCTAssertEqual(headers.entries.map(\.name), ["Connection", "Keep-Alive", "connection"])
        XCTAssertEqual(headers.values(for: "CONNECTION"), ["close", "Keep-Alive"])
        XCTAssertEqual(try JSONDecoder().decode(LegadoHTTPHeaders.self, from: JSONEncoder().encode(headers)), headers)
    }

    func testLegacySingleValueObjectStillDecodesAndSerializesToEntries() throws {
        let headers = try JSONDecoder().decode(LegadoHTTPHeaders.self, from: Data(#"{"Accept":"*/*","User-Agent":"fixture"}"#.utf8))
        XCTAssertEqual(headers.values(for: "accept"), ["*/*"])
        XCTAssertEqual(try headers.urlSessionFields(), ["Accept": "*/*", "User-Agent": "fixture"])
        XCTAssertTrue(try JSONSerialization.jsonObject(with: JSONEncoder().encode(headers)) is [[String: String]])
    }

    func testMalformedArrayDoesNotBecomeAnEmptyOrLegacyHeaderMap() {
        for json in [#"[{"name":"Accept","value":3}]"#, #"[{"name":"Accept"}]"#, #"["bad"]"#, "3"] {
            XCTAssertThrowsError(try JSONDecoder().decode(LegadoHTTPHeaders.self, from: Data(json.utf8)))
        }
    }

    func testURLSessionRejectsRepeatedNamesEvenWhenCaseOrValuesDiffer() {
        for entries in [
            [LegadoHTTPHeader(name: "Connection", value: "close"), .init(name: "Connection", value: "Keep-Alive")],
            [LegadoHTTPHeader(name: "X-Token", value: "same"), .init(name: "x-token", value: "same")]
        ] {
            XCTAssertThrowsError(try LegadoHTTPHeaders(entries: entries).urlSessionFields()) { error in
                XCTAssertEqual((error as? LegadoRuntimeError)?.code, "unsupported_duplicate_headers")
            }
        }
    }

    func testInvalidHeaderLinesAreRejectedInsteadOfEnteringURLRequest() {
        for entry in [LegadoHTTPHeader(name: "Bad:Name", value: "x"), .init(name: "", value: "x"),
                      .init(name: "X-Test", value: "x\r\nInjected: y")] {
            XCTAssertThrowsError(try LegadoHTTPHeaders(entries: [entry]).urlSessionFields()) { error in
                XCTAssertEqual((error as? LegadoRuntimeError)?.code, "invalid_http_header")
            }
        }
    }

    func testRealURLSessionAdapterRejectsDuplicateLinesBeforeAnyNetworkRequest() async {
        let host = URLSessionLegadoHost()
        let request = LegadoHostRequest(taskID: "duplicates", operation: "http.request", requestJSON:
            #"{"url":"https://must-not-contact.invalid/","method":"GET","headers":[{"name":"Connection","value":"close"},{"name":"Connection","value":"Keep-Alive"}]}"#)
        do {
            _ = try await host.dispatch(request)
            XCTFail("A lossy URLSession request must not report success")
        } catch {
            XCTAssertEqual((error as? LegadoRuntimeError)?.code, "unsupported_duplicate_headers")
        }
    }

    func testAdapterPreCancellationAndDeadlineRemainEffectiveForOrderedRequests() async {
        let host = URLSessionLegadoHost()
        await host.cancel(taskID: "cancelled")
        let headers = #"[{"name":"Accept","value":"*/*"}]"#
        let json = #"{"url":"https://must-not-contact.invalid/","headers":\#(headers)}"#
        do {
            _ = try await host.dispatch(.init(taskID: "cancelled", operation: "http.request", requestJSON: json))
            XCTFail("Pre-cancelled work must not start")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await host.dispatch(.init(taskID: "expired", operation: "http.request",
                requestJSON: #"{"url":"https://must-not-contact.invalid/","deadlineEpochMs":1,"headers":\#(headers)}"#))
            XCTFail("Expired work must not start")
        } catch { XCTAssertEqual((error as? LegadoRuntimeError)?.code, "host_timeout") }
    }
}

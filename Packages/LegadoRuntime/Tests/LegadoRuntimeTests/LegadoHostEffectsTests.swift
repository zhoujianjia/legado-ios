import Foundation
import XCTest
@testable import LegadoRuntime

final class LegadoHostEffectsTests: XCTestCase {
    func testRequestCopiesShareBoundedIssuedFactsAndHostErrorCodecKeepsThem() throws {
        let request = LegadoHostRequest(taskID: "cookie-task", operation: "cookie.owner.text", requestJSON: "{}")
        let pending = request
        pending.recordPossibleEffect("webKitCookieMutationIssued")
        pending.recordPossibleEffect("webKitCookieMutationIssued")
        XCTAssertEqual(request.possibleEffects, ["webKitCookieMutationIssued"])
        let success = LegadoHostErrorCodec.attachingEffects("{\"committed\":true}", effects: request.possibleEffects)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(success.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["hostEffects"] as? [String], ["webKitCookieMutationIssued"])
        let timedOut = LegadoHostErrorCodec.encode(code: "host_timeout", message: "Callback has not returned", completedEffects: request.possibleEffects)
        struct Failure: Decodable { let error: LegadoRuntimeError }
        let error = try JSONDecoder().decode(Failure.self, from: Data(timedOut.utf8)).error
        XCTAssertEqual(error.code, "host_timeout")
        XCTAssertEqual(error.completedEffects, ["webKitCookieMutationIssued"])
        for index in 0..<100 { pending.recordPossibleEffect("effect-\(index)") }
        XCTAssertEqual(request.possibleEffects.count, 32)
        let sealed = request.closePossibleEffects()
        XCTAssertEqual(sealed.count, 32)
        XCTAssertFalse(pending.recordPossibleEffect("late-old-operation"))
        XCTAssertEqual(request.possibleEffects, sealed)
        let other = LegadoHostRequest(taskID: "next-task", operation: "cookie.owner.text", requestJSON: "{}")
        XCTAssertTrue(other.possibleEffects.isEmpty)
        // Timeout first: no later Host child can claim its first mutation. The
        // next request has a separate gate, never reopened by the old callback.
        XCTAssertEqual(other.closePossibleEffects(), [])
        XCTAssertFalse(other.recordPossibleEffect("webKitCookieMutationIssued"))
        XCTAssertTrue(other.possibleEffects.isEmpty)
    }
    func testMalformedHostResponseRetainsIssuedFactsAndEmptyEffectsPreserveOldResponses() throws {
        XCTAssertEqual(LegadoHostErrorCodec.attachingEffects("{}", effects: []), "{}")
        struct Failure: Decodable { let error: LegadoRuntimeError }
        for raw in ["[]", "not JSON"] {
            let wrapped = LegadoHostErrorCodec.attachingEffects(raw, effects: ["webKitCookieMutationIssued"])
            let result = try JSONDecoder().decode(Failure.self, from: Data(wrapped.utf8)).error
            XCTAssertEqual(result.code, "host_failure")
            XCTAssertEqual(result.completedEffects, ["webKitCookieMutationIssued"])
        }
    }
}

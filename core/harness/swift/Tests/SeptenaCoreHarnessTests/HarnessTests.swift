import Foundation
import SeptenaSharedCore
import XCTest

/// Runs every `registry/conformance/*.json` file through the packaged core and
/// calls a few typed functions, so records, enums, options and errors cross
/// the Swift boundary. `SEPTENA_CONFORMANCE` names the fixture directory.
final class HarnessTests: XCTestCase {
    func testVectorsThroughThePackagedCore() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SEPTENA_CONFORMANCE"], "set SEPTENA_CONFORMANCE")
        let files = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)

        var times: [Double] = []
        var cases: UInt32 = 0
        for file in files {
            let fixture = file.deletingPathExtension().lastPathComponent
            let json = try String(contentsOf: file, encoding: .utf8)
            for round in 0..<50 {
                let start = DispatchTime.now().uptimeNanoseconds
                let report = try runConformance(fixture: fixture, json: json)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                XCTAssertEqual(report.failures, [], fixture)
                if round == 0 { cases += report.cases }
            }
        }

        XCTAssertEqual(occurrenceId(sourceTaskId: "task-1", scheduled: "2026-11-22"), "recur-27f6e5d56dadf4cc")
        XCTAssertEqual(rowOpacity(fill: 0.5), 0.775, accuracy: 1e-9)
        XCTAssertEqual(rowOpacity(fill: nil), 1.0)
        let page = checkPullPage(cursor: 10, page: PullPageHeader(resetRequired: false, nextSince: 20, hasMore: true), resetsSoFar: 0)
        guard case .applyAndContinue(let next) = page else { return XCTFail("expected applyAndContinue, got \(page)") }
        XCTAssertEqual(next, 20)
        XCTAssertThrowsError(try planPullRow(entity: "turn", rowJson: "{\"seq\":1}", currentFieldsJson: nil, pendingFields: [], pendingDelete: false))

        times.sort()
        let p95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        print("SEPTENA_CORE_METRICS platform=macos-\(Self.arch) cases=\(cases) calls=\(times.count) p95_ms_per_fixture=\(String(format: "%.3f", p95))")
        XCTAssertLessThanOrEqual(p95, 5.0, "p95 per fixture run is over the 5 ms budget")
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

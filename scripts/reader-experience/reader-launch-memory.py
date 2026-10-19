#!/usr/bin/env python3
"""Validate separate launch/memory observation shapes, never attest SDK execution.

Run only on retained logs from the two new selections. This does not change the
existing reader-stage, smoke or release protocols. Actual passing xcresult leaf
identities, source/build/overlay and Xcode/SDK/runtime metadata must be bound by
the future runner before anyone accepts these as measured app observations.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics

LAUNCH = "READER_PROCESS_LAUNCH "
MEMORY = "READER_PROCESS_MEMORY "
PHASE = "READER_PROCESS_MEMORY_EVENT "
STAGES = ["baseline", "document.begin", "document.end", "first-page.begin", "first-page.end",
          "pagination.begin", "pagination.end", "scroll.begin", "scroll.end"] + [
              "jump.%d.%s" % (i, edge) for i in range(10) for edge in ("begin", "end")] + ["complete"]
TIMES = ["terminateRequested", "notRunningObserved", "launchRequested", "launchReturned",
         "shelfObserved", "bookTapRequested", "pageObserved"]


def require(value, message):
    if not value:
        raise ValueError(message)


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def strict_json(text):
    def pairs(entries):
        value = {}
        for key, item in entries:
            require(key not in value, "duplicate JSON key")
            value[key] = item
        return value
    def constant(value):
        raise ValueError("nonfinite JSON constant: " + value)
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def utf16(text):
    return len(text.encode("utf-16-le")) // 2


def rows(raw, marker):
    require(len(raw) <= 64 * 1024**2, "log exceeds 64MiB")
    result = []
    for line in raw.decode("utf-8").splitlines():
        if marker not in line:
            continue
        require(line.count(marker) == 1, "ambiguous row marker")
        text = line.split(marker, 1)[1]
        require(len(text.encode("utf-8")) <= 8 * 1024**2, "observation row exceeds 8MiB")
        value = strict_json(text)
        require(type(value) is dict, "observation must be an object")
        result.append(value)
    return result


def fixture_protocol():
    # Independent reconstruction of the two owned plain fixtures, including the
    # existing document()/paragraphs() whitespace. No importer/renderer is added.
    unit = "讀書使人充實，思考使人深邃，交談使人清醒。"
    paragraph = (unit * ((256 + len(unit) - 1) // len(unit)))[:256]
    result = {}
    for identity, title, minimum in (("plain-100k", "Plain 100K", 102_400), ("plain-1m", "Plain 1M", 1_048_576)):
        body = ("<p>" + paragraph + "</p>\n") * ((minimum + 255) // 256)
        html = ('<!doctype html>\n<html xmlns="http://www.w3.org/1999/xhtml"\n'
                '      xmlns:epub="http://www.idpf.org/2007/ops">\n  <head>\n'
                '    <meta charset="utf-8"/>\n    <title>' + title + '</title>\n'
                '    \n  </head>\n  <body>' + body + '</body>\n</html>').encode()
        result[identity] = {"fixtureSHA256": hashlib.sha256(html).hexdigest(),
                            "fixtureHTMLBytes": len(html), "fixtureMinimumUTF16": minimum}
    return result


def launch_fixture_protocol():
    chapters = [("第一章 出發", "LOCAL_READER_SMOKE_OPENING"), ("第二章 渡河", "LOCAL_READER_SMOKE_CROSSING"),
                ("第三章 林間", "LOCAL_READER_SMOKE_RESUME"), ("第四章 歸途", "LOCAL_READER_SMOKE_RETURN")]
    text = "\n\n".join(title + "\n\n" + "\n\n".join(
        "%s_P%04d. The traveller follows the path beside the river, records the day's journey, and reads the map before continuing." % (marker, i)
        for i in range(10)) for title, marker in chapters).encode()
    return {"fixtureSHA256": hashlib.sha256(text).hexdigest(), "fixtureBytes": len(text)}


def literal_flags(row, flags):
    for key, expected in flags.items():
        require(row.get(key) is expected, "flag differs: " + key)


def page(value, marker):
    require(type(value) is dict and type(value.get("schemaVersion")) is int and value["schemaVersion"] == 1, "page schema differs")
    require(value.get("boundary") == "cpu-layer-submitted-and-ax-readable", "page boundary differs")
    for key in ("processID", "viewBindingRevision", "pageLengthUTF16", "documentLengthUTF16"):
        require(integer(value.get(key), 1), "invalid page integer: " + key)
    for key in ("spineIndex", "pageIndex", "pageStartUTF16"):
        require(integer(value.get(key)), "invalid page integer: " + key)
    require(value["spineIndex"] == 2 and type(value.get("viewID")) is str and value["viewID"], "page identity differs")
    require(type(value.get("processObservationID")) is str and value["processObservationID"], "process observation identity missing")
    text = value.get("pageText")
    require(type(text) is str and text.count(marker) == 1, "unique visible marker missing")
    require(utf16(text) == value["pageLengthUTF16"] <= 16_384, "page UTF16 length differs")
    require(value["pageStartUTF16"] + utf16(text) <= value["documentLengthUTF16"], "page exceeds document")
    require(value.get("imageSource") in {"drawn", "prerendered"}, "unknown image source")
    require(number(value.get("submissionUptimeSeconds")) and value["submissionUptimeSeconds"] > 0, "invalid page timestamp")
    return value["pageStartUTF16"] + utf16(text.split(marker, 1)[0])


def validate_launch(values):
    require(len(values) == 5, "exactly five launch samples required")
    expected_fixture = launch_fixture_protocol()
    seen, processes, intervals, run_ids = set(), set(), [], set()
    expected_page = None
    for row in values:
        require(type(row.get("schemaVersion")) is int and row["schemaVersion"] == 1 and row.get("kind") == "reader-process-launch", "launch schema differs")
        require(integer(row.get("iteration")) and row["iteration"] < 5 and row["iteration"] not in seen, "duplicate/unknown launch iteration")
        seen.add(row["iteration"])
        run_ids.add(row.get("runID"))
        for key, value in expected_fixture.items(): require(row.get(key) == value, "launch fixture differs")
        require(integer(row.get("fixtureBytes"), 1), "launch fixture byte count invalid")
        literal_flags(row, {"fixturePreparationInsideInterval": False, "originalImportInputRemoved": True,
                           "measuredLaunchImports": False, "systemCachesPurged": False, "deviceCold": False,
                           "gpuPresentationMeasured": False, "improvementEstablished": False,
                           "launchToReadableIncludesAutomationNavigation": True, "complete": True})
        require(row.get("terminalPhase") == "complete" and row.get("error") is None, "failed launch sample")
        require(row.get("timingProcess") == "separate-xctest-ui-runner" and row.get("observedProcess") == "debug-app-under-ui-automation", "launch process scope differs")
        require(row.get("boundary") == "launch-request-to-cpu-layer-submitted-and-ax-readable-visible-anchor", "launch endpoint differs")
        marker = "LOCAL_READER_SMOKE_RESUME_P0000."
        require(row.get("expectedMarker") == marker, "anchor marker differs")
        expected = row.get("expected")
        expected_offset = page(expected, marker)
        if expected_page is None: expected_page = expected
        require(expected == expected_page, "preparation anchor changed within series")
        actual = row.get("observed")
        require(integer(row.get("expectedMarkerUTF16")) and page(actual, marker) == expected_offset == row["expectedMarkerUTF16"], "actual rendered marker offset differs")
        for key in ("spineIndex", "pageStartUTF16", "pageLengthUTF16", "documentLengthUTF16", "pageText"):
            require(actual[key] == expected[key], "actual rendered page differs: " + key)
        require(actual["processObservationID"] != expected["processObservationID"]
                and actual["processObservationID"] not in processes, "fresh process observation identity missing")
        processes.add(actual["processObservationID"])
        times = row.get("timestamps")
        require(type(times) is dict and set(times) == set(TIMES), "launch timestamps incomplete")
        require(all(number(times[key]) and times[key] > 0 for key in TIMES), "invalid launch timestamp")
        ordered = [times[key] for key in TIMES]
        require(all(b >= a for a, b in zip(ordered, ordered[1:])), "launch timestamps out of order")
        require(times["launchRequested"] <= actual["submissionUptimeSeconds"] <= times["pageObserved"], "submission is outside fresh process interval")
        intervals.append({"iteration": row["iteration"], "launchCallMilliseconds": (times["launchReturned"] - times["launchRequested"]) * 1_000,
                          "launchThroughAutomationToReadableMilliseconds": (times["pageObserved"] - times["launchRequested"]) * 1_000,
                          "bookTapToObservedReadableMilliseconds": (times["pageObserved"] - times["bookTapRequested"]) * 1_000})
    require(seen == set(range(5)) and len(run_ids) == 1 and all(type(x) is str and x for x in run_ids), "launch series identity incomplete")
    return intervals


def validate_memory(values, phase_rows):
    protocol = fixture_protocol()
    expected = {(fixture, i) for fixture in protocol for i in range(5)}
    require(len(values) == 10, "exactly ten memory samples required")
    seen, run_ids, pids, phase_expected, summary = set(), set(), set(), {}, []
    for row in values:
        require(type(row.get("schemaVersion")) is int and row["schemaVersion"] == 1 and row.get("kind") == "reader-process-memory", "memory schema differs")
        key = (row.get("fixture"), row.get("iteration"))
        require(type(key[1]) is int and key in expected and key not in seen, "duplicate/unknown memory fixture iteration")
        seen.add(key); run_ids.add(row.get("runID"))
        for name, value in protocol[key[0]].items(): require(row.get(name) == value, "memory fixture differs")
        require(integer(row.get("fixtureHTMLBytes"), 1) and integer(row.get("fixtureMinimumUTF16"), 1), "memory fixture count invalid")
        literal_flags(row, {"fixtureConstructionInsideInterval": False, "baselineIncludesRetainedFixtureHTML": True,
                           "cachesPurged": False, "deviceCold": False, "improvementEstablished": False,
                           "measurementOverheadExcluded": False, "exactKernelPeakClaimed": False})
        require(row.get("processScope") == "app-process-with-xctest-loaded" and row.get("platform") == "ios-simulator", "memory process/platform scope differs")
        require(row.get("units") == "bytes" and row.get("metricMethod") == "task_info(TASK_VM_INFO): phys_footprint and resident_size; same snapshot", "memory units/method differ")
        for name, value in {"nominalIntervalMilliseconds": 10, "maximumAllowedGapMilliseconds": 50, "fontSize": 18, "paragraphSpacing": 8}.items():
            require(type(row.get(name)) is int and row[name] == value, "memory protocol integer differs")
        require(row.get("viewport") == [390, 844] and all(type(x) is int for x in row["viewport"])
                and number(row.get("lineHeightMultiple")) and row["lineHeightMultiple"] == 1.5, "render protocol differs")
        style = row.get("style")
        require(type(style) is dict, "actual render style missing")
        for name, value in {"fontSize": 18, "lineHeightMultiple": 1.5, "paragraphSpacing": 8, "lineSpacing": 0, "letterSpacing": 0}.items():
            require(number(style.get(name)) and style[name] == value, "actual render style differs")
        require(style.get("writingMode") == "horizontal" and style.get("contentInsets") == [0, 0, 0, 0]
                and all(number(x) for x in style["contentInsets"]), "actual writing/insets differ")
        outputs = row.get("outputs")
        require(type(outputs) is dict and set(outputs) == {"documentUTF16", "firstPages", "fullPages", "coveredUTF16", "scrollChunks", "verifiedJumps"}, "stage output counts incomplete")
        require(all(integer(value, 1) for value in outputs.values()), "stage output count invalid")
        require(outputs["documentUTF16"] == outputs["coveredUTF16"] >= protocol[key[0]]["fixtureMinimumUTF16"] and outputs["verifiedJumps"] == 10, "stage output coverage differs")
        require(outputs["firstPages"] <= outputs["fullPages"] <= outputs["documentUTF16"]
                and outputs["scrollChunks"] <= outputs["documentUTF16"], "stage output counts impossible")
        jumps = row.get("jumps")
        require(type(jumps) is list and len(jumps) == 10, "jump witnesses incomplete")
        offsets = set()
        for index, jump in enumerate(jumps):
            require(type(jump) is dict and type(jump.get("index")) is int and jump["index"] == index, "jump identity differs")
            offset = jump.get("requestedOffsetUTF16")
            require(integer(offset) and offset < outputs["documentUTF16"] and offset not in offsets, "jump offset invalid/duplicate")
            offsets.add(offset)
            require(type(jump.get("observedSpine")) is int and jump["observedSpine"] == 0
                    and type(jump.get("observedOffsetUTF16")) is int and jump["observedOffsetUTF16"] == offset, "jump did not land at requested text anchor")
            require(type(jump.get("anchorText")) is str and integer(jump.get("anchorLengthUTF16"), 1)
                    and utf16(jump["anchorText"]) == jump["anchorLengthUTF16"] <= 32
                    and offset + jump["anchorLengthUTF16"] <= outputs["documentUTF16"], "jump UTF16 text witness differs")
        measurement = row.get("measurement")
        require(type(measurement) is dict and measurement.get("complete") is True and measurement.get("errors") == [], "memory sample failed/incomplete")
        require(integer(measurement.get("processID"), 1), "memory PID missing")
        pids.add(measurement["processID"])
        points, events = measurement.get("points"), measurement.get("events")
        require(type(points) is list and 3 <= len(points) <= 12_030 and type(events) is list
                and [event.get("name") for event in events if type(event) is dict] == STAGES, "points/stages incomplete")
        for event in events:
            require(set(event) == {"name", "uptimeSeconds"} and number(event["uptimeSeconds"]), "invalid stage timestamp")
        require(all(b["uptimeSeconds"] >= a["uptimeSeconds"] for a, b in zip(events, events[1:])), "stage time reversed")
        previous_end = -1
        for point in points:
            require(type(point) is dict and point.get("kind") in {"boundary", "periodic"} and point.get("phase") in STAGES, "invalid point identity")
            before, after = point.get("beforeUptimeSeconds"), point.get("afterUptimeSeconds")
            require(number(before) and number(after) and 0 < before <= after and before >= previous_end, "invalid or overlapping point time")
            previous_end = after
            require(type(point.get("kernelReturn")) is int and point["kernelReturn"] == 0
                    and point.get("sufficientReturnCount") is True and point.get("onMain") is False, "failed/on-main kernel memory query")
            require(integer(point.get("footprintBytes"), 1) and integer(point.get("residentBytes"), 1), "missing memory bytes")
        boundaries = [point for point in points if point["kind"] == "boundary"]
        require([point["phase"] for point in boundaries] == STAGES, "stage boundary samples incomplete")
        require(points[0]["kind"] == points[-1]["kind"] == "boundary"
                and points[0]["phase"] == "baseline" and points[-1]["phase"] == "complete", "memory endpoint samples missing")
        for event, point in zip(events, boundaries):
            require(event["uptimeSeconds"] <= point["beforeUptimeSeconds"], "stage event came after its sample")
        periodic = [point for point in points if point["kind"] == "periodic"]
        require(periodic and type(measurement.get("periodicSamples")) is int and measurement["periodicSamples"] == len(periodic), "no/miscounted periodic samples")
        for point in periodic:
            active = [event["name"] for event in events if event["uptimeSeconds"] <= point["beforeUptimeSeconds"]]
            require(active and point["phase"] == active[-1] and point["phase"] != "complete", "periodic sample labelled with the wrong phase")
        timeline = [points[0]] + periodic + [points[-1]]
        gaps = [(b["beforeUptimeSeconds"] - a["beforeUptimeSeconds"]) * 1_000 for a, b in zip(timeline, timeline[1:])]
        maximum_gap = max(gaps)
        require(maximum_gap <= 50 and number(measurement.get("maximumObservedGapMilliseconds"))
                and abs(measurement["maximumObservedGapMilliseconds"] - maximum_gap) < 0.00001, "periodic sample gap invalid/missed")
        require(number(measurement.get("beginUptimeSeconds")) and number(measurement.get("endUptimeSeconds"))
                and measurement["beginUptimeSeconds"] == points[0]["beforeUptimeSeconds"]
                and measurement.get("endUptimeSeconds") == points[-1]["afterUptimeSeconds"], "memory interval differs")
        for metric, title in (("footprintBytes", "Footprint"), ("residentBytes", "Resident")):
            require(type(measurement.get("baseline" + title + "Bytes")) is int
                    and measurement["baseline" + title + "Bytes"] == points[0][metric], "baseline differs from raw sample")
            require(type(measurement.get("sampledPeak" + title + "Bytes")) is int
                    and measurement["sampledPeak" + title + "Bytes"] == max(point[metric] for point in points), "peak differs from raw points")
        phase_expected[(row.get("runID"), *key)] = events
        summary.append({"fixture": key[0], "iteration": key[1], "baselineFootprintBytes": measurement["baselineFootprintBytes"],
                        "sampledPeakFootprintBytes": measurement["sampledPeakFootprintBytes"],
                        "baselineResidentBytes": measurement["baselineResidentBytes"], "sampledPeakResidentBytes": measurement["sampledPeakResidentBytes"],
                        "periodicSamples": len(periodic), "maximumObservedGapMilliseconds": maximum_gap})
    require(seen == expected and len(run_ids) == len(pids) == 1 and all(type(x) is str and x for x in run_ids), "memory matrix/process series incomplete")
    emitted = {}
    for row in phase_rows:
        require(set(row) == {"runID", "fixture", "iteration", "event"}, "raw phase envelope differs")
        key = (row["runID"], row["fixture"], row["iteration"])
        require(type(row["iteration"]) is int and key in phase_expected, "unexpected raw phase sample")
        emitted.setdefault(key, []).append(row["event"])
    require(emitted == phase_expected, "raw phase records missing/duplicate/reordered")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launch-log", type=Path, required=True)
    parser.add_argument("--memory-log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(not args.output.exists(), "refusing to overwrite evidence")
    result = {"schemaVersion": 1, "collectionShapeValidated": False, "sdkCompilationAttested": False,
              "iOSExecutionAttested": False, "physicalDeviceMeasured": False, "improvementEstablished": False,
              "limitations": ["Supplied text alone does not attest execution: bind actual passing new XCTest identities, source/build and SDK/runtime/overlay evidence separately.",
                              "Launch interval includes UI automation navigation; layer submission and AX visibility are not GPU presentation or tap-to-photon.",
                              "System/Simulator caches are not cleared. Process-cold is not device-cold.",
                              "Memory is a sampled app XCTest-host interval, with retained fixtures, recorder buffers, logging and scheduling overhead included; short peaks can be missed.",
                              "Five observations support median/max descriptions, not p95, production performance improvement or device memory-limit acceptance."], "inputs": {}}
    try:
        raw = {}
        for kind, path in (("launch", args.launch_log), ("memory", args.memory_log)):
            require(path.stat().st_size <= 64 * 1024**2, "log exceeds 64MiB")
            raw[kind] = path.read_bytes()
            result["inputs"][kind] = {"path": str(path), "bytes": len(raw[kind]), "sha256": hashlib.sha256(raw[kind]).hexdigest()}
        result["launchSamples"] = validate_launch(rows(raw["launch"], LAUNCH))
        result["memorySamples"] = validate_memory(rows(raw["memory"], MEMORY), rows(raw["memory"], PHASE))
        result["collectionShapeValidated"] = True
        result["launchMedianThroughAutomationMilliseconds"] = statistics.median(item["launchThroughAutomationToReadableMilliseconds"] for item in result["launchSamples"])
        result["launchMaxThroughAutomationMilliseconds"] = max(item["launchThroughAutomationToReadableMilliseconds"] for item in result["launchSamples"])
    except Exception as error:
        result["error"] = type(error).__name__ + ": " + str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2); stream.write("\n")
    print(json.dumps({"output": str(args.output), "collectionShapeValidated": result["collectionShapeValidated"], "sdkCompilationAttested": False, "iOSExecutionAttested": False}))
    return 0 if result["collectionShapeValidated"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

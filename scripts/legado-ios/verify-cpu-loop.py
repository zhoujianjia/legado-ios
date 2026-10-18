#!/usr/bin/env python3
"""Validate fixed CPU-loop evidence; platform/source authentication belongs to the runner."""
import json
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value):
    return type(value) is int


def envelope(raw):
    require(isinstance(raw, str) and len(raw) <= 65536, "Missing bounded original operation envelope")
    value = json.loads(raw)
    require(isinstance(value, dict), "Operation envelope must be an object")
    return value


def verify(native):
    require(isinstance(native, dict) and native.get("suite") == "CpuLoopCapabilityProbe"
            and native.get("passed") is True and native.get("interpreted") is True
            and native.get("fixtureOnly") is True and native.get("g4ValidationPassed") is False,
            "CPU loop probe must identify its interpreted fixed suite and actual success")
    parent = native.get("parentDeadlineEpochMs")
    require(integer(parent) and parent > 0, "Original parent deadline is missing")
    cases = native.get("cases")
    require(isinstance(cases, list) and len(cases) == 2 and all(isinstance(x, dict) for x in cases),
            "Exactly two CPU loop cases are required")
    names = [item.get("name") for item in cases]
    require(all(isinstance(x, str) for x in names) and set(names) == {"public-cancel", "absolute-deadline"},
            "CPU loop cases must cover public cancellation and the absolute deadline exactly once")
    identifiers = set()
    workers = set()
    for item in cases:
        require(item.get("passed") is True and item.get("sessionClosed") is True and item.get("contextExited") is True,
                "CPU workload, context exit and session close must pass")
        task, session, token = (item.get(key) for key in ("taskId", "sessionId", "token"))
        require(all(isinstance(x, str) and x and x not in identifiers for x in (task, session, token))
                and len({task, session, token}) == 3, "Each CPU case must own distinct task, session and token identifiers")
        require(str(uuid.UUID(token)) == token, "CPU signal token must be its unique canonical UUID")
        identifiers.update((task, session, token))
        child = item.get("childDeadlineEpochMs")
        require(integer(child) and 0 < child <= parent, "CPU child deadline cannot exceed its parent's deadline")
        signal, sample, recovery = (item.get(key) for key in ("signal", "cpuSample", "recovery"))
        require(all(isinstance(x, dict) for x in (signal, sample, recovery)), "CPU signal, real stack sample and recovery evidence are required")
        require(signal.get("token") == token and integer(signal.get("iterations")) and signal["iterations"] == 16384
                and integer(signal.get("checksum")) and signal["checksum"] == 402644992,
                "The actual JavaScript iteration count and checksum must match the fixed workload")
        signalled, sampled = signal.get("recordedNanoTime"), sample.get("sampledNanoTime")
        require(integer(signalled) and integer(sampled) and signalled <= sampled and sample.get("passed") is True,
                "A positive CPU stack sample must follow the JavaScript signal")
        stack = sample.get("stack")
        require(isinstance(stack, list) and 0 < len(stack) <= 512 and all(isinstance(x, str) for x in stack)
                and any(x.startswith("org.htmlunit.corejs.javascript.Interpreter.interpretLoop(") for x in stack),
                "The sampled worker must actually be in Rhino's interpreter loop")
        require(not any(any(blocked in frame for blocked in (
                    "CpuLoopCapabilityProbe$workload$", "NativeJavaMethod", "SourceJavaHost", "LegadoRuntime.dispatchHost"))
                for frame in stack), "A signal or host-call stack cannot establish CPU-loop execution")
        worker = sample.get("workerId")
        require(integer(worker) and worker > 0 and recovery.get("workerId") == worker
                and type(recovery.get("workerId")) is int and recovery.get("contextExited") is True,
                "Recovery must run on the same worker after leaving its Rhino context")
        workers.add(worker)
        created, closed = envelope(item.get("sessionEnvelope")), envelope(item.get("closeEnvelope"))
        require(created.get("ok") is True and created.get("sessionId") == session and closed.get("ok") is True,
                "Original public session creation and close envelopes must succeed")
        outcome = envelope(item.get("operationEnvelope"))
        error = outcome.get("error")
        expected = "CANCELLED" if item["name"] == "public-cancel" else "TIMEOUT"
        require(outcome.get("ok") is False and outcome.get("taskId") == task
                and isinstance(error, dict) and error.get("code") == expected,
                "The actual CPU operation must return its distinct cancellation or timeout error")
        if item["name"] == "public-cancel":
            requested = item.get("cancelRequestedNanoTime")
            cancelled = envelope(item.get("cancelEnvelope"))
            require(integer(requested) and sampled <= requested and cancelled.get("ok") is True
                    and cancelled.get("taskId") == task and cancelled.get("cancelled") is True,
                    "Public cancel must find the live task after a positive CPU sample")
        else:
            require("cancelEnvelope" not in item and "cancelRequestedNanoTime" not in item,
                    "Deadline evidence cannot substitute an explicit cancellation")
        recovered = envelope(recovery.get("operationEnvelope"))
        recovery_id = recovered.get("taskId")
        require(recovered.get("ok") is True and recovered.get("result") == 42
                and isinstance(recovery_id, str) and recovery_id and recovery_id not in identifiers,
                "A separate public operation must recover with the original expected result")
        identifiers.add(recovery_id)
    require(len(workers) == 1, "Both cases and recovery must use their one owned worker")
    cleanup = native.get("cleanup")
    require(isinstance(cleanup, dict) and cleanup.get("errors") == []
            and all(cleanup.get(name) is True for name in ("workerStopped", "sessionsClosed", "registryEmpty")),
            "CPU diagnostic must stop its worker and release every session and signal registration")
    return {"passed": True, "casesVerified": 2, "cpuExecutionPositivelySampled": True,
            "g4ValidationPassed": False, "fullStabilityGatePassed": False}

import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic } from "./logic.mjs"

const L = loadLogic("runnerstatus")

function runner(dir, status, extra = {}) {
    return { dir, name: "mac-build", repo: "pless84/" + dir, repo_url: "https://github.com/pless84/" + dir,
        status, job: null, history: [], ...extra }
}

test("runnerState: unknown statuses count as offline", () => {
    assert.equal(L.runnerState({ status: "idle" }), "idle")
    assert.equal(L.runnerState({ status: "busy" }), "busy")
    assert.equal(L.runnerState({ status: "offline" }), "offline")
    assert.equal(L.runnerState({ status: "not loaded" }), "offline")
    assert.equal(L.runnerState({}), "offline")
})

test("countStates, panelStates and visibleStates", () => {
    const runners = [runner("a", "idle"), runner("b", "busy"), runner("c", "idle"), runner("d", "weird")]
    const counts = L.countStates(runners)
    assert.deepEqual(counts, { idle: 2, busy: 1, offline: 1 })
    const states = [{ key: "offline", inPanel: true }, { key: "busy", inPanel: false }, { key: "idle", inPanel: true }]
    assert.deepEqual(L.panelStates(states, { idle: 2 }, false).map(s => s.key), ["idle"])
    assert.deepEqual(L.panelStates(states, { idle: 2 }, true).map(s => s.key), ["offline", "idle"])
    assert.deepEqual(L.visibleStates(states, counts).map(s => s.key), ["offline", "busy", "idle"])
})

test("sortRunners: worst state first, then by repository", () => {
    const sorted = L.sortRunners([runner("z", "idle"), runner("b", "busy"), runner("a", "idle"), runner("y", "offline")],
        ["offline", "busy", "idle"])
    assert.deepEqual(sorted.map(r => r.dir), ["y", "b", "a", "z"])
})

test("title falls back to the runner name", () => {
    assert.equal(L.title({ repo: "o/r", name: "n" }), "o/r")
    assert.equal(L.title({ name: "n" }), "n")
})

test("lastJob picks the latest finished, whatever the order", () => {
    assert.equal(L.lastJob(runner("a", "idle")), null)
    const r = runner("a", "idle", { history: [{ name: "x", finished: 10 }, { name: "y", finished: 30 }, { name: "z", finished: 20 }] })
    assert.equal(L.lastJob(r).name, "y")
})

test("jobFailed", () => {
    assert.ok(L.jobFailed({ result: "Failed" }))
    assert.ok(!L.jobFailed({ result: "Succeeded" }))
    assert.ok(!L.jobFailed({ result: "Canceled" }))
    assert.ok(!L.jobFailed(null))
})

test("actionsUrl links the running job, else the Actions page", () => {
    assert.equal(L.actionsUrl(runner("a", "idle")), "https://github.com/pless84/a/actions")
    assert.equal(L.actionsUrl(runner("a", "busy", { job: { run_id: 42 } })), "https://github.com/pless84/a/actions/runs/42")
    assert.equal(L.actionsUrl({}), "")
})

test("actionsUrl opens only http(s) links", () => {
    assert.equal(L.actionsUrl({ repo_url: "file:///etc/passwd" }), "")
    assert.equal(L.actionsUrl({ repo_url: "javascript:alert(1)" }), "")
    assert.equal(L.actionsUrl({ repo_url: "https://github.com/o/r x" }), "")
})

test("formatDuration", () => {
    assert.equal(L.formatDuration(45.4), "45s")
    assert.equal(L.formatDuration(192), "3m 12s")
    assert.equal(L.formatDuration(7500), "2h 5m")
    assert.equal(L.formatDuration(356400), "4d 3h")
    assert.equal(L.formatDuration(-5), "0s")
    assert.equal(L.formatDuration(null), "–")
})

test("changes: nothing on the first check", () => {
    const result = L.changes([runner("a", "offline", { history: [{ result: "Failed", finished: 5 }] })], null)
    assert.deepEqual(result.wentOffline, [])
    assert.deepEqual(result.failedJobs, [])
    assert.deepEqual(result.snapshot, { a: { state: "offline", finished: 5 } })
})

test("changes: runners going offline and newly failed jobs", () => {
    const first = L.changes([
        runner("a", "idle", { history: [{ name: "old", result: "Failed", finished: 10 }] }),
        runner("b", "busy"),
        runner("c", "offline"),
    ], null).snapshot
    const result = L.changes([
        runner("a", "offline", { history: [
            { name: "new", result: "Failed", finished: 20 },
            { name: "ok", result: "Succeeded", finished: 15 },
            { name: "old", result: "Failed", finished: 10 },
        ] }),
        runner("b", "idle", { history: [{ name: "build", result: "Failed", finished: 3 }] }),
        runner("c", "offline"),
        runner("d", "offline"),
    ], first)
    assert.deepEqual(result.wentOffline.map(r => r.dir), ["a"])
    assert.deepEqual(result.failedJobs.map(f => f.runner.dir + ":" + f.job.name), ["a:new", "b:build"])
})

function job(name, status, extra = {}) {
    return { label: "dk.pless." + name, name, status, schedule: "daily 03:30", last_run: 100, log: [], ...extra }
}

test("jobState: ok, running and waiting; anything else is a problem", () => {
    assert.equal(L.jobState(job("a", "ok")), "idle")
    assert.equal(L.jobState(job("a", "running")), "busy")
    assert.equal(L.jobState(job("a", "waiting")), "waiting")
    for (const status of ["failed", "missed", "not loaded", "error", "something new", undefined]) {
        assert.equal(L.jobState(job("a", status)), "offline", String(status))
    }
    assert.deepEqual(L.failingJobs([job("a", "ok"), job("b", "missed"), job("c", "failed")]).map(j => j.name), ["b", "c"])
    assert.deepEqual(L.failingJobs(undefined), [])
})

test("sortJobs: failing first, then by name", () => {
    const sorted = L.sortJobs([job("z", "ok"), job("b", "ok"), job("y", "failed"), job("a", "missed")])
    assert.deepEqual(sorted.map(j => j.name), ["a", "y", "b", "z"])
    assert.deepEqual(L.sortJobs(undefined), [])
})

test("lastLogLine is the newest line (the dashboard lists newest first)", () => {
    assert.equal(L.lastLogLine(job("a", "ok")), null)
    assert.equal(L.lastLogLine(job("a", "ok", { log: [{ time: 2, text: "saved" }, { time: 1, text: "ping" }] })).text, "saved")
})

test("jobChanges: newly failing jobs and repeat failures, never on the first check", () => {
    const first = L.jobChanges([job("a", "failed"), job("b", "ok")], null)
    assert.deepEqual(first.newlyFailing, [])
    assert.deepEqual(first.snapshot["dk.pless.a"], { failing: true, lastRun: 100 })
    // a is still failing from the same run: no repeat; b just failed.
    const second = L.jobChanges([job("a", "failed"), job("b", "failed", { last_run: 200 })], first.snapshot)
    assert.deepEqual(second.newlyFailing.map(j => j.name), ["b"])
    // a ran again and failed again; b is fine now.
    const third = L.jobChanges([job("a", "failed", { last_run: 300 }), job("b", "ok", { last_run: 300 })], second.snapshot)
    assert.deepEqual(third.newlyFailing.map(j => j.name), ["a"])
    // A job that appears already failing (e.g. newly installed) waits for the next change.
    assert.deepEqual(L.jobChanges([job("c", "missed")], third.snapshot).newlyFailing, [])
})

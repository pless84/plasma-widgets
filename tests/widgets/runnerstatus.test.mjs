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

const hist = (name, secs, finished) => ({ name, result: "Succeeded", started: finished - secs, finished })

test("jobContext: run number, branch and who triggered it", () => {
    assert.equal(L.jobContext({ run_number: "412", ref: "refs/heads/main", event_name: "push", actor: "pless84" }),
        "#412 · main · push by pless84")
    assert.equal(L.jobContext({ ref: "refs/tags/v1", actor: "x" }), "refs/tags/v1 · by x")
    assert.equal(L.jobContext({ event_name: "schedule" }), "schedule")
    assert.equal(L.jobContext({}), "")
    assert.equal(L.jobContext(null), "")
})

test("usualDuration: median of the same job, needs 3 samples", () => {
    const r = runner("a", "busy", { history: [hist("build", 240, 1000), hist("build", 100, 2000), hist("build", 300, 3000),
        hist("test", 5, 3100), { name: "build", result: "Succeeded", started: null, finished: 4000 }] })
    assert.equal(L.usualDuration(r, "build"), 240)
    assert.equal(L.usualDuration(r, "test"), null)
    r.history.push(hist("build", 400, 5000))
    assert.equal(L.usualDuration(r, "build"), 270)
    assert.equal(L.usualDuration(runner("a", "idle"), "build"), null)
})

test("jobTiming: slow past twice the usual duration", () => {
    const history = [hist("build", 240, 1000), hist("build", 240, 2000), hist("build", 240, 3000)]
    const at = (started, now) => L.jobTiming(runner("a", "busy", { history, job: { job: "build", started } }), now)
    assert.deepEqual(at(10000, 10480), { running: 480, usual: 240, slow: false })
    assert.equal(at(10000, 10481).slow, false) // past 2x but under 5 minutes beyond usual
    assert.equal(at(10000, 10540).slow, true)
    assert.equal(L.jobTiming(runner("a", "busy", { job: { job: "other", started: 1 } }), 99999).slow, false)
    assert.equal(L.jobTiming(runner("a", "idle"), 5), null)
    assert.equal(L.jobTiming(runner("a", "busy", { job: { job: "build" } }), 5), null)
})

test("jobTiming: a quick job isn't slow just because it ran a few seconds more", () => {
    const history = [hist("lint", 8, 1000), hist("lint", 8, 2000), hist("lint", 8, 3000)]
    const at = now => L.jobTiming(runner("a", "busy", { history, job: { job: "lint", started: 10000 } }), now)
    assert.equal(at(10017).slow, false)
    assert.equal(at(10200).slow, false)
    assert.equal(at(10308).slow, true)
})

test("usualDuration: only succeeded jobs count; canceled and failed samples are ignored", () => {
    const early = (name, secs, finished, result) => ({ name, result, started: finished - secs, finished })
    const r = runner("a", "busy", { history: [hist("build", 600, 1000), hist("build", 600, 2000), hist("build", 600, 3000),
        early("build", 5, 4000, "Canceled"), early("build", 5, 5000, "Failed"), early("build", 5, 6000, "Skipped")] })
    assert.equal(L.usualDuration(r, "build"), 600)
    const few = runner("a", "busy", { history: [hist("build", 600, 1000), early("build", 5, 4000, "Canceled"), early("build", 5, 5000, "Canceled")] })
    assert.equal(L.usualDuration(few, "build"), null)
})

test("hungJobs: reported once, never on the first check", () => {
    const history = [hist("build", 600, 1000), hist("build", 600, 2000), hist("build", 600, 3000)]
    const r = runner("a", "busy", { history, job: { job: "build", started: 5000 } })
    const first = L.hungJobs([r], 6500, null)
    assert.equal(first.keys.length, 1)
    assert.deepEqual(first.hung, [])
    const calm = L.hungJobs([r], 5100, first.keys)
    assert.deepEqual(calm.keys, [])
    const slow = L.hungJobs([r], 6300, calm.keys)
    assert.deepEqual(slow.hung.map(x => x.dir), ["a"])
    assert.deepEqual(L.hungJobs([r], 6400, slow.keys).hung, [])
})

test("offlineReason: service state from launchd", () => {
    assert.equal(L.offlineReason(runner("a", "idle", { launchd: { loaded: true } })), null)
    assert.equal(L.offlineReason(runner("a", "offline")), null)
    assert.equal(L.offlineReason(runner("a", "offline", { launchd: {} })), null)
    assert.deepEqual(L.offlineReason(runner("a", "offline", { launchd: { loaded: false } })), { kind: "notLoaded" })
    assert.deepEqual(L.offlineReason(runner("a", "offline", { launchd: { loaded: true, last_exit_code: "1", runs: "7" } })),
        { kind: "crashed", exitCode: 1, runs: 7 })
    assert.deepEqual(L.offlineReason(runner("a", "offline", { launchd: { loaded: true, last_exit_code: "0" } })),
        { kind: "stopped", exitCode: 0, runs: null })
    assert.deepEqual(L.offlineReason(runner("a", "offline", { launchd: { loaded: true, last_exit_code: "(never exited)" } })),
        { kind: "stopped", exitCode: null, runs: null })
})

test("host: load per core, low disk and its one-time change", () => {
    assert.equal(L.loadPerCore({ load: [4, 1, 1], cpus: 8 }), 0.5)
    assert.equal(L.loadPerCore({ load: [4], cpus: 0 }), null)
    assert.equal(L.loadPerCore({}), null)
    assert.equal(L.loadPerCore(null), null)
    assert.ok(L.diskLow({ disk_free_gb: 9, disk_total_gb: 100 }))
    assert.ok(!L.diskLow({ disk_free_gb: 10, disk_total_gb: 100 }))
    assert.ok(!L.diskLow({}))
    const low = { disk_free_gb: 5, disk_total_gb: 100 }, ok = { disk_free_gb: 50, disk_total_gb: 100 }
    assert.deepEqual(L.lowDiskChange(low, null), { low: true, notify: false })
    assert.deepEqual(L.lowDiskChange(low, false), { low: true, notify: true })
    assert.deepEqual(L.lowDiskChange(low, true), { low: true, notify: false })
    assert.deepEqual(L.lowDiskChange(ok, true), { low: false, notify: false })
})

test("lowDiskChange: re-arms only after free space is back above 12 %", () => {
    const at = free => ({ disk_free_gb: free, disk_total_gb: 100 })
    assert.deepEqual(L.lowDiskChange(at(11), true), { low: true, notify: false })
    assert.deepEqual(L.lowDiskChange(at(12), true), { low: true, notify: false })
    assert.deepEqual(L.lowDiskChange(at(13), true), { low: false, notify: false })
    // Hovering around the 10 % limit doesn't notify again until it has recovered.
    let low = L.lowDiskChange(at(9), false)
    assert.equal(low.notify, true)
    for (const free of [11, 9, 10.5, 9.5]) {
        low = L.lowDiskChange(at(free), low.low)
        assert.equal(low.notify, false)
    }
    low = L.lowDiskChange(at(13), low.low)
    assert.equal(L.lowDiskChange(at(9), low.low).notify, true)
})

test("lowDiskChange: missing host data keeps the previous state, so the first check with data never notifies", () => {
    assert.deepEqual(L.lowDiskChange(null, null), { low: null, notify: false })
    assert.deepEqual(L.lowDiskChange({}, null), { low: null, notify: false })
    assert.deepEqual(L.lowDiskChange(undefined, true), { low: true, notify: false })
    assert.deepEqual(L.lowDiskChange(null, false), { low: false, notify: false })
    const first = L.lowDiskChange({ disk_free_gb: 5, disk_total_gb: 100 }, L.lowDiskChange(null, null).low)
    assert.deepEqual(first, { low: true, notify: false })
})

test("formatMb", () => {
    assert.equal(L.formatMb(639.6), "640 MB")
    assert.equal(L.formatMb(1434), "1.4 GB")
    assert.equal(L.formatMb(null), "")
    assert.equal(L.formatMb(undefined), "")
})

test("recentProblems: only the last 24 hours, newest first", () => {
    const now = 1000000
    const r = runner("a", "idle", { problems: [{ time: now - 100, msg: "new" }, { time: now - 90000, msg: "old" }, { time: now - 5000, msg: "mid" }, { msg: "no time" }] })
    assert.deepEqual(L.recentProblems(r, now).map(p => p.msg), ["new", "mid", "no time"])
    assert.deepEqual(L.recentProblems(runner("a", "idle"), now), [])
})

test("recentProblems: ISO string times are parsed; a missing time still counts, without an age", () => {
    const now = Date.parse("2026-10-20T12:00:00Z") / 1000
    const r = runner("a", "idle", { problems: [{ time: "2026-10-20 11:00:00Z", msg: "iso" }, { time: "2026-10-18T11:00:00Z", msg: "old iso" },
        { time: "garbage", msg: "bad" }, { msg: "none" }, { time: now - 10, msg: "num" }] })
    const found = L.recentProblems(r, now)
    assert.deepEqual(found.map(p => p.msg), ["num", "iso", "bad", "none"])
    assert.equal(found[1].time, now - 3600)
    assert.equal(found[2].time, null)
    assert.equal(found[3].time, null)
})

test("recentResults: last 10, newest first", () => {
    assert.equal(L.recentResults(runner("a", "idle")), null)
    const history = []
    for (let i = 1; i <= 12; i++) history.push({ name: "j", result: i === 11 ? "Failed" : "Succeeded", finished: i })
    const res = L.recentResults(runner("a", "idle", { history }))
    assert.equal(res.total, 10)
    assert.equal(res.passed, 9)
    assert.equal(res.results[0], "Succeeded")
    assert.equal(res.results[1], "Failed")
})

test("recentResults: canceled and skipped jobs are not failures, so they count as passed", () => {
    const history = ["Succeeded", "Canceled", "Skipped", "Failed"].map((result, i) => ({ name: "j", result, finished: i + 1 }))
    const res = L.recentResults(runner("a", "idle", { history }))
    assert.deepEqual([res.passed, res.total], [3, 4])
})

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

function llm(extra = {}) {
    return {
        gpu: { util: 0, alloc_gb: 42.9 },
        memory: { free_pct: 54, swap_used_gb: 6, swap_total_gb: 24 },
        ollama: { up: true, version: "0.40.3", models: [{ name: "gemma" }], requests: [{ time: 10 }, { time: 30 }] },
        mlx: [{ label: "dk.pless.mlx-rpr", model: "Org/Qwen3-8Bit", up: true, footprint_gb: 39, requests: [] }],
        ...extra,
    }
}

test("shortModel and lastRequestTime", () => {
    assert.equal(L.shortModel("Org/Qwen3-8Bit"), "Qwen3-8Bit")
    assert.equal(L.shortModel("plain"), "plain")
    assert.equal(L.shortModel(null), "")
    assert.equal(L.lastRequestTime([{ time: 10 }, { time: 30 }, { time: 20 }]), 30)
    assert.equal(L.lastRequestTime(undefined), 0)
})

test("llmServers lists Ollama then the MLX servers", () => {
    assert.deepEqual(L.llmServers(undefined), [])
    const servers = L.llmServers(llm())
    assert.deepEqual(servers.map(s => [s.key, s.name, s.up]), [["ollama", "Ollama", true], ["dk.pless.mlx-rpr", "Qwen3-8Bit", true]])
    assert.equal(servers[0].lastRequest, 30)
    assert.equal(servers[1].footprintGb, 39)
    assert.equal(L.llmServers(llm({ ollama: { error: "boom" } }))[0].up, false)
})

test("llmState: down beats busy beats idle", () => {
    assert.equal(L.llmState(undefined), "")
    assert.equal(L.llmState(llm()), "idle")
    assert.equal(L.llmState(llm({ gpu: { util: 85 } })), "busy")
    assert.equal(L.llmState(llm({ gpu: { util: 85 }, ollama: { up: false } })), "down")
    assert.equal(L.llmState(llm({ mlx: [{ label: "x", up: false }] })), "down")
})

test("swapPercent", () => {
    assert.equal(L.swapPercent({ swap_used_gb: 6, swap_total_gb: 24 }), 25)
    assert.equal(L.swapPercent({ swap_used_gb: 0, swap_total_gb: 0 }), null)
    assert.equal(L.swapPercent(undefined), null)
})

test("llmChanges: servers going down, never on the first check", () => {
    const first = L.llmChanges(llm({ ollama: { up: false } }), null)
    assert.deepEqual(first.wentDown, [])
    assert.deepEqual(first.snapshot, { ollama: false, "dk.pless.mlx-rpr": true })
    const second = L.llmChanges(llm({ ollama: { up: false }, mlx: [{ label: "dk.pless.mlx-rpr", up: false }] }), first.snapshot)
    assert.deepEqual(second.wentDown.map(s => s.key), ["dk.pless.mlx-rpr"])
})

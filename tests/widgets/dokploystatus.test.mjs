import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic } from "./logic.mjs"

const L = loadLogic("dokploystatus")

const svc = (type, id, name, status) => ({ type, id, name, status })
const projects = [
    { id: "p1", name: "Shop", environments: [
        { id: "e1", name: "production", services: [
            svc("application", "a1", "web", "done"), svc("application", "a2", "worker", "error"),
            svc("compose", "c1", "stack", "running"), svc("postgres", "d1", "db", "done"),
        ] },
        { id: "e2", name: "staging", services: [] },
    ] },
    { id: "p2", name: "Blog", environments: [{ id: "e3", name: "production", services: [svc("application", "a3", "site", null)] }] },
]

test("statusKey: unknown statuses count as idle", () => {
    assert.equal(L.statusKey({ status: "error" }), "error")
    assert.equal(L.statusKey({ status: null }), "idle")
    assert.equal(L.statusKey({ status: "queued" }), "idle")
})

test("allServices and countStates", () => {
    const services = L.allServices(projects)
    assert.equal(services.length, 5)
    assert.deepEqual(L.countStates(services), { done: 2, error: 1, running: 1, idle: 1 })
})

test("groupServices: one per non-empty environment, in the given state order", () => {
    const groups = L.groupServices(projects, L.statusOrder)
    assert.deepEqual(groups.map(g => g.title), ["Shop · production", "Blog"])   // env named only when there are several
    assert.deepEqual(groups[0].services.map(s => s.name), ["worker", "stack", "db", "web"])
    assert.equal(groups[0].projectId, "p1")
    assert.equal(groups[0].environmentId, "e1")
    // The original list is left alone (QML may still be showing it).
    assert.deepEqual(projects[0].environments[0].services.map(s => s.name), ["web", "worker", "stack", "db"])
    // The order comes from the caller (main.qml's serviceStates), not a copy in logic.js.
    assert.deepEqual(L.groupServices(projects, ["done", "running", "error", "idle"])[0].services.map(s => s.name),
        ["db", "web", "stack", "worker"])
})

test("serviceUrl", () => {
    const [group] = L.groupServices(projects, L.statusOrder)
    assert.equal(L.serviceUrl("https://dokploy.example.com", group, group.services[1]),
        "https://dokploy.example.com/dashboard/project/p1/environment/e1/services/compose/c1")
})

test("freshFailures: only deployments that newly failed", () => {
    const services = L.allServices(projects)
    const first = L.freshFailures(services, null)
    assert.deepEqual(first.fresh, [])
    assert.deepEqual(first.statuses, { a1: "done", a2: "error", c1: "running", d1: "done", a3: null })
    assert.deepEqual(L.freshFailures(services, first.statuses).fresh, [])
    const second = L.freshFailures(services, { ...first.statuses, a2: "running" })
    assert.deepEqual(second.fresh.map(s => s.id), ["a2"])
})

test("panelStates", () => {
    const states = L.statusOrder.map(key => ({ key, inPanel: true }))
    assert.deepEqual(L.panelStates(states, { error: 1, done: 2 }, false).map(s => s.key), ["error", "done"])
    assert.equal(L.panelStates(states, {}, true).length, 4)
})

const now = new Date("2026-10-20T12:00:00Z")
const dep = (status, extra = {}) => ({ id: "x", status, title: "Fix login", description: "Hash: abc1234def5678",
    errorMessage: null, createdAt: "2026-10-20T09:58:00Z", startedAt: "2026-10-20T09:58:01Z", finishedAt: "2026-10-20T09:59:33Z", ...extra })

test("deploymentSummary: age, duration, title and short commit", () => {
    const d = L.deploymentSummary({ deployment: dep("done") }, now)
    assert.deepEqual({ ...d }, { minutes: 120, duration: 92, title: "Fix login", commit: "abc1234", failed: false })
    assert.equal(L.deploymentSummary({ deployment: null }, now), null)
    assert.equal(L.deploymentSummary({}, now), null)
    assert.equal(L.deploymentSummary({ deployment: dep("error") }, now).failed, true)
})

test("formatDuration and shortCommit", () => {
    assert.equal(L.formatDuration(45), "45s")
    assert.equal(L.formatDuration(92), "1m 32s")
    assert.equal(L.formatDuration(7500), "2h 5m")
    assert.equal(L.shortCommit("no hash here"), "")
    assert.equal(L.shortCommit(null), "")
})

test("failureReason: error message first line, else title, only for failed", () => {
    assert.equal(L.failureReason({ deployment: dep("error", { errorMessage: "build failed\nmore" }) }), "build failed")
    assert.equal(L.failureReason({ deployment: dep("error") }), "Fix login")
    assert.equal(L.failureReason({ deployment: dep("done") }), "")
    assert.equal(L.failureReason({}), "")
    assert.equal(L.failureReason({ deployment: dep("error", { errorMessage: "x".repeat(200) }) }).length, 160)
})

test("idleDetail: never deployed vs stopped", () => {
    assert.equal(L.idleDetail({ type: "application", status: "idle", deployment: null }), "never")
    assert.equal(L.idleDetail({ type: "compose", status: "idle", deployment: dep("done") }), "stopped")
    assert.equal(L.idleDetail({ type: "application", status: "idle" }), "")
    assert.equal(L.idleDetail({ type: "postgres", status: "idle" }), "")
    assert.equal(L.idleDetail({ type: "application", status: "done", deployment: null }), "")
})

const backup = (enabled, last) => ({ enabled, schedule: "0 3 * * *", last })
test("backupSummary", () => {
    const run = (status, createdAt, errorMessage = null) => ({ id: createdAt, status, createdAt, finishedAt: null, errorMessage })
    assert.equal(L.backupSummary({ backups: [] }, now).kind, "none")
    assert.equal(L.backupSummary({ backups: [backup(false, run("done", "2026-10-20T06:00:00Z"))] }, now).kind, "none")
    assert.equal(L.backupSummary({ backups: [backup(true, null)] }, now).kind, "waiting")
    assert.deepEqual({ ...L.backupSummary({ backups: [backup(true, run("done", "2026-10-20T06:00:00Z"))] }, now) },
        { kind: "ok", minutes: 360 })
    const failed = L.backupSummary({ backups: [backup(true, run("done", "2026-10-19T03:00:00Z")),
        backup(true, run("error", "2026-10-20T03:00:00Z", "upload failed\nstack"))] }, now)
    assert.equal(failed.kind, "failed")
    assert.equal(failed.minutes, 540)
    assert.equal("message" in failed, false)      // a backup's error text can hold credentials
})

test("multipleServers: unknown servers are ignored, local counts as one", () => {
    assert.equal(L.multipleServers([{ server: "" }, { server: "" }, {}]), false)
    assert.equal(L.multipleServers([{ server: "" }, { server: "edge-1" }]), true)
    assert.equal(L.multipleServers([{ server: "a" }, { server: "a" }, { server: null }]), false)
})

test("freshBackupFailures: once per failed run", () => {
    const failing = id => ({ id: "d1", backups: [backup(true, { id, status: "error", createdAt: id })] })
    const first = L.freshBackupFailures([failing("r1")], null)
    assert.deepEqual(first.fresh, [])
    assert.deepEqual(L.freshBackupFailures([failing("r1")], first.seen).fresh, [])
    assert.equal(L.freshBackupFailures([failing("r2")], first.seen).fresh.length, 1)
    // the entry carries the failed run itself, even when another backup of the database succeeded later
    const two = { id: "d1", backups: [backup(true, { id: "r9", status: "error", createdAt: "2026-10-20T03:00:00Z", finishedAt: "2026-10-20T03:10:00Z" }),
        backup(true, { id: "ok", status: "done", createdAt: "2026-10-20T05:00:00Z" })] }
    const entry = L.freshBackupFailures([two], first.seen, now).fresh[0]
    assert.equal(entry.service, two)
    assert.equal(entry.run.id, "r9")
    assert.equal(entry.minutes, 530)
    assert.equal(L.freshBackupFailures([two], first.seen).fresh[0].minutes, null)
    assert.deepEqual(L.freshBackupFailures([{ id: "d1", backups: [backup(true, { id: "r3", status: "done" })] }], first.seen).fresh, [])
})

test("main.qml: a deployment line without a time has no trailing 'deployed '", async () => {
    const { readFileSync } = await import("node:fs")
    const qml = readFileSync(new URL("../../dokploystatus/contents/ui/main.qml", import.meta.url), "utf8")
    assert.match(qml, /ago \? i18n\("failed %1", ago\) : i18n\("failed"\)/)
    assert.match(qml, /ago \? i18n\("deployed %1", ago\) : i18n\("deployed"\)/)
    assert.doesNotMatch(qml, /backup failed: %1/)
})

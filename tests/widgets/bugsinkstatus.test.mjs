import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic, isoAgo } from "./logic.mjs"

const L = loadLogic("bugsinkstatus")
const NOW = Date.parse("2026-10-09T12:00:00Z")

const issue = (id, firstSeenMinutesAgo, lastSeenMinutesAgo = firstSeenMinutesAgo, extra = {}) =>
    ({ id, first_seen: isoAgo(NOW, firstSeenMinutesAgo), last_seen: isoAgo(NOW, lastSeenMinutesAgo), ...extra })

const projects = [
    { id: 1, name: "Shop", open: [issue("n1", 60), issue("o1", 3 * 24 * 60, 30)], muted: 1, resolved: 4 },
    { id: 2, name: "Quiet", open: [], muted: 0, resolved: 2 },
    { id: 3, name: "Blog", open: [issue("o2", 2 * 24 * 60, 5)], muted: 2, resolved: 0 },
    { id: 4, name: "Admin", open: [issue("o3", 5 * 24 * 60, 4 * 24 * 60)], muted: 0, resolved: 0 },
]

test("isNew: first seen within 24 hours", () => {
    assert.ok(L.isNew(issue("x", 23 * 60), NOW))
    assert.ok(!L.isNew(issue("x", 24 * 60 + 1), NOW))
})

test("countStates", () => {
    assert.deepEqual(L.countStates(projects, NOW), { new: 1, open: 3, muted: 3, resolved: 6 })
    assert.deepEqual(L.countStates([], NOW), { new: 0, open: 0, muted: 0, resolved: 0 })
})

test("activeProjects: only those with open issues, most recent activity first", () => {
    // Not alphabetical: Admin's issue is the oldest.
    assert.deepEqual(L.activeProjects(projects).map(p => p.name), ["Blog", "Shop", "Admin"])
})

test("issueTitle and issueUrl", () => {
    assert.equal(L.issueTitle({ calculated_type: "KeyError", calculated_value: "'user'" }), "KeyError: 'user'")
    assert.equal(L.issueTitle({ calculated_type: "Timeout", calculated_value: "" }), "Timeout")
    assert.equal(L.issueTitle({}), "")
    assert.equal(L.issueUrl("https://bugsink.example.com", { id: "abc" }),
        "https://bugsink.example.com/issues/issue/abc/event/last/")
})

test("age", () => {
    assert.deepEqual(L.age(isoAgo(NOW, 0.2), NOW), { unit: "minute", count: 1 })
    assert.deepEqual(L.age(isoAgo(NOW, 42), NOW), { unit: "minute", count: 42 })
    assert.deepEqual(L.age(isoAgo(NOW, 5 * 60), NOW), { unit: "hour", count: 5 })
    assert.deepEqual(L.age(isoAgo(NOW, 3 * 24 * 60), NOW), { unit: "day", count: 3 })
})

test("freshIssues: new open issues, remembering earlier ones", () => {
    const first = L.freshIssues(projects, null)
    assert.deepEqual(first.fresh, [])                  // never on the first check
    assert.deepEqual(Object.keys(first.seen).sort(), ["n1", "o1", "o2", "o3"])

    const later = [{ name: "Shop", open: [issue("n1", 60), issue("n2", 1)] }]
    const second = L.freshIssues(later, first.seen)
    assert.deepEqual(second.fresh.map(o => [o.issue.id, o.project]), [["n2", "Shop"]])
    // o1 and o2 were resolved in the meantime, but stay remembered: reopening isn't "new".
    assert.deepEqual(Object.keys(second.seen).sort(), ["n1", "n2", "o1", "o2", "o3"])
})

test("panelStates and visibleStates", () => {
    const states = ["new", "open", "muted", "resolved"].map(key => ({ key, inPanel: key === "new" || key === "open" }))
    const counts = { new: 0, open: 2, muted: 1, resolved: 0 }
    assert.deepEqual(L.visibleStates(states, counts).map(s => s.key), ["open", "muted"])
    assert.deepEqual(L.panelStates(states, counts, false).map(s => s.key), ["open"])
    assert.deepEqual(L.panelStates(states, counts, true).map(s => s.key), ["new", "open"])
})

test("changes: regressions and activity since the previous poll", () => {
    const poll1 = [{ name: "Shop", open: [issue("a", 60, 5, { digested_event_count: 3 })], resolved_ids: ["r1", "r2"] }]
    const first = L.changes(poll1, null)
    assert.deepEqual(first.regressed, [])               // never on the first check
    assert.deepEqual(first.activity, {})

    const poll2 = [{ name: "Shop", open: [issue("a", 60, 1, { digested_event_count: 15 }), issue("r1", 9999, 1, { digested_event_count: 7 })],
                     resolved_ids: ["r2"] }]
    const second = L.changes(poll2, first.snapshot)
    assert.deepEqual(second.regressed.map(o => [o.issue.id, o.project]), [["r1", "Shop"]])
    assert.deepEqual(second.activity, { a: 12 })          // r1 had no earlier count, so no "+n"
    assert.deepEqual(Object.keys(second.snapshot.regressed), ["r1"])

    // Stays flagged while open, drops once it is no longer open; same count means no activity.
    const third = L.changes(poll2, second.snapshot)
    assert.deepEqual(third.regressed, [])
    assert.deepEqual(third.activity, {})
    assert.deepEqual(Object.keys(third.snapshot.regressed), ["r1"])
    assert.deepEqual(Object.keys(L.changes([{ name: "Shop", open: [], resolved_ids: [] }], third.snapshot).snapshot.regressed), [])
})

test("ordered: regressed, then active, then the rest in the given order", () => {
    const issues = ["a", "b", "c", "d"].map(id => ({ id }))
    assert.deepEqual(L.ordered(issues, { d: true }, { c: 2 }).map(i => i.id), ["d", "c", "a", "b"])
    assert.deepEqual(L.ordered(issues, {}, {}).map(i => i.id), ["a", "b", "c", "d"])
})

test("main.qml: regressions use their own Notification and setting, not the new-issue popup", async () => {
    const { readFileSync } = await import("node:fs")
    const qml = readFileSync(new URL("../../bugsinkstatus/contents/ui/main.qml", import.meta.url), "utf8")
    const fn = qml.slice(qml.indexOf("function notifyAboutRegressed"), qml.indexOf("function notifyAboutNew"))
    assert.match(fn, /regressedNotification\.sendEvent/)
    assert.doesNotMatch(fn, /newIssueNotification/)
    assert.match(fn, /notifyOnRegression/)
    assert.match(qml, /id: regressedNotification/)
    const xml = readFileSync(new URL("../../bugsinkstatus/contents/config/main.xml", import.meta.url), "utf8")
    assert.match(xml, /name="notifyOnRegression"[^>]*>\s*<label>[^<]*<\/label>\s*<default>true</)
})

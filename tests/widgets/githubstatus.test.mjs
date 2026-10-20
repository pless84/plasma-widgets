import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic } from "./logic.mjs"

const L = loadLogic("githubstatus")

const summary = {
    status: { indicator: "minor", description: "Minor Service Outage" },
    components: [
        { id: "1", name: "Git Operations", status: "operational" },
        { id: "2", name: "Actions", status: "degraded_performance" },
        { id: "g", name: "Copilot", status: "operational", group: true },
        { id: "v", name: "Visit www.githubstatus.com for more information", status: "operational" },
        { id: "3", name: "Pages", status: "operational" },
    ],
    incidents: [{ id: "i1", name: "Actions are slow" }],
    scheduled_maintenances: [{ id: "m1", status: "in_progress" }, { id: "m2", status: "scheduled" }],
}

test("parseSummary skips groups and the Visit link, keeps maintenance in progress", () => {
    const parsed = L.parseSummary(summary)
    assert.equal(parsed.indicator, "minor")
    assert.equal(parsed.summary, "Minor Service Outage")
    assert.deepEqual(parsed.components.map(c => c.name), ["Git Operations", "Actions", "Pages"])
    assert.deepEqual(parsed.incidents.map(i => i.id), ["i1"])
    assert.deepEqual(parsed.maintenances.map(m => m.id), ["m1"])
})

test("countStates and visibleComponents", () => {
    const components = L.parseSummary(summary).components
    assert.deepEqual(L.countStates(components), { operational: 2, degraded_performance: 1 })
    assert.equal(L.visibleComponents(components, true).length, 3)
    assert.deepEqual(L.visibleComponents(components, false).map(c => c.name), ["Actions"])
})

test("indicatorChanged: not on the first check, nor when unchanged", () => {
    assert.ok(!L.indicatorChanged("unknown", "none"))
    assert.ok(!L.indicatorChanged("none", "none"))
    assert.ok(L.indicatorChanged("none", "major"))
    assert.ok(L.indicatorChanged("major", "none"))
})

test("panelStates", () => {
    const states = ["major_outage", "operational"].map(key => ({ key, inPanel: true }))
    assert.deepEqual(L.panelStates(states, { operational: 11 }, false).map(s => s.key), ["operational"])
    assert.equal(L.panelStates(states, { operational: 11 }, true).length, 2)
})

const incident = (id, status, extra = {}) => ({
    id, name: "Incident " + id, status, impact: "minor",
    started_at: "2026-01-01T10:00:00Z",
    components: [{ name: "Actions" }, { name: "Pages" }],
    incident_updates: [{ id: "u-" + id + status, status, body: "We are looking.<br />Second &amp; line", display_at: "2026-01-01T10:05:00Z" }],
    ...extra,
})

test("stripHtml and oneLine", () => {
    assert.equal(L.stripHtml("a<br />b<br/>c <b>d</b> &amp; &lt;e&gt;"), "a\nb\nc d & <e>")
    assert.equal(L.stripHtml(null), "")
    assert.equal(L.oneLine("a\n b   c", 10), "a b c")
    assert.equal(L.oneLine("abcdefghij", 5), "abcd…")
})

test("parseSummary adds affected components and the latest update to incidents", () => {
    const parsed = L.parseSummary({ ...summary, incidents: [incident("i1", "investigating")] })
    const i = parsed.incidents[0]
    assert.deepEqual(i.affects, ["Actions", "Pages"])
    assert.equal(i.started, "2026-01-01T10:00:00Z")
    assert.equal(i.update.body, "We are looking.\nSecond & line")
    assert.equal(i.update.at, "2026-01-01T10:05:00Z")
    assert.deepEqual(L.parseSummary(summary).incidents[0].affects, [])
    assert.equal(L.parseSummary(summary).incidents[0].update, null)
})

test("parseSummary keeps upcoming scheduled maintenance apart", () => {
    const parsed = L.parseSummary(summary)
    assert.deepEqual(parsed.upcoming.map(m => m.id), ["m2"])
})

test("incidentChanges: nothing on the first check", () => {
    const r = L.incidentChanges(null, [incident("i1", "investigating")])
    assert.deepEqual(r.events, [])
    assert.deepEqual(r.next, { i1: { name: "Incident i1", status: "investigating" } })
})

test("incidentChanges: new, status step, resolved, unchanged", () => {
    const first = L.incidentChanges(null, [L.parseSummary({ ...summary, incidents: [incident("i1", "investigating")] }).incidents[0]])
    const open = ["i1", "investigating"]
    const parse = list => L.parseSummary({ ...summary, incidents: list }).incidents
    const same = L.incidentChanges(first.next, parse([incident(...open)]))
    assert.deepEqual(same.events, [])
    const step = L.incidentChanges(first.next, parse([incident("i1", "identified"), incident("i2", "investigating")]))
    assert.deepEqual(step.events.map(e => [e.kind, e.incident.id]), [["status", "i1"], ["new", "i2"]])
    const done = L.incidentChanges(step.next, [])
    assert.deepEqual(done.events.map(e => [e.kind, e.incident.id, e.incident.name]), [["resolved", "i1", "Incident i1"], ["resolved", "i2", "Incident i2"]])
    assert.deepEqual(done.next, {})
})

test("isToday compares the local calendar day", () => {
    const now = new Date(2026, 9, 20, 15, 0)
    assert.equal(L.isToday(new Date(2026, 9, 20, 1, 0).toISOString(), now), true)
    assert.equal(L.isToday(new Date(2026, 9, 19, 23, 59).toISOString(), now), false)
    assert.equal(L.isToday(new Date(2025, 9, 20, 15, 0).toISOString(), now), false)
})

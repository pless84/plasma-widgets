import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic } from "./logic.mjs"

const L = loadLogic("prtgstatus")

test("stateOf maps every PRTG status code", () => {
    const expected = { 1: "unknown", 2: "unknown", 3: "up", 4: "warning", 5: "down", 6: "unknown", 7: "paused",
                       8: "paused", 9: "paused", 10: "unusual", 11: "paused", 12: "paused", 13: "acknowledged", 14: "down" }
    for (const [code, key] of Object.entries(expected)) {
        assert.equal(L.stateOf(Number(code)), key, `code ${code}`)
    }
    assert.equal(L.stateOf(99), "up")                  // unknown codes count as up, as before
})

test("countStates and total", () => {
    const counts = L.countStates([5, 14, 4, 10, 13, 3, 3, 3, 7, 12, 1].map((status_raw, objid) => ({ objid, status_raw })))
    assert.deepEqual(counts, { down: 2, warning: 1, unusual: 1, acknowledged: 1, up: 3, paused: 2, unknown: 1 })
    assert.equal(L.total(counts), 11)
    assert.equal(L.total({}), 0)
})

test("splitProblems", () => {
    const sensors = [5, 4, 14, 13, 10, 3].map((status_raw, objid) => ({ objid, status_raw }))
    const p = L.splitProblems(sensors)
    assert.deepEqual(p.down.map(s => s.objid), [0, 2])
    assert.deepEqual(p.warning.map(s => s.objid), [1])
    assert.deepEqual(p.acknowledged.map(s => s.objid), [3])
    assert.deepEqual(p.unusual.map(s => s.objid), [4])
})

test("sensorUrl", () => {
    assert.equal(L.sensorUrl("https://prtg.example.com", { objid: 2001 }), "https://prtg.example.com/sensor.htm?id=2001")
})

test("freshDown: only sensors that newly went down", () => {
    const down = [{ objid: 1 }, { objid: 2 }]
    const first = L.freshDown(down, null)
    assert.deepEqual(first.fresh, [])
    assert.deepEqual(first.seen, { 1: true, 2: true })
    const second = L.freshDown([{ objid: 2 }, { objid: 3 }], first.seen)
    assert.deepEqual(second.fresh, [{ objid: 3 }])
    assert.deepEqual(second.seen, { 2: true, 3: true })  // 1 recovered: down again later counts as new
})

test("panelStates and visibleStates", () => {
    const states = Object.keys(L.stateCodes).map(key => ({ key, inPanel: key !== "paused" }))
    const counts = { down: 1, paused: 4, up: 9 }
    assert.deepEqual(L.visibleStates(states, counts).map(s => s.key), ["down", "paused", "up"])
    assert.deepEqual(L.panelStates(states, counts, false).map(s => s.key), ["down", "up"])
    assert.equal(L.panelStates(states, counts, true).length, 6)
})

test("extraStates and extraCodes: only switched-on unknown, paused and up", () => {
    const on = ["down", "warning", "paused", "up"]
    const states = Object.keys(L.stateCodes).map(key => ({ key, inPanel: on.includes(key) }))
    assert.deepEqual(L.extraStates(states).map(s => s.key), ["paused", "up"])
    assert.equal(L.extraCodes(states), "7,8,9,11,12,3")
    assert.equal(L.extraCodes(states.map(st => ({ ...st, inPanel: false }))), "")
})

test("splitExtra", () => {
    const sensors = [1, 7, 3, 12, 6, 3].map((status_raw, objid) => ({ objid, status_raw }))
    const g = L.splitExtra(sensors)
    assert.deepEqual(g.unknown.map(s => s.objid), [0, 4])
    assert.deepEqual(g.paused.map(s => s.objid), [1, 3])
    assert.deepEqual(g.up.map(s => s.objid), [2, 5])
})

test("toggled adds or removes a collapsed group", () => {
    assert.deepEqual(L.toggled([], "up"), ["up"])
    assert.deepEqual(L.toggled(["down", "up"], "up"), ["down"])
    assert.deepEqual(L.toggled(["down"], "paused"), ["down", "paused"])
})

test("priorityOf reads the number, stars or text, and defaults to 3", () => {
    assert.equal(L.priorityOf({ priority_raw: 5 }), 5)
    assert.equal(L.priorityOf({ priority: "4" }), 4)
    assert.equal(L.priorityOf({ priority: "**" }), 2)
    assert.equal(L.priorityOf({ priority: "★★★★★" }), 5)
    assert.equal(L.priorityOf({}), 3)
    assert.equal(L.priorityOf({ priority: "high", priority_raw: "x" }), 3)
    assert.equal(L.stars(3), "★★★")
})

test("prioritiesDiffer only when they are not all the same", () => {
    assert.equal(L.prioritiesDiffer([]), false)
    assert.equal(L.prioritiesDiffer([{}, { priority_raw: 3 }, { priority: "3" }]), false)
    assert.equal(L.prioritiesDiffer([{}, { priority_raw: 5 }]), true)
})

test("downSeconds uses PRTG's raw seconds first, then parses the text", () => {
    assert.equal(L.downSeconds({ downtimesince: "3 h 12 m", downtimesince_raw: 11520.4 }), 11520)
    assert.equal(L.downSeconds({ downtimesince: "3 h 12 min" }), 3 * 3600 + 12 * 60)
    assert.equal(L.downSeconds({ downtimesince: "3 h 12 m" }), 3 * 3600 + 12 * 60)
    assert.equal(L.downSeconds({ downtimesince: "2 d 4 h" }), 2 * 86400 + 4 * 3600)
    assert.equal(L.downSeconds({ downtimesince: "45 s" }), 45)
    assert.equal(L.downSeconds({ downtimesince: "", downtimesince_raw: 90 }), 90)
    assert.equal(L.downSeconds({ downtimesince: "-", downtimesince_raw: "" }), null)
    assert.equal(L.downSeconds({}), null)
})

test("formatDuration and downFor", () => {
    assert.equal(L.formatDuration(3 * 3600 + 12 * 60 + 5), "3 h 12 m")
    assert.equal(L.formatDuration(2 * 86400 + 5 * 3600 + 59 * 60), "2 d 5 h")
    assert.equal(L.formatDuration(12 * 60), "12 m")
    assert.equal(L.formatDuration(20), "<1 m")
    assert.equal(L.downFor({ downtimesince: "3 h 12 m" }), "3 h 12 m")
    assert.equal(L.downFor({}), "")
})

test("sortSensors: priority first, then longest down, then name; splitProblems sorts each group", () => {
    const s = [
        { objid: 1, device: "b", sensor: "x", status_raw: 5, priority_raw: 3, downtimesince: "1 h" },
        { objid: 2, device: "a", sensor: "x", status_raw: 5, priority_raw: 3, downtimesince: "5 h" },
        { objid: 3, device: "c", sensor: "x", status_raw: 14, priority_raw: 5, downtimesince: "1 m" },
        { objid: 4, device: "d", sensor: "x", status_raw: 5, priority_raw: 3 },
        { objid: 5, device: "a", sensor: "y", status_raw: 4, priority_raw: 3 },
        { objid: 6, device: "a", sensor: "x", status_raw: 4, priority_raw: 3 },
    ]
    const p = L.splitProblems(s)
    assert.deepEqual(p.down.map(x => x.objid), [3, 2, 1, 4])
    assert.deepEqual(p.warning.map(x => x.objid), [6, 5])
    assert.deepEqual(s.map(x => x.objid), [1, 2, 3, 4, 5, 6])   // input untouched
})

test("isPartial and sensorPath", () => {
    assert.equal(L.isPartial({ status_raw: 14 }), true)
    assert.equal(L.isPartial({ status_raw: 5 }), false)
    assert.equal(L.sensorPath({ probe: "Local", group: "Servers", device: "web", sensor: "Ping" }), "Local › Servers › web – Ping")
    assert.equal(L.sensorPath({ device: "web", sensor: "Ping" }), "web – Ping")
})

test("freshDown honours the minimum priority but remembers every down sensor", () => {
    const down = [{ objid: 1, priority_raw: 2 }, { objid: 2, priority_raw: 4 }, { objid: 3 }]
    const r = L.freshDown(down, {}, 3)
    assert.deepEqual(r.fresh.map(s => s.objid), [2, 3])
    assert.deepEqual(r.seen, { 1: true, 2: true, 3: true })
    assert.equal(L.freshDown(down, {}).fresh.length, 3)
    assert.equal(L.freshDown(down, {}, 1).fresh.length, 3)
})

test("probeSummaries, sumProbes and the all-unknown flag", () => {
    const probes = [
        { objid: 1, probe: "Local", upsens: "10", downsens: 1, partialdownsens: "2", downacksens: 1, warnsens: 3,
          unusualsens: 0, pausedsens: "4", undefinedsens: 1, totalsens: "22" },
        { objid: 2, probe: "Remote", upsens: 0, downsens: 0, partialdownsens: 0, downacksens: 0, warnsens: 0,
          unusualsens: 0, pausedsens: 0, undefinedsens: 7, totalsens: 7 },
        { objid: 3, probe: "Empty" },
    ]
    const sums = L.probeSummaries(probes)
    assert.deepEqual(sums[0].counts, { down: 3, acknowledged: 1, warning: 3, unknown: 1, paused: 4, up: 10 })
    assert.equal(sums[0].total, 22)
    assert.equal(sums[0].allUnknown, false)
    assert.equal(sums[1].allUnknown, true)
    assert.equal(sums[2].allUnknown, false)
    assert.deepEqual(L.sumProbes(sums), { down: 3, acknowledged: 1, warning: 3, unknown: 8, paused: 4, up: 10 })
    assert.deepEqual(L.probeSummaries(undefined), [])
})

test("probeSummaries reads the _raw numbers, never digits out of PRTG's HTML", () => {
    // As PRTG really sends it: each *sens column is a link around the number, the number is in *_raw.
    const root = {
        objid: 0, probe: "",
        upsens: '<a  title="Root: 855x Up"  class="sensorlinkgreen" href="sensors.htm?id=0&filter_status=2&filter_status=3"><div class="sensg">855</div></a>',
        upsens_raw: 855,
        warnsens: '<a  title="Root: 4x Warning" href="sensors.htm?id=0&filter_status=4"><div class="sensy">4</div></a>', warnsens_raw: 4,
        pausedsens: '<a href="sensors.htm?id=0&filter_status=7"><div class="sensb">60</div></a>', pausedsens_raw: 60,
        downsens: "", downsens_raw: 0, totalsens: "919", totalsens_raw: 919,
    }
    const [sum] = L.probeSummaries([root])
    assert.deepEqual(sum.counts, { warning: 4, paused: 60, up: 855 })
    assert.equal(sum.total, 919)
    // HTML without a _raw value counts as 0 rather than a number glued from the link's digits.
    assert.deepEqual(L.probeSummaries([{ upsens: '<a href="sensors.htm?id=12&filter_status=3">7</a>' }])[0].counts, {})
})

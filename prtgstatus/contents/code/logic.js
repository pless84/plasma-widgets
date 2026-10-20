.pragma library
// The PRTG Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/prtgstatus.test.mjs). main.qml imports it as Logic.

// PRTG's status_raw codes per state, in the order PRTG's status bar shows them.
var stateCodes = {
    down: [5, 14],           // Down, Down (partial)
    acknowledged: [13],
    warning: [4],
    unusual: [10],
    unknown: [1, 2, 6],
    paused: [7, 8, 9, 11, 12],
    up: [3],
}

function shellQuote(s) {
    return "'" + s.replace(/'/g, "'\\''") + "'"
}

// A status_raw code -> its state key. Codes PRTG adds later count as "up", like the widget always did.
function stateOf(code) {
    return Object.keys(stateCodes).find(key => stateCodes[key].includes(code)) || "up"
}

// fetch.sh's "all" table -> sensors per state key
function countStates(sensors) {
    const counts = {}
    sensors.forEach(s => {
        const key = stateOf(s.status_raw)
        counts[key] = (counts[key] || 0) + 1
    })
    return counts
}

// fetch.sh's "problems" table -> {down, acknowledged, warning, unusual}, each sorted by sortSensors
function splitProblems(sensors) {
    const inState = key => sortSensors(sensors.filter(s => stateCodes[key].includes(s.status_raw)))
    return { down: inState("down"), acknowledged: inState("acknowledged"), warning: inState("warning"),
             unusual: inState("unusual") }
}

// States the popup only lists when their badge is switched on (st.inPanel); the problem states
// above are always listed.
var extraStateKeys = ["unknown", "paused", "up"]

// The extra states switched on in the settings
function extraStates(states) {
    return states.filter(st => extraStateKeys.includes(st.key) && st.inPanel)
}

// fetch.sh's extra status codes argument for those states, e.g. "7,8,9,11,12"
function extraCodes(states) {
    return extraStates(states).map(st => stateCodes[st.key].join(",")).join(",")
}

// fetch.sh's "extra" table -> sensors per extra state key
function splitExtra(sensors) {
    const groups = {}
    extraStateKeys.forEach(key => groups[key] = sortSensors(sensors.filter(s => stateCodes[key].includes(s.status_raw))))
    return groups
}

// The collapsed groups list with key added, or removed if it was there
function toggled(list, key) {
    return list.includes(key) ? list.filter(k => k !== key) : list.concat([key])
}

function sensorUrl(serverUrl, sensor) {
    return serverUrl + "/sensor.htm?id=" + sensor.objid
}

// Down sensors not down at the last check, and the ids to remember. Nothing is fresh on the
// first check (seenIds null). Only sensors at or above minPriority (default: all) are fresh;
// the others are still remembered, so they don't turn up as new later.
function freshDown(down, seenIds, minPriority) {
    const fresh = down.filter(s => seenIds && !seenIds[s.objid] && priorityOf(s) >= (minPriority || 1))
    const seen = {}
    down.forEach(s => seen[s.objid] = true)
    return { fresh: fresh, seen: seen }
}

function total(counts) {
    return Object.values(counts).reduce((sum, n) => sum + n, 0)
}

// The badge states to show: those switched on in the settings (st.inPanel) with sensors in
// them, or all switched-on ones when showZero is set.
function panelStates(states, counts, showZero) {
    return states.filter(st => st.inPanel && (showZero || (counts[st.key] || 0) > 0))
}

function visibleStates(states, counts) {
    return states.filter(st => (counts[st.key] || 0) > 0)
}

// Which shared look colour role (see look.js) each colour setting follows when the widget
// uses the shared look.
var colorRoles = {
    colorDown: "error",
    colorAcknowledged: "attention",
    colorWarning: "warning",
    colorUnusual: "active",
    colorPaused: "info",
    colorUp: "ok",
    colorUnknown: "neutral",
    colorCountBackground: "countBackground"
}

// A sensor's priority 1-5 from the table's priority column. PRTG sends the number (priority_raw)
// and may send the text as a number or as stars; anything unreadable counts as the default, 3.
function priorityOf(sensor) {
    const raw = Number(sensor.priority_raw)
    if (raw >= 1 && raw <= 5) return Math.round(raw)
    const text = String(sensor.priority === undefined ? "" : sensor.priority)
    const n = /^\s*[1-5]\s*$/.test(text) ? Number(text) : (text.match(/[*★]/g) || []).length
    return n >= 1 && n <= 5 ? n : 3
}

// Whether the sensors' priorities are not all the same. Priorities are only worth showing then:
// every sensor starts out at 3.
function prioritiesDiffer(sensors) {
    return sensors.some(s => priorityOf(s) !== priorityOf(sensors[0]))
}

function stars(priority) {
    return "★".repeat(priority)
}

// How long a sensor has been down, in seconds, or null if unknown: downtimesince_raw (seconds),
// else the downtimesince text such as "3 d 4 h" or "12 min 5 s".
function downSeconds(sensor) {
    const raw = Number(sensor.downtimesince_raw)
    if (sensor.downtimesince_raw !== undefined && sensor.downtimesince_raw !== "" && raw > 0) {
        return Math.round(raw)
    }
    const units = { d: 86400, h: 3600, m: 60, min: 60, s: 1, sec: 1 }
    const parts = String(sensor.downtimesince === undefined ? "" : sensor.downtimesince).match(/(\d+(?:[.,]\d+)?)\s*(min|sec|[dhms])\b/gi)
    if (!parts) {
        return null
    }
    return Math.round(parts.reduce((sum, part) => {
        const m = part.match(/([\d.,]+)\s*(min|sec|[dhms])/i)
        return sum + Number(m[1].replace(",", ".")) * units[m[2].toLowerCase()]
    }, 0))
}

// Seconds as "3 d 4 h", "3 h 12 m" or "12 m": the two largest units, "<1 m" below a minute.
function formatDuration(seconds) {
    const d = Math.floor(seconds / 86400)
    const h = Math.floor(seconds % 86400 / 3600)
    const m = Math.floor(seconds % 3600 / 60)
    if (d > 0) return d + " d " + h + " h"
    if (h > 0) return h + " h " + m + " m"
    return m > 0 ? m + " m" : "<1 m"
}

// "3 h 12 m", or "" when the sensor's down time is unknown
function downFor(sensor) {
    const seconds = downSeconds(sensor)
    return seconds === null ? "" : formatDuration(seconds)
}

// Highest priority first, then longest down, then device and sensor name. A copy.
function sortSensors(sensors) {
    const down = s => downSeconds(s) || 0
    return sensors.slice().sort((a, b) => priorityOf(b) - priorityOf(a) || down(b) - down(a)
        || String(a.device).localeCompare(String(b.device)) || String(a.sensor).localeCompare(String(b.sensor)))
}

// Down (partial): some channels or some probes' checks fail, merged into the down group
function isPartial(sensor) {
    return sensor.status_raw === 14
}

// "Probe › Group › device – sensor", leaving out what the table didn't give
function sensorPath(sensor) {
    return [sensor.probe, sensor.group, sensor.device + " – " + sensor.sensor].filter(t => t).join(" › ")
}

// A sensor count from a probe row's *sens column. PRTG sends the column as HTML (a link around
// the number) and the number itself in <column>_raw, so the raw value wins; plain numeric text
// is accepted too. Anything else counts as 0 (never dig digits out of HTML).
function sensorCount(row, column) {
    const raw = row[column + "_raw"]
    const value = raw !== undefined && raw !== "" ? raw : row[column]
    const n = typeof value === "number" ? value : /^\s*\d+\s*$/.test(String(value)) ? parseInt(value, 10) : 0
    return n > 0 ? n : 0
}

// fetch.sh's "probes" table -> one entry per probe {name, counts (per state key, only the
// non-zero ones), total, allUnknown}. A probe that is down shows all its sensors as unknown.
function probeSummaries(probes) {
    return (probes || []).map(p => {
        const counts = {}
        const add = (key, column) => { const n = sensorCount(p, column); if (n > 0) counts[key] = (counts[key] || 0) + n }
        add("down", "downsens")
        add("down", "partialdownsens")
        add("acknowledged", "downacksens")
        add("warning", "warnsens")
        add("unusual", "unusualsens")
        add("unknown", "undefinedsens")
        add("paused", "pausedsens")
        add("up", "upsens")
        const all = Math.max(sensorCount(p, "totalsens"), total(counts))
        return { name: p.probe, counts: counts, total: all, allUnknown: all > 0 && counts.unknown === all }
    })
}

// The per-state counts summed over all probes
function sumProbes(summaries) {
    const counts = {}
    summaries.forEach(p => Object.keys(p.counts).forEach(key => counts[key] = (counts[key] || 0) + p.counts[key]))
    return counts
}

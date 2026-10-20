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

// fetch.sh's "problems" table -> {down, acknowledged, warning, unusual}
function splitProblems(sensors) {
    const inState = key => sensors.filter(s => stateCodes[key].includes(s.status_raw))
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
    extraStateKeys.forEach(key => groups[key] = sensors.filter(s => stateCodes[key].includes(s.status_raw)))
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
// first check (seenIds null).
function freshDown(down, seenIds) {
    const fresh = down.filter(s => seenIds && !seenIds[s.objid])
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

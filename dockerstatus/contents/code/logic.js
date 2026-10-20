.pragma library
// The Docker Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/dockerstatus.test.mjs). main.qml imports it as Logic.

// Docker exit codes that mean "stopped on purpose" (clean exit, Ctrl+C, docker stop's
// SIGTERM, or its SIGKILL after the timeout) rather than a crash.
var stoppedExitCodes = [0, 130, 137, 143]

function shellQuote(s) {
    return "'" + s.replace(/'/g, "'\\''") + "'"
}

// The value of one key in docker's "a=1,b=2" label string, or "".
function label(labels, key) {
    const match = new RegExp("(?:^|,)" + key.replace(/\./g, "\\.") + "=([^,]*)").exec(labels || "")
    return match ? match[1] : ""
}

// A container from `docker ps --format '{{json .}}'` -> failed | unhealthy | restarting | paused | stopped | running
function classify(c) {
    switch (c.State) {
    case "restarting": return "restarting"
    case "paused": return "paused"
    case "running":
        return c.HealthStatus === "unhealthy" || /\(unhealthy\)/.test(c.Status) ? "unhealthy" : "running"
    case "dead": return "failed"
    case "exited": {
        const exit = /Exited \((\d+)\)/.exec(c.Status)
        return exit && !stoppedExitCodes.includes(parseInt(exit[1])) ? "failed" : "stopped"
    }
    default: return "stopped" // created, removing
    }
}

// "0.0.0.0:8888->80/tcp, [::]:8888->80/tcp" -> "8888→80"
function shortPorts(ports) {
    const seen = []
    const re = /:(\d+)->(\d+)/g
    let m
    while ((m = re.exec(ports || "")) !== null) {
        const p = m[1] + "→" + m[2]
        if (!seen.includes(p)) seen.push(p)
    }
    return seen.join(", ")
}

function shortImage(image) {
    return image.startsWith("sha256:") ? image.slice(7, 19) : image
}

// fetch.sh's output (one JSON object per line) -> [{id, name, fullName, project, image, stateKey, status, ports}]
function parseContainers(stdout) {
    return stdout.split("\n").filter(line => line.trim()).map(line => JSON.parse(line)).map(c => ({
        id: c.ID,
        name: label(c.Labels, "com.docker.compose.service") || c.Names,
        fullName: c.Names,
        project: label(c.Labels, "com.docker.compose.project"),
        image: shortImage(c.Image),
        stateKey: classify(c),
        status: c.Status,
        ports: shortPorts(c.Ports),
    }))
}

function countStates(containers) {
    const counts = {}
    containers.forEach(c => counts[c.stateKey] = (counts[c.stateKey] || 0) + 1)
    return counts
}

// Containers grouped by Compose project (standalone ones last), worst state first within a group,
// following `order` (state keys, worst first).
function groupContainers(containers, order) {
    const byProject = {}
    containers.forEach(c => (byProject[c.project] = byProject[c.project] || []).push(c))
    return Object.keys(byProject)
        .sort((a, b) => (a === "") - (b === "") || a.localeCompare(b))
        .map(project => ({
            project: project,
            containers: byProject[project].sort((a, b) =>
                order.indexOf(a.stateKey) - order.indexOf(b.stateKey) || a.name.localeCompare(b.name))
        }))
}

// Whether a container is up (so it can be stopped or restarted) rather than down (so it can be started).
// Paused containers are neither.
function isActive(stateKey) {
    return stateKey === "running" || stateKey === "unhealthy" || stateKey === "restarting"
}

// Which buttons a Compose stack gets: start when any of its containers is down, stop and restart
// when any is up.
function stackActions(containers) {
    return {
        start: containers.some(c => !isActive(c.stateKey) && c.stateKey !== "paused"),
        stop: containers.some(c => isActive(c.stateKey)),
    }
}

// Containers that newly became failed or unhealthy since the last check, and the states to
// remember for the next one. Nothing is fresh on the first check (previousStates null).
function freshProblems(containers, previousStates) {
    const isProblem = key => key === "failed" || key === "unhealthy"
    const fresh = containers.filter(c => previousStates && isProblem(c.stateKey) && previousStates[c.id] !== c.stateKey)
    const states = {}
    containers.forEach(c => states[c.id] = c.stateKey)
    return { fresh: fresh, states: states }
}

// The badge states to show: those switched on in the settings (st.inPanel) with containers in
// them, or all switched-on ones when showZero is set.
function panelStates(states, counts, showZero) {
    return states.filter(st => st.inPanel && (showZero || (counts[st.key] || 0) > 0))
}

function visibleStates(states, counts) {
    return states.filter(st => (counts[st.key] || 0) > 0)
}

// The collapsed groups list with key added, or removed if it was there
function toggled(list, key) {
    return list.includes(key) ? list.filter(k => k !== key) : list.concat([key])
}

// Which shared look colour role (see look.js) each colour setting follows when the widget
// uses the shared look.
var colorRoles = {
    colorFailed: "error",
    colorUnhealthy: "attention",
    colorRestarting: "active",
    colorPaused: "info",
    colorStopped: "neutral",
    colorRunning: "ok",
    colorCountBackground: "countBackground"
}

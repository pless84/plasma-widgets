.pragma library
// The Runner Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/runnerstatus.test.mjs). main.qml imports it as Logic.

// The dashboard reports each runner as idle, busy or offline. Anything else it might report
// (e.g. a runner whose service isn't loaded) counts as offline, so it still gets a red badge.
function runnerState(runner) {
    return runner.status === "busy" || runner.status === "idle" ? runner.status : "offline"
}

// Runners per state, e.g. {idle: 2, busy: 1}
function countStates(runners) {
    const counts = {}
    runners.forEach(r => {
        const key = runnerState(r)
        counts[key] = (counts[key] || 0) + 1
    })
    return counts
}

// The badge states to show: those switched on in the settings (st.inPanel) with runners in
// them, or all switched-on ones when showZero is set.
function panelStates(states, counts, showZero) {
    return states.filter(st => st.inPanel && (showZero || (counts[st.key] || 0) > 0))
}

function visibleStates(states, counts) {
    return states.filter(st => (counts[st.key] || 0) > 0)
}

// Runners worst state first (in the order of stateKeys), then by repository.
function sortRunners(runners, stateKeys) {
    return runners.slice().sort((a, b) =>
        stateKeys.indexOf(runnerState(a)) - stateKeys.indexOf(runnerState(b))
        || title(a).localeCompare(title(b)))
}

// Several runners can share a name (one per repository), so the repository is the title.
function title(runner) {
    return runner.repo || runner.name || ""
}

// The most recently finished job, or null.
function lastJob(runner) {
    const history = runner.history || []
    return history.reduce((latest, job) => !latest || (job.finished || 0) > (latest.finished || 0) ? job : latest, null)
}

function jobFailed(job) {
    return !!job && job.result !== "Succeeded" && job.result !== "Canceled" && job.result !== "Skipped"
}

// The running job's page on GitHub, or the repository's Actions page. The URL comes from the
// dashboard (over plain http), so only http(s) links are opened, never file: or other schemes.
function actionsUrl(runner) {
    if (!/^https?:\/\/[^\s]+$/i.test(runner.repo_url || "")) {
        return ""
    }
    const job = runner.job
    return job && job.run_id ? runner.repo_url + "/actions/runs/" + job.run_id : runner.repo_url + "/actions"
}

// Seconds as "45s", "3m 12s", "2h 5m" or "4d 3h".
function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || isNaN(seconds)) {
        return "–"
    }
    const s = Math.max(0, Math.round(seconds))
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
    return d ? d + "d " + h + "h" : h ? h + "h " + m + "m" : m ? m + "m " + s % 60 + "s" : s + "s"
}

// What changed since the previous check, for notifications: runners that went offline, and jobs
// that failed since then. `previous` is the snapshot this returned last time, or null on the first
// check (which never notifies). Runners are told apart by their directory, as names repeat.
function changes(runners, previous) {
    const snapshot = {}
    const wentOffline = []
    const failedJobs = []
    runners.forEach(r => {
        const key = r.dir || title(r)
        const state = runnerState(r)
        const finished = (lastJob(r) || {}).finished || 0
        snapshot[key] = { state: state, finished: finished }

        const before = previous && previous[key]
        if (!before) {
            return
        }
        if (state === "offline" && before.state !== "offline") {
            wentOffline.push(r)
        }
        ;(r.history || []).forEach(job => {
            if ((job.finished || 0) > before.finished && jobFailed(job)) {
                failedJobs.push({ runner: r, job: job })
            }
        })
    })
    return { snapshot: snapshot, wentOffline: wentOffline, failedJobs: failedJobs }
}

// ---- Scheduled jobs (the dashboard's "jobs" block; absent on older dashboards) ----

// The dashboard reports each LaunchAgent job as ok, running, waiting (not run yet), failed,
// missed, "not loaded" or error. As badge colours: ok is idle (green), running is busy
// (yellow), waiting is neutral, and anything else (including statuses it may add later) is
// a problem (red).
function jobState(job) {
    switch (job.status) {
    case "ok": return "idle"
    case "running": return "busy"
    case "waiting": return "waiting"
    default: return "offline"
    }
}

function jobFailing(job) {
    return jobState(job) === "offline"
}

function failingJobs(jobs) {
    return (jobs || []).filter(jobFailing)
}

// Failing jobs first, then by name.
function sortJobs(jobs) {
    return (jobs || []).slice().sort((a, b) =>
        (jobFailing(b) ? 1 : 0) - (jobFailing(a) ? 1 : 0) || String(a.name || "").localeCompare(String(b.name || "")))
}

// The newest line of a job's log ({time, text}), or null.
function lastLogLine(job) {
    const log = job.log || []
    return log.length > 0 ? log[0] : null
}

// Jobs that started failing since the previous check, or failed again on a new run, for
// notifications. `previous` is the snapshot this returned last time, or null on the first check
// (which never notifies). Jobs are told apart by their launchd label.
function jobChanges(jobs, previous) {
    const snapshot = {}
    const newlyFailing = []
    ;(jobs || []).forEach(j => {
        const key = j.label || j.name
        const failing = jobFailing(j)
        snapshot[key] = { failing: failing, lastRun: j.last_run || 0 }
        const before = previous && previous[key]
        if (failing && before && (!before.failing || (j.last_run || 0) > before.lastRun)) {
            newlyFailing.push(j)
        }
    })
    return { snapshot: snapshot, newlyFailing: newlyFailing }
}

// The collapsed groups list with key added, or removed if it was there
function toggled(list, key) {
    return list.includes(key) ? list.filter(k => k !== key) : list.concat([key])
}

// Which shared look colour role (see look.js) each colour setting follows when the widget
// uses the shared look.
var colorRoles = {
    colorOffline: "error",
    colorBusy: "active",
    colorIdle: "ok",
    colorCountBackground: "countBackground"
}

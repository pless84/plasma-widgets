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

// ---- Running job context and duration ----

// "#412 · main · push by pless84" from the running job's run_number, ref, event_name and actor.
// Any of them may be missing; "" when none is known.
function jobContext(job) {
    if (!job) {
        return ""
    }
    const ref = String(job.ref || "").replace(/^refs\/heads\//, "")
    const who = job.event_name && job.actor ? job.event_name + " by " + job.actor
        : job.actor ? "by " + job.actor : job.event_name || ""
    return [job.run_number ? "#" + job.run_number : "", ref, who].filter(t => t).join(" · ")
}

// The median duration (seconds) of succeeded jobs of this name in the runner's history, or null
// with fewer than 3 samples. Jobs without a start time are skipped, and so are failed, canceled
// and skipped ones (they end early and would make a normal run look slow).
function usualDuration(runner, jobName) {
    const durations = (runner.history || [])
        .filter(h => h.name === jobName && h.result === "Succeeded" && h.started && h.finished > h.started)
        .map(h => h.finished - h.started)
        .sort((a, b) => a - b)
    if (!jobName || durations.length < 3) {
        return null
    }
    const mid = Math.floor(durations.length / 2)
    return durations.length % 2 ? durations[mid] : (durations[mid - 1] + durations[mid]) / 2
}

// How long the runner's current job has run (`now` is the server's clock) against its usual
// duration: {running, usual, slow}, or null when no job runs. `usual` is null when unknown;
// `slow` is set past twice the usual duration and at least SLOW_MIN_EXTRA seconds beyond it, so
// a job that usually takes seconds isn't called slow after a few more.
var SLOW_MIN_EXTRA = 300

function jobTiming(runner, now) {
    const job = runner.job
    if (!job || !job.started || !now) {
        return null
    }
    const running = Math.max(0, now - job.started)
    const usual = usualDuration(runner, job.job)
    return { running: running, usual: usual, slow: usual !== null && running > 2 * usual && running - usual >= SLOW_MIN_EXTRA }
}

// Runners whose job runs far past its usual duration, for the "likely hung" notification.
// `previous` is the list of keys this returned last time, or null on the first check (which
// never notifies); each job is reported once.
function hungJobs(runners, now, previous) {
    const keys = []
    const fresh = []
    runners.forEach(r => {
        const timing = jobTiming(r, now)
        if (timing && timing.slow) {
            const key = (r.dir || title(r)) + "@" + r.job.started
            keys.push(key)
            if (previous && !previous.includes(key)) {
                fresh.push(r)
            }
        }
    })
    return { keys: keys, hung: fresh }
}

// ---- Why a runner is offline ----

function exitCodeOf(value) {
    const n = parseInt(value, 10)
    return isNaN(n) ? null : n
}

// Why an offline runner is down, from launchd: {kind: "notLoaded"} when its service isn't loaded,
// {kind: "crashed", exitCode, runs} after a non-zero exit, {kind: "stopped", exitCode, runs}
// otherwise (loaded but not listening). null when the runner isn't offline or nothing is known.
function offlineReason(runner) {
    const svc = runner.launchd
    if (runnerState(runner) !== "offline" || !svc) {
        return null
    }
    if (svc.loaded === false) {
        return { kind: "notLoaded" }
    }
    if (svc.loaded !== true) {
        return null
    }
    const exitCode = exitCodeOf(svc.last_exit_code)
    return { kind: exitCode ? "crashed" : "stopped", exitCode: exitCode, runs: exitCodeOf(svc.runs) }
}

// ---- Host ----

// One-minute load per CPU core, or null when unknown.
function loadPerCore(host) {
    const load = host && host.load && host.load[0]
    return host && host.cpus > 0 && typeof load === "number" ? load / host.cpus : null
}

// Free disk space in percent, or null when unknown.
function diskFreePercent(host) {
    return host && host.disk_total_gb > 0 && typeof host.disk_free_gb === "number"
        ? host.disk_free_gb / host.disk_total_gb * 100 : null
}

var lowDiskPercent = 10

// Free space (percent) above which a low-disk warning is cleared, so a disk hovering around the
// limit doesn't notify again and again.
var lowDiskClearPercent = 12

function diskLow(host) {
    const free = diskFreePercent(host)
    return free !== null && free < lowDiskPercent
}

// {low, notify}: notify is set once, when free space drops below the limit; it is low until
// free space is back above lowDiskClearPercent. `wasLow` is the previous low, or null before the
// first check with host data (which never notifies). Without host data `low` stays as it was.
function lowDiskChange(host, wasLow) {
    const free = diskFreePercent(host)
    if (free === null) {
        return { low: wasLow, notify: false }
    }
    const low = wasLow === true ? free <= lowDiskClearPercent : free < lowDiskPercent
    return { low: low, notify: low && wasLow === false }
}

// Megabytes as "640 MB" or "1.4 GB"; "" when unknown.
function formatMb(mb) {
    if (typeof mb !== "number" || isNaN(mb)) {
        return ""
    }
    return mb >= 1024 ? (mb / 1024).toFixed(1) + " GB" : Math.round(mb) + " MB"
}

// ---- Warnings and recent results ----

// A problem's time as seconds since the epoch: a number as is, an ISO-like string parsed, else null.
function problemTime(time) {
    if (typeof time === "number" && !isNaN(time)) {
        return time
    }
    const parsed = typeof time === "string" ? Date.parse(time.trim().replace(" ", "T")) / 1000 : NaN
    return isNaN(parsed) ? null : parsed
}

// The warning/error log lines (newest first) from the last 24 hours, as {time, msg, …}. The
// dashboard sends the last 5 whatever their age. One without a usable time can't be aged, so it
// is kept (with time null) rather than hidden, after the ones with a time.
function recentProblems(runner, now) {
    return (runner.problems || [])
        .map(p => Object.assign({}, p, { time: problemTime(p.time) }))
        .filter(p => p.time === null || now - p.time <= 86400)
        .sort((a, b) => (b.time === null ? -Infinity : b.time) - (a.time === null ? -Infinity : a.time))
}

// The runner's last up to 10 results, newest first: {total, passed, results}, or null without any.
// Canceled and skipped jobs count as passed (they are not failures, see jobFailed).
function recentResults(runner) {
    const results = (runner.history || [])
        .slice()
        .sort((a, b) => (b.finished || 0) - (a.finished || 0))
        .slice(0, 10)
        .map(h => h.result)
    return results.length > 0
        ? { total: results.length, passed: results.filter(r => !jobFailed({ result: r })).length, results: results }
        : null
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

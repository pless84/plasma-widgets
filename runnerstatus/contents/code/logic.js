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

// ---- Local LLMs (the dashboard's "llm" block; absent on older dashboards) ----

// GPU load (percent) at or above which the LLM badge shows as busy.
var LLM_BUSY_PERCENT = 10

// The last part of a model path, e.g. "Org/Model-8bit" → "Model-8bit".
function shortModel(name) {
    return String(name || "").split("/").pop()
}

// The newest request's time from a list of {time}, or 0.
function lastRequestTime(requests) {
    return (requests || []).reduce((latest, r) => Math.max(latest, r.time || 0), 0)
}

// Ollama and every MLX server as one list: {key, kind, name, up, …}. Empty without LLM data.
function llmServers(llm) {
    if (!llm) {
        return []
    }
    const servers = []
    const o = llm.ollama
    if (o) {
        servers.push({ key: "ollama", kind: "ollama", name: "Ollama", up: !o.error && !!o.up,
            error: o.error || "", version: o.version || "", models: o.models || [],
            lastRequest: lastRequestTime(o.requests) })
    }
    if (Array.isArray(llm.mlx)) {
        llm.mlx.forEach(s => servers.push({ key: s.label || s.model || "mlx", kind: "mlx",
            name: shortModel(s.model) || s.label || "MLX", up: !!s.up, label: s.label || "",
            footprintGb: s.footprint_gb, promptCache: s.prompt_cache, uptime: s.uptime,
            lastRequest: lastRequestTime(s.requests) }))
    }
    return servers
}

// "down" if any LLM server is down, "busy" while the GPU is working, else "idle"; "" without LLM data.
function llmState(llm) {
    if (!llm) {
        return ""
    }
    if (llmServers(llm).some(s => !s.up)) {
        return "down"
    }
    const util = llm.gpu && llm.gpu.util
    return util >= LLM_BUSY_PERCENT ? "busy" : "idle"
}

// Swap use in percent, or null when unknown.
function swapPercent(memory) {
    return memory && memory.swap_total_gb ? Math.round(memory.swap_used_gb / memory.swap_total_gb * 100) : null
}

// LLM servers that went down since the previous check, for notifications. `previous` is the
// snapshot this returned last time, or null on the first check (which never notifies).
function llmChanges(llm, previous) {
    const snapshot = {}
    const wentDown = []
    llmServers(llm).forEach(s => {
        snapshot[s.key] = s.up
        if (previous && previous[s.key] === true && !s.up) {
            wentDown.push(s)
        }
    })
    return { snapshot: snapshot, wentDown: wentDown }
}

// The collapsed groups list with key added, or removed if it was there
function toggled(list, key) {
    return list.includes(key) ? list.filter(k => k !== key) : list.concat([key])
}

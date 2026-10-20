.pragma library
// The LLM Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/llmstatus.test.mjs). main.qml imports it as Logic.
//
// Both sources end up as the same "llm" block, the shape the Mac server dashboard's
// /api/status uses: {gpu: {util, alloc_gb, mem_used_gb, mem_total_gb, name}, memory,
// ollama: {up, error, version, models: [{name, size_gb, vram_gb, expires, params, quant, context}],
// installed: [{name, size_gb, params, quant, capabilities}], requests: [{time, secs, status}]}, mlx: [...]}.

// GPU load (percent) at or above which the status badge shows as "GPU busy" (while a model is
// loaded). The GPU may be shared with other programs, so this is not proof that a model is
// generating; see modelInUse() for that.
var BUSY_PERCENT = 10

// GPU temperature (°C) at or above which it is shown as a warning.
var TEMP_WARN = 85

// Seconds as "45s", "3m 12s", "2h 5m" or "4d 3h".
function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || isNaN(seconds)) {
        return "–"
    }
    const s = Math.max(0, Math.round(seconds))
    const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
    return d ? d + "d " + h + "h" : h ? h + "h " + m + "m" : m ? m + "m " + s % 60 + "s" : s + "s"
}

// Bytes as gigabytes with one decimal, e.g. 8149190253 → 8.1.
function gigabytes(bytes) {
    return Math.round((bytes || 0) / 1e8) / 10
}

// The last part of a model path, e.g. "Org/Model-8bit" → "Model-8bit".
function shortModel(name) {
    return String(name || "").split("/").pop()
}

// The newest request's time from a list of {time}, or 0.
function lastRequestTime(requests) {
    return (requests || []).reduce((latest, r) => Math.max(latest, r.time || 0), 0)
}

// A number as a context size: 8192 → "8k", 131072 → "128k", 1048576 → "1M". "" when unknown.
function shortCount(n) {
    if (!(n > 0)) {
        return ""
    }
    const k = n / 1024
    return k >= 1024 ? Math.round(k / 1024 * 10) / 10 + "M" : k >= 1 ? Math.round(k * 10) / 10 + "k" : String(n)
}

// A model's parameter count, quantization and capabilities (vision, tools…) as a list of
// the ones that are known. Ollama's "completion" capability is every text model's, so it's left out.
function modelDetails(model) {
    return [model.params, model.quant].concat(model.capabilities || []).filter(t => t && t !== "completion")
}

// Ollama's GPU memory use in GB: what its loaded models have in VRAM. Null without a loaded model.
function ollamaVramGb(models) {
    if (!models || models.length === 0) {
        return null
    }
    const bytes = models.reduce((sum, m) => sum + (m.size_vram || 0), 0)
    return bytes > 0 ? gigabytes(bytes) : Math.round(models.reduce((sum, m) => sum + (m.vram_gb || 0), 0) * 10) / 10
}

// A time like Ollama's expires_at (nanoseconds, ".837530123") as seconds since the epoch, or NaN.
function parseTime(text) {
    return Date.parse(String(text).replace(/(\.\d{3})\d+/, "$1")) / 1000
}

// Which loaded models were used since the previous check. Ollama pushes a model's expires_at
// forward whenever it serves a request, so a later expiry than last time means "used".
// `previous` is what this returned last time (null at first); `now` is in seconds.
// Approximate: only as exact as the polling interval. Returns {expires, used: {name: seconds}}.
// `models` null means /api/ps didn't answer: nothing is known, so `previous` is kept as it is.
function trackUsage(previous, models, now) {
    if (models === null && previous) {
        return previous
    }
    const expires = {}
    const used = {}
    ;(models || []).forEach(m => {
        const e = parseTime(m.expires)
        expires[m.name] = e
        if (previous && previous.expires[m.name] !== undefined && e > previous.expires[m.name] + 1) {
            used[m.name] = now
        } else if (previous && previous.used[m.name] !== undefined) {
            used[m.name] = previous.used[m.name]
        }
    })
    return { expires: expires, used: used }
}

// Whether this model served a request since the previous check, from trackUsage()'s result.
function modelInUse(usage, name, now) {
    return !!usage && usage.used[name] !== undefined && usage.used[name] === now
}

// Whether an address points at this computer, where gpu.sh reads the GPU. Anything else
// (another host, an unparsable address) is not local.
function isLocalHost(url) {
    const m = /^(?:[a-z][a-z0-9+.-]*:\/\/)?(?:[^\/@]*@)?(\[[^\]]*\]|[^\/:?#]*)/i.exec(String(url || "").trim())
    const host = m ? m[1].toLowerCase() : ""
    return host === "localhost" || host === "[::1]" || /^127(\.\d{1,3}){3}$/.test(host)
}

// The newest of a list of {time, secs, status} as {time, secs, status, failed} (failed: HTTP 400
// or above), or null without requests. secs and status are null when not reported.
function latestRequest(requests) {
    const newest = (requests || []).reduce((best, r) => !best || (r.time || 0) > (best.time || 0) ? r : best, null)
    if (!newest) {
        return null
    }
    const status = typeof newest.status === "number" ? newest.status : null
    return { time: newest.time || 0, secs: typeof newest.secs === "number" ? newest.secs : null,
             status: status, failed: status !== null && status >= 400 }
}

// One process_name from nvidia-smi as the program's name: "/usr/lib/firefox/firefox" → "firefox".
function processName(path) {
    return String(path || "").trim().split("/").pop()
}

// The GPU from gpu.sh's output: one "util, used MiB, total MiB, temperature, power, power limit,
// name" line per GPU (older: "util, used MiB, total MiB, name"; unreported values are empty or
// "[N/A]"), then optionally "# apps" and a "pid, process, used MiB" line per compute process.
// Several GPUs count as one: the busiest one's load and hottest temperature, their memory and
// power added up. `apps` lists the programs using GPU memory other than Ollama, biggest first.
// Null without a GPU.
function parseGpu(text) {
    const lines = String(text || "").split("\n")
    const appsAt = lines.findIndex(line => line.trim() === "# apps")
    const isNumber = p => p !== "" && !isNaN(Number(p))
    // Any bracketed value ("[N/A]", "[Not Supported]", "[Unknown Error]"…) is nvidia-smi saying it can't tell.
    const isUnknown = p => p === "" || /^\[.*\]$/.test(p)
    const orNull = p => isNumber(p) ? Number(p) : null
    const gpus = (appsAt < 0 ? lines : lines.slice(0, appsAt)).map(line => line.split(",").map(part => part.trim()))
        .filter(parts => parts.length >= 3 && isNumber(parts[0]) && parts.slice(1, 3).every(p => isNumber(p) || isUnknown(p)))
        .map(parts => {
            const extended = parts.length >= 7 && parts.slice(3, 6).every(p => isNumber(p) || isUnknown(p))
            const [temp, power, limit] = extended ? parts.slice(3, 6).map(orNull) : [null, null, null]
            return { util: Number(parts[0]), used: orNull(parts[1]), total: orNull(parts[2]),
                     temp: temp, power: power, limit: limit, name: parts.slice(extended ? 6 : 3).join(",") }
        })
    if (gpus.length === 0) {
        return null
    }
    const sumOf = key => {
        const values = gpus.map(g => g[key]).filter(v => v !== null)
        return values.length > 0 ? values.reduce((a, b) => a + b, 0) : null
    }
    const temps = gpus.map(g => g.temp).filter(v => v !== null)
    const byName = {}
    ;(appsAt < 0 ? [] : lines.slice(appsAt + 1)).map(line => line.split(",").map(part => part.trim()))
        .filter(parts => parts.length >= 3 && isNumber(parts[parts.length - 1]))
        .forEach(parts => {
            const name = processName(parts.slice(1, -1).join(","))
            if (name && !name.toLowerCase().startsWith("ollama")) {
                byName[name] = (byName[name] || 0) + Number(parts[parts.length - 1])
            }
        })
    const used = sumOf("used")
    const total = sumOf("total")
    const power = sumOf("power")
    const limit = sumOf("limit")
    return {
        util: Math.max.apply(null, gpus.map(g => g.util)),
        mem_used_gb: used === null ? null : Math.round(used / 1024 * 10) / 10,
        mem_total_gb: total === null ? null : Math.round(total / 1024 * 10) / 10,
        temp_c: temps.length > 0 ? Math.round(Math.max.apply(null, temps)) : null,
        power_w: power === null ? null : Math.round(power),
        power_limit_w: limit === null ? null : Math.round(limit),
        apps: Object.keys(byName).map(name => ({ name: name, used_gb: Math.round(byName[name] / 1024 * 10) / 10 }))
            .sort((a, b) => b.used_gb - a.used_gb),
        name: gpus.map(g => g.name).filter(n => n).join(" + ")
    }
}

// The "llm" block for an Ollama server, from its /api/version, /api/ps and /api/tags replies
// (parsed JSON, or null when that request failed) and the GPU (or null).
function fromOllama(version, ps, tags, gpu, error) {
    const up = !!version && !error
    const models = up && ps && Array.isArray(ps.models) ? ps.models.map(m => ({
        name: m.name || m.model || "",
        size_gb: gigabytes(m.size),
        vram_gb: gigabytes(m.size_vram),
        size: m.size || 0,
        size_vram: m.size_vram || 0,
        expires: m.expires_at || "",
        params: (m.details || {}).parameter_size || "",
        quant: (m.details || {}).quantization_level || "",
        context: m.context_length || 0
    })) : []
    const installed = up && tags && Array.isArray(tags.models)
        ? tags.models.map(m => ({ name: m.name || m.model || "", size_gb: gigabytes(m.size),
            params: (m.details || {}).parameter_size || "", quant: (m.details || {}).quantization_level || "",
            capabilities: Array.isArray(m.capabilities) ? m.capabilities : [] }))
            .sort((a, b) => a.name.localeCompare(b.name))
        : []
    return {
        gpu: gpu,
        memory: null,
        ollama: { up: up, error: up ? "" : (error || "Not responding"), version: version ? version.version || "" : "",
                  models: models, installed: installed },
        mlx: []
    }
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
            installed: o.installed || [], lastRequest: lastRequestTime(o.requests), request: latestRequest(o.requests) })
    }
    if (Array.isArray(llm.mlx)) {
        llm.mlx.forEach(s => servers.push({ key: s.label || s.model || "mlx", kind: "mlx",
            name: shortModel(s.model) || s.label || "MLX", up: !!s.up, label: s.label || "",
            footprintGb: s.footprint_gb, promptCache: s.prompt_cache, uptime: s.uptime,
            lastRequest: lastRequestTime(s.requests), request: latestRequest(s.requests) }))
    }
    return servers
}

// "down" if any server is down, "busy" while the GPU is busy and a model is loaded (it may be
// another program's load: that is "GPU busy", not "generating"), else "idle"; "" without data.
function llmState(llm) {
    if (!llm) {
        return ""
    }
    if (llmServers(llm).some(s => !s.up)) {
        return "down"
    }
    const util = llm.gpu && llm.gpu.util
    return util >= BUSY_PERCENT && loadedCount(llm) > 0 ? "busy" : "idle"
}

// Models loaded in memory: Ollama's, plus one per running MLX server.
function loadedCount(llm) {
    return llmServers(llm).reduce((n, s) => n + (!s.up ? 0 : s.kind === "ollama" ? s.models.length : 1), 0)
}

// How much of a loaded model sits in GPU memory, in percent (Ollama splits big models
// between GPU and CPU), or null when unknown. Uses the dashboard's own figure (gpu_pct) when
// there is one, else the exact byte sizes, else the GB sizes.
function gpuPercent(model) {
    if (typeof model.gpu_pct === "number" && !isNaN(model.gpu_pct)) {
        return Math.round(model.gpu_pct)
    }
    if (model.size > 0) {
        return Math.floor(model.size_vram / model.size * 100)
    }
    return model.size_gb > 0 && typeof model.vram_gb === "number" ? Math.round(model.vram_gb / model.size_gb * 100) : null
}

// Swap use in percent, or null when unknown.
function swapPercent(memory) {
    return memory && memory.swap_total_gb ? Math.round(memory.swap_used_gb / memory.swap_total_gb * 100) : null
}

// Servers that went down since the previous check, for notifications. `previous` is the
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

// Which shared look colour role (see look.js) each colour setting follows when the widget
// uses the shared look.
var colorRoles = {
    colorDown: "error",
    colorBusy: "active",
    colorIdle: "ok",
    colorLoaded: "info",
    colorCountBackground: "countBackground"
}

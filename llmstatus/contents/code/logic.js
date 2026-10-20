.pragma library
// The LLM Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/llmstatus.test.mjs). main.qml imports it as Logic.
//
// Both sources end up as the same "llm" block, the shape the Mac server dashboard's
// /api/status uses: {gpu: {util, alloc_gb, mem_used_gb, mem_total_gb, name}, memory,
// ollama: {up, error, version, models: [{name, size_gb, vram_gb, expires}], installed}, mlx: [...]}.

// GPU load (percent) at or above which the status badge shows as busy.
var BUSY_PERCENT = 10

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

// The GPU from gpu.sh's output: one "util, used MiB, total MiB, name" line per GPU. Several
// GPUs count as one: the busiest one's load and their memory added up. Null without a GPU.
function parseGpu(text) {
    const gpus = String(text || "").split("\n").map(line => line.split(",").map(part => part.trim()))
        .filter(parts => parts.length >= 3 && parts.slice(0, 3).every(p => p !== "" && !isNaN(Number(p))))
    if (gpus.length === 0) {
        return null
    }
    const used = gpus.reduce((sum, g) => sum + Number(g[1]), 0)
    const total = gpus.reduce((sum, g) => sum + Number(g[2]), 0)
    return {
        util: Math.max.apply(null, gpus.map(g => Number(g[0]))),
        mem_used_gb: Math.round(used / 1024 * 10) / 10,
        mem_total_gb: Math.round(total / 1024 * 10) / 10,
        name: gpus.map(g => g.slice(3).join(",")).filter(n => n).join(" + ")
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
        expires: m.expires_at || ""
    })) : []
    const installed = up && tags && Array.isArray(tags.models)
        ? tags.models.map(m => ({ name: m.name || m.model || "", size_gb: gigabytes(m.size) }))
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
            installed: o.installed || [], lastRequest: lastRequestTime(o.requests) })
    }
    if (Array.isArray(llm.mlx)) {
        llm.mlx.forEach(s => servers.push({ key: s.label || s.model || "mlx", kind: "mlx",
            name: shortModel(s.model) || s.label || "MLX", up: !!s.up, label: s.label || "",
            footprintGb: s.footprint_gb, promptCache: s.prompt_cache, uptime: s.uptime,
            lastRequest: lastRequestTime(s.requests) }))
    }
    return servers
}

// "down" if any server is down, "busy" while the GPU is working, else "idle"; "" without data.
function llmState(llm) {
    if (!llm) {
        return ""
    }
    if (llmServers(llm).some(s => !s.up)) {
        return "down"
    }
    const util = llm.gpu && llm.gpu.util
    return util >= BUSY_PERCENT ? "busy" : "idle"
}

// Models loaded in memory: Ollama's, plus one per running MLX server.
function loadedCount(llm) {
    return llmServers(llm).reduce((n, s) => n + (!s.up ? 0 : s.kind === "ollama" ? s.models.length : 1), 0)
}

// How much of a loaded model sits in GPU memory, in percent (Ollama splits big models
// between GPU and CPU), or null when unknown. Uses the exact byte sizes when there are any.
function gpuPercent(model) {
    if (model.size > 0) {
        return Math.floor(model.size_vram / model.size * 100)
    }
    return model.size_gb > 0 ? Math.round(model.vram_gb / model.size_gb * 100) : null
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

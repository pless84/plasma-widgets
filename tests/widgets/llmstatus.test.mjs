import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic } from "./logic.mjs"

const L = loadLogic("llmstatus")

// Ollama's own replies, as on this machine.
const version = { version: "0.34.1" }
const ps = { models: [{ name: "qwen3:8b", model: "qwen3:8b", size: 6200000000, size_vram: 4650000000, expires_at: "2026-10-20T10:05:00+02:00",
                        context_length: 8192, details: { parameter_size: "8.2B", quantization_level: "Q4_K_M" } }] }
const tags = { models: [{ name: "qwen3:8b", size: 5225388164 },
                        { name: "gemma3:12b", size: 8149190253, details: { parameter_size: "12.2B", quantization_level: "Q4_K_M" },
                          capabilities: ["completion", "vision"] }] }

test("llmServers: the one server, up or down", () => {
    assert.deepEqual(L.llmServers(undefined), [])
    assert.deepEqual(L.llmServers(L.fromOllama(version, ps, tags, null, "")).map(s => [s.key, s.name, s.up]), [["ollama", "Ollama", true]])
    assert.equal(L.llmServers({ ollama: { error: "boom" } })[0].up, false)
})

test("llmState: down beats busy beats idle", () => {
    assert.equal(L.llmState(undefined), "")
    assert.equal(L.llmState(L.fromOllama(version, ps, tags, null, "")), "idle")
    assert.equal(L.llmState(L.fromOllama(version, ps, tags, { util: 85 }, "")), "busy")
    assert.equal(L.llmState(L.fromOllama(null, null, null, { util: 85 }, "Can't reach")), "down")
})

test("llmChanges: servers going down, never on the first check", () => {
    const up = L.fromOllama(version, ps, tags, null, "")
    const down = L.fromOllama(null, null, null, null, "Can't reach")
    const first = L.llmChanges(down, null)
    assert.deepEqual(first.wentDown, [])
    assert.deepEqual(first.snapshot, { ollama: false })
    const second = L.llmChanges(up, first.snapshot)
    assert.deepEqual(second.wentDown, [])
    const third = L.llmChanges(down, second.snapshot)
    assert.deepEqual(third.wentDown.map(s => s.key), ["ollama"])
})

test("fromOllama: version, loaded and installed models", () => {
    const block = L.fromOllama(version, ps, tags, { util: 40 }, "")
    assert.equal(block.gpu.util, 40)
    assert.deepEqual(block.ollama.models, [{ name: "qwen3:8b", size_gb: 6.2, vram_gb: 4.7, size: 6200000000, size_vram: 4650000000,
                                             expires: "2026-10-20T10:05:00+02:00", params: "8.2B", quant: "Q4_K_M", context: 8192 }])
    assert.deepEqual(block.ollama.installed.map(m => m.name), ["gemma3:12b", "qwen3:8b"])
    assert.equal(block.ollama.installed[0].size_gb, 8.1)
    assert.deepEqual(block.ollama.installed[0], { name: "gemma3:12b", size_gb: 8.1, params: "12.2B", quant: "Q4_K_M", capabilities: ["completion", "vision"] })
    assert.deepEqual(block.ollama.installed[1].capabilities, [])
    const [server] = L.llmServers(block)
    assert.equal(server.up, true)
    assert.equal(server.version, "0.34.1")
    assert.equal(L.llmState(block), "busy")
})

test("fromOllama: a server that doesn't answer is down, with the reason", () => {
    const block = L.fromOllama(null, null, null, null, "Can't reach http://localhost:11434")
    const [server] = L.llmServers(block)
    assert.equal(server.up, false)
    assert.equal(server.error, "Can't reach http://localhost:11434")
    assert.deepEqual(server.models, [])
    assert.equal(L.llmState(block), "down")
    assert.equal(L.loadedCount(block), 0)
})

test("fromOllama: an answering server with failed model lists is up with no models", () => {
    const block = L.fromOllama(version, null, null, null, "")
    assert.equal(L.llmServers(block)[0].up, true)
    assert.equal(L.loadedCount(block), 0)
})

test("loadedCount: the server's loaded models", () => {
    assert.equal(L.loadedCount(null), 0)
    assert.equal(L.loadedCount(L.fromOllama(version, ps, tags, null, "")), 1)
    assert.equal(L.loadedCount(L.fromOllama(null, null, null, null, "down")), 0)
})

test("gpuPercent: how much of a model sits in GPU memory", () => {
    assert.equal(L.gpuPercent({ size_gb: 6.2, vram_gb: 6.2 }), 100)
    assert.equal(L.gpuPercent({ size_gb: 10, vram_gb: 4 }), 40)
    assert.equal(L.gpuPercent({ size_gb: 0, vram_gb: 0 }), null)
    // Exact bytes win: 40 MB on the CPU isn't "all on GPU", even though both round to 6.2 GB.
    assert.equal(L.gpuPercent({ size_gb: 6.2, vram_gb: 6.2, size: 6200000000, size_vram: 6160000000 }), 99)
    // No VRAM size (LM Studio): unknown, never "NaN% on GPU".
    assert.equal(L.gpuPercent({ size_gb: 9.1 }), null)
})

test("parseGpu: nvidia-smi and AMD lines; several GPUs count as one", () => {
    assert.deepEqual(L.parseGpu("2, 2471, 12227, NVIDIA GeForce RTX 5070\n"),
                     { util: 2, mem_used_gb: 2.4, mem_total_gb: 11.9, temp_c: null, power_w: null, power_limit_w: null, apps: [],
                       name: "NVIDIA GeForce RTX 5070" })
    const two = L.parseGpu("10, 1024, 8192, GPU A\n70, 2048, 8192, GPU B")
    assert.equal(two.util, 70)
    assert.equal(two.mem_used_gb, 3)
    assert.equal(two.mem_total_gb, 16)
    assert.equal(two.name, "GPU A + GPU B")
    assert.equal(L.parseGpu(""), null)
    assert.equal(L.parseGpu("NVIDIA-SMI has failed because it couldn't communicate with the driver"), null)
    assert.equal(L.parseGpu("[N/A], 100, 200, Odd GPU"), null)
})

test("gigabytes and formatDuration", () => {
    assert.equal(L.gigabytes(8149190253), 8.1)
    assert.equal(L.gigabytes(undefined), 0)
    assert.equal(L.formatDuration(272), "4m 32s")
    assert.equal(L.formatDuration(null), "–")
})

test("llmState: GPU busy needs a loaded model; a model-less GPU load (a game) doesn't count", () => {
    const noModel = L.fromOllama(version, { models: [] }, tags, { util: 95 }, "")
    assert.equal(L.llmState(noModel), "idle")
    assert.equal(L.llmState(L.fromOllama(version, ps, tags, { util: 95 }, "")), "busy")
    assert.equal(L.llmState(L.fromOllama(version, ps, tags, { util: 3 }, "")), "idle")
    assert.equal(L.llmState(L.fromOllama(version, ps, tags, null, "")), "idle")
})

test("modelInUse: only a model whose expiry moved at this very check, never from GPU load alone", () => {
    const at = iso => ({ name: "m", expires: iso })
    const first = L.trackUsage(null, [at("2026-10-20T10:05:00+02:00")], 1000)
    const idle = L.trackUsage(first, [at("2026-10-20T10:05:00+02:00")], 1030)
    assert.equal(L.modelInUse(idle, "m", 1030), false)
    const used = L.trackUsage(idle, [at("2026-10-20T10:08:00+02:00")], 1060)
    assert.equal(L.modelInUse(used, "m", 1060), true)
    assert.equal(L.modelInUse(used, "m", 1090), false)
    assert.equal(L.modelInUse(used, "other", 1060), false)
    assert.equal(L.modelInUse(null, "m", 1060), false)
})

test("isLocalHost: gpu.sh only describes this computer's GPU", () => {
    for (const url of ["http://localhost:11434", "localhost:11434", "http://127.0.0.1:11434/", "https://user@127.0.0.2", "http://[::1]:11434", "HTTP://LOCALHOST"]) {
        assert.equal(L.isLocalHost(url), true, url)
    }
    for (const url of ["http://192.168.1.5:11434", "http://mac.local:11434", "http://localhost.example.com", "http://127.0.0.1.evil.net", "", undefined]) {
        assert.equal(L.isLocalHost(url), false, String(url))
    }
})

test("trackUsage: a failed /api/ps (models null) keeps what was tracked", () => {
    const used = L.trackUsage(L.trackUsage(null, [{ name: "m", expires: "2026-10-20T10:05:00+02:00" }], 1000),
                              [{ name: "m", expires: "2026-10-20T10:08:00+02:00" }], 1060)
    assert.equal(L.trackUsage(used, null, 1090), used)
    assert.deepEqual(L.trackUsage(null, null, 1090), { expires: {}, used: {} })
})

test("parseGpu: any bracketed value is unknown", () => {
    const gtx = L.parseGpu("37, 2471, 12227, 39, [Not Supported], [Not Supported], NVIDIA GeForce GTX 1060")
    assert.deepEqual([gtx.util, gtx.temp_c, gtx.power_w, gtx.power_limit_w, gtx.name, gtx.mem_total_gb],
                     [37, 39, null, null, "NVIDIA GeForce GTX 1060", 11.9])
    const odd = L.parseGpu("5, 100, 200, [Unknown Error], [Insufficient Permissions], [N/A], Card")
    assert.deepEqual([odd.temp_c, odd.power_w, odd.power_limit_w, odd.name], [null, null, null, "Card"])
})

test("parseGpu: unknown memory (unified-memory boards) keeps the GPU", () => {
    const gpu = L.parseGpu("42, [N/A], [N/A], 50, 10, 60, Jetson")
    assert.deepEqual([gpu.util, gpu.mem_used_gb, gpu.mem_total_gb, gpu.temp_c, gpu.name], [42, null, null, 50, "Jetson"])
    const half = L.parseGpu("42, [Not Supported], 8192, Old GPU")
    assert.deepEqual([half.mem_used_gb, half.mem_total_gb, half.name], [null, 8, "Old GPU"])
})

test("model details: parameters, quantization, capabilities, context", () => {
    const [loaded] = L.fromOllama(version, ps, tags, null, "").ollama.models
    assert.deepEqual(L.modelDetails(loaded), ["8.2B", "Q4_K_M"])
    assert.deepEqual(L.modelDetails({ params: "12.2B", quant: "Q4_K_M", capabilities: ["completion", "vision", "tools"] }), ["12.2B", "Q4_K_M", "vision", "tools"])
    assert.deepEqual(L.modelDetails({ name: "dashboard model" }), [])
    assert.equal(L.shortCount(8192), "8k")
    assert.equal(L.shortCount(131072), "128k")
    assert.equal(L.shortCount(1048576), "1M")
    assert.equal(L.shortCount(512), "512")
    assert.equal(L.shortCount(0), "")
    assert.equal(L.shortCount(undefined), "")
})

test("ollamaVramGb: what Ollama's loaded models hold in GPU memory", () => {
    assert.equal(L.ollamaVramGb(L.fromOllama(version, ps, tags, null, "").ollama.models), 4.7)
    assert.equal(L.ollamaVramGb([{ size_vram: 5e9 }, { size_vram: 2.8e9 }]), 7.8)
    assert.equal(L.ollamaVramGb([{ vram_gb: 3.5 }, { vram_gb: 1.2 }]), 4.7)
    assert.equal(L.ollamaVramGb([]), null)
    assert.equal(L.ollamaVramGb(undefined), null)
})

test("parseGpu: temperature, power and the old format", () => {
    const gpu = L.parseGpu("37, 2471, 12227, 39, 28.50, 250.00, NVIDIA GeForce RTX 5070\n")
    assert.equal(gpu.temp_c, 39)
    assert.equal(gpu.power_w, 29)
    assert.equal(gpu.power_limit_w, 250)
    assert.equal(gpu.name, "NVIDIA GeForce RTX 5070")
    const na = L.parseGpu("1, 100, 200, [N/A], [N/A], [N/A], Odd, GPU")
    assert.deepEqual([na.temp_c, na.power_w, na.power_limit_w, na.name], [null, null, null, "Odd,GPU"])
    const amd = L.parseGpu("5, 1024, 8192, 51, , , AMD GPU")
    assert.deepEqual([amd.temp_c, amd.power_w, amd.name], [51, null, "AMD GPU"])
    const two = L.parseGpu("10, 1024, 8192, 40, 100, 200, A\n70, 2048, 8192, 60, 50, 150, B")
    assert.deepEqual([two.temp_c, two.power_w, two.power_limit_w, two.name], [60, 150, 350, "A + B"])
    assert.equal(L.TEMP_WARN, 85)
})

test("parseGpu: other programs' GPU memory, without Ollama's", () => {
    const text = "37, 8000, 12227, 39, 28, 250, GPU\n# apps\n101, /usr/bin/ollama, 6000\n102, /usr/lib/ollama/ollama_llama_server, 100\n"
        + "201, /usr/lib/firefox/firefox, 1024\n202, /usr/lib/firefox/firefox, 512\n203, /usr/bin/blender, 2048\n"
    assert.deepEqual(L.parseGpu(text).apps, [{ name: "blender", used_gb: 2 }, { name: "firefox", used_gb: 1.5 }])
    assert.deepEqual(L.parseGpu("37, 8000, 12227, 39, 28, 250, GPU\n# apps\n").apps, [])
})

test("trackUsage: a later expiry than last time means the model was used", () => {
    const at = iso => ({ name: "m", expires: iso })
    const first = L.trackUsage(null, [at("2026-10-20T10:05:00.123456789+02:00")], 1000)
    assert.deepEqual(first.used, {})
    const idle = L.trackUsage(first, [at("2026-10-20T10:05:00.123456789+02:00")], 1030)
    assert.deepEqual(idle.used, {})
    const used = L.trackUsage(idle, [at("2026-10-20T10:08:00+02:00")], 1060)
    assert.deepEqual(used.used, { m: 1060 })
    // Stays remembered while the expiry holds still, and is dropped when the model unloads.
    assert.deepEqual(L.trackUsage(used, [at("2026-10-20T10:08:00+02:00")], 1090).used, { m: 1060 })
    assert.deepEqual(L.trackUsage(used, [], 1090).used, {})
})

// LM Studio's /api/v1/models reply, trimmed from this machine (the Nomic model is on three devices over LM Link).
const lmModels = { models: [
    { type: "llm", key: "qwen2.5-coder-7b-instruct", size_bytes: 4683074048, params_string: "7B",
      quantization: { name: "Q4_K_M", bits_per_weight: 4 }, capabilities: { vision: false, trained_for_tool_use: false },
      loaded_instances: [{ id: "qwen2.5-coder-7b-instruct", config: { context_length: 8192 }, remaining_ttl_seconds: 3382 }] },
    { type: "embedding", key: "text-embedding-nomic-embed-text-v1.5", size_bytes: 84106624, params_string: null,
      quantization: { name: "Q4_K_M" }, loaded_instances: [] },
    { type: "llm", key: "qwen3-30b-a3b-arliai-rpr-v4-fast-mlx", size_bytes: 32456750575, params_string: "30B",
      quantization: { name: "8bit" }, capabilities: { vision: false, trained_for_tool_use: true }, loaded_instances: [] },
    { type: "embedding", key: "text-embedding-nomic-embed-text-v1.5", size_bytes: 84106624, loaded_instances: [] },
] }

test("fromLmStudio: loaded instances, unload time and downloaded models listed once", () => {
    const now = 1793257000
    const block = L.fromLmStudio(lmModels, null, "", now)
    assert.equal(block.ollama, undefined)
    const servers = L.llmServers(block)
    assert.deepEqual(servers.map(s => [s.key, s.name, s.up]), [["lmstudio", "LM Studio", true]])
    const [m] = block.lmstudio.models
    assert.equal(m.name, "qwen2.5-coder-7b-instruct")
    assert.equal(m.size_gb, 4.7)
    assert.equal(m.context, 8192)
    assert.equal(L.parseTime(m.expires), now + 3382)
    assert.equal(L.gpuPercent(m), null)
    assert.equal(L.modelDetails(m).join(" · "), "7B · Q4_K_M")
    assert.deepEqual(block.lmstudio.installed.map(i => [i.name, i.capabilities]), [
        ["qwen2.5-coder-7b-instruct", []],
        ["qwen3-30b-a3b-arliai-rpr-v4-fast-mlx", ["tools"]],
        ["text-embedding-nomic-embed-text-v1.5", ["embedding"]],
    ])
    assert.equal(L.loadedCount(block), 1)
    assert.equal(L.llmState(block), "idle")
})

test("fromLmStudio: no reply or an unexpected one is down, with the reason", () => {
    const down = L.fromLmStudio(null, null, "Can't reach http://localhost:1234", 0)
    assert.equal(down.lmstudio.up, false)
    assert.equal(down.lmstudio.error, "Can't reach http://localhost:1234")
    assert.deepEqual(down.lmstudio.installed, [])
    assert.equal(L.llmState(down), "down")
    assert.equal(L.fromLmStudio({ error: "Unexpected endpoint" }, null, "", 0).lmstudio.up, false)
})

test("fromLmStudio: a request restarts the countdown, which trackUsage reads as used", () => {
    const first = L.fromLmStudio(lmModels, null, "", 1000)
    const usage = L.trackUsage(null, first.lmstudio.models, 1000)
    // 10 s later the TTL is back at its start: the model served a request.
    const second = L.fromLmStudio(lmModels, null, "", 1010)
    const after = L.trackUsage(usage, second.lmstudio.models, 1010)
    assert.equal(L.modelInUse(after, "qwen2.5-coder-7b-instruct", 1010), true)
    // Counting down as usual: not used.
    const idle = { models: [{ ...lmModels.models[0], loaded_instances: [{ id: "qwen2.5-coder-7b-instruct", remaining_ttl_seconds: 3372 }] }] }
    const still = L.trackUsage(usage, L.fromLmStudio(idle, null, "", 1010).lmstudio.models, 1010)
    assert.equal(L.modelInUse(still, "qwen2.5-coder-7b-instruct", 1010), false)
})

test("parseGpu: LM Studio's own engine isn't another program", () => {
    const gpu = L.parseGpu("3, 6000, 16376, 45, 30, 200, RTX\n# apps\n1670732, /home/jap/.lmstudio/extensions/backends/llama.cpp-linux-x86_64-nvidia-cuda12-avx2-2.41.0/llama-server, 4944\n3543, /usr/bin/warp-terminal, 234")
    assert.deepEqual(gpu.apps, [{ name: "warp-terminal", used_gb: 0.2 }])
})

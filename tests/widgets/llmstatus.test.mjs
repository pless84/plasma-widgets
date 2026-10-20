import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic } from "./logic.mjs"

const L = loadLogic("llmstatus")

// A Mac server dashboard's "llm" block.
function llm(extra = {}) {
    return {
        gpu: { util: 0, alloc_gb: 42.9 },
        memory: { free_pct: 54, swap_used_gb: 6, swap_total_gb: 24 },
        ollama: { up: true, version: "0.40.3", models: [{ name: "gemma" }], requests: [{ time: 10 }, { time: 30 }] },
        mlx: [{ label: "dk.pless.mlx-rpr", model: "Org/Qwen3-8Bit", up: true, footprint_gb: 39, requests: [] }],
        ...extra,
    }
}

// Ollama's own replies, as on this machine.
const version = { version: "0.34.1" }
const ps = { models: [{ name: "qwen3:8b", model: "qwen3:8b", size: 6200000000, size_vram: 4650000000, expires_at: "2026-10-20T10:05:00+02:00" }] }
const tags = { models: [{ name: "qwen3:8b", size: 5225388164 }, { name: "gemma3:12b", size: 8149190253 }] }

test("shortModel and lastRequestTime", () => {
    assert.equal(L.shortModel("Org/Qwen3-8Bit"), "Qwen3-8Bit")
    assert.equal(L.shortModel("plain"), "plain")
    assert.equal(L.shortModel(null), "")
    assert.equal(L.lastRequestTime([{ time: 10 }, { time: 30 }, { time: 20 }]), 30)
    assert.equal(L.lastRequestTime(undefined), 0)
})

test("llmServers lists Ollama then the MLX servers", () => {
    assert.deepEqual(L.llmServers(undefined), [])
    const servers = L.llmServers(llm())
    assert.deepEqual(servers.map(s => [s.key, s.name, s.up]), [["ollama", "Ollama", true], ["dk.pless.mlx-rpr", "Qwen3-8Bit", true]])
    assert.equal(servers[0].lastRequest, 30)
    assert.equal(servers[1].footprintGb, 39)
    assert.equal(L.llmServers(llm({ ollama: { error: "boom" } }))[0].up, false)
})

test("llmState: down beats busy beats idle", () => {
    assert.equal(L.llmState(undefined), "")
    assert.equal(L.llmState(llm()), "idle")
    assert.equal(L.llmState(llm({ gpu: { util: 85 } })), "busy")
    assert.equal(L.llmState(llm({ gpu: { util: 85 }, ollama: { up: false } })), "down")
    assert.equal(L.llmState(llm({ mlx: [{ label: "x", up: false }] })), "down")
    assert.equal(L.llmState(L.fromOllama(version, ps, tags, null, "")), "idle")
})

test("swapPercent", () => {
    assert.equal(L.swapPercent({ swap_used_gb: 6, swap_total_gb: 24 }), 25)
    assert.equal(L.swapPercent({ swap_used_gb: 0, swap_total_gb: 0 }), null)
    assert.equal(L.swapPercent(undefined), null)
})

test("llmChanges: servers going down, never on the first check", () => {
    const first = L.llmChanges(llm({ ollama: { up: false } }), null)
    assert.deepEqual(first.wentDown, [])
    assert.deepEqual(first.snapshot, { ollama: false, "dk.pless.mlx-rpr": true })
    const second = L.llmChanges(llm({ ollama: { up: false }, mlx: [{ label: "dk.pless.mlx-rpr", up: false }] }), first.snapshot)
    assert.deepEqual(second.wentDown.map(s => s.key), ["dk.pless.mlx-rpr"])
})

test("fromOllama: version, loaded and installed models", () => {
    const block = L.fromOllama(version, ps, tags, { util: 40 }, "")
    assert.equal(block.gpu.util, 40)
    assert.deepEqual(block.ollama.models, [{ name: "qwen3:8b", size_gb: 6.2, vram_gb: 4.7, expires: "2026-10-20T10:05:00+02:00" }])
    assert.deepEqual(block.ollama.installed.map(m => m.name), ["gemma3:12b", "qwen3:8b"])
    assert.equal(block.ollama.installed[0].size_gb, 8.1)
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

test("loadedCount: Ollama's loaded models plus running MLX servers", () => {
    assert.equal(L.loadedCount(null), 0)
    assert.equal(L.loadedCount(llm()), 2)
    assert.equal(L.loadedCount(llm({ mlx: [{ label: "x", up: false }] })), 1)
    assert.equal(L.loadedCount(L.fromOllama(version, ps, tags, null, "")), 1)
})

test("gpuPercent: how much of a model sits in GPU memory", () => {
    assert.equal(L.gpuPercent({ size_gb: 6.2, vram_gb: 6.2 }), 100)
    assert.equal(L.gpuPercent({ size_gb: 10, vram_gb: 4 }), 40)
    assert.equal(L.gpuPercent({ size_gb: 0, vram_gb: 0 }), null)
})

test("parseGpu: nvidia-smi and AMD lines; several GPUs count as one", () => {
    assert.deepEqual(L.parseGpu("2, 2471, 12227, NVIDIA GeForce RTX 5070\n"),
                     { util: 2, mem_used_gb: 2.4, mem_total_gb: 11.9, name: "NVIDIA GeForce RTX 5070" })
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

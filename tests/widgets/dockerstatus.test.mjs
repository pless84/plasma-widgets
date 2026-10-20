import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic } from "./logic.mjs"

const L = loadLogic("dockerstatus")
const ORDER = ["failed", "unhealthy", "restarting", "paused", "stopped", "running"]

test("classify", () => {
    const cases = [
        ["running", "Up 2 hours", "", "running"],
        ["running", "Up 2 hours (healthy)", "healthy", "running"],
        ["running", "Up 2 hours (unhealthy)", "", "unhealthy"],
        ["running", "Up 2 hours", "unhealthy", "unhealthy"],
        ["restarting", "Restarting (1) 5 seconds ago", "", "restarting"],
        ["paused", "Up 2 hours (Paused)", "", "paused"],
        ["dead", "Dead", "", "failed"],
        ["exited", "Exited (1) 3 minutes ago", "", "failed"],
        ["exited", "Exited (255) 3 minutes ago", "", "failed"],
        ["exited", "Exited (0) 3 minutes ago", "", "stopped"],     // finished normally
        ["exited", "Exited (130) 3 minutes ago", "", "stopped"],   // Ctrl+C
        ["exited", "Exited (137) 3 minutes ago", "", "stopped"],   // docker stop's SIGKILL
        ["exited", "Exited (143) 3 minutes ago", "", "stopped"],   // docker stop's SIGTERM
        ["created", "Created", "", "stopped"],
        ["removing", "Removal In Progress", "", "stopped"],
    ]
    for (const [State, Status, HealthStatus, expected] of cases) {
        assert.equal(L.classify({ State, Status, HealthStatus }), expected, `${State} / ${Status}`)
    }
})

test("label", () => {
    const labels = "com.docker.compose.project=shop,com.docker.compose.service=web,other=x"
    assert.equal(L.label(labels, "com.docker.compose.project"), "shop")
    assert.equal(L.label(labels, "com.docker.compose.service"), "web")
    assert.equal(L.label(labels, "missing"), "")
    assert.equal(L.label(undefined, "missing"), "")
    // The dots are literal, and the key must start a label.
    assert.equal(L.label("comXdockerXcompose.project=no", "com.docker.compose.project"), "")
    assert.equal(L.label("xcom.docker.compose.project=no", "com.docker.compose.project"), "")
})

test("shortPorts drops IPv6 duplicates and unpublished ports", () => {
    assert.equal(L.shortPorts("0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 0.0.0.0:5432->5432/tcp, 6379/tcp"),
        "8080→80, 5432→5432")
    assert.equal(L.shortPorts(""), "")
    assert.equal(L.shortPorts(undefined), "")
})

test("shortImage shortens image ids only", () => {
    assert.equal(L.shortImage("sha256:0123456789abcdef0123"), "0123456789ab")
    assert.equal(L.shortImage("nginx:1.27"), "nginx:1.27")
})

const ps = [
    { ID: "a1", Names: "shop-web-1", State: "running", Status: "Up 1 hour", Image: "nginx:1.27",
      Labels: "com.docker.compose.project=shop,com.docker.compose.service=web,com.docker.compose.project.working_dir=/srv/shop",
      Ports: "0.0.0.0:8080->80/tcp", RunningFor: "2 days ago", CreatedAt: "2026-10-09 07:57:56 +0200 CEST",
      Networks: "shop_default,edge", Mounts: "/srv/shop/src,shop_data", Size: "4.1kB (virtual 174MB)" },
    { ID: "a2", Names: "shop-db-1", State: "exited", Status: "Exited (1) 2 minutes ago", Image: "postgres:17",
      Labels: "com.docker.compose.project=shop,com.docker.compose.service=db", Ports: "" },
    { ID: "a3", Names: "shop-api-1", State: "running", Status: "Up 1 hour", Image: "api:1",
      Labels: "com.docker.compose.project=shop,com.docker.compose.service=api", Ports: "" },
    { ID: "b1", Names: "scratch", State: "exited", Status: "Exited (0) 1 day ago", Image: "sha256:0123456789abcdef",
      Labels: "", Ports: "" },
    { ID: "c1", Names: "api-app-1", State: "running", Status: "Up 3 days (unhealthy)", Image: "api:2",
      Labels: "com.docker.compose.project=api,com.docker.compose.service=app", Ports: "" },
].map(c => JSON.stringify(c)).join("\n") + "\n\n"

test("parseContainers reads fetch.sh's JSON lines", () => {
    const containers = L.parseContainers(ps)
    assert.equal(containers.length, 5)
    assert.deepEqual(containers[0], { id: "a1", name: "web", fullName: "shop-web-1", project: "shop", image: "nginx:1.27",
                                      imageRef: "nginx:1.27", stateKey: "running", status: "Up 1 hour", ports: "8080→80",
                                      workingDir: "/srv/shop", exitCode: null, age: "2 days ago", created: "2026-10-09 07:57",
                                      networks: ["shop_default", "edge"], mounts: ["/srv/shop/src", "shop_data"],
                                      writableSize: "4.1kB", why: null })
    assert.equal(containers[3].name, "scratch")       // no compose service: the container name
    assert.equal(containers[3].project, "")
    assert.equal(containers[3].image, "0123456789ab")
    assert.equal(containers[3].imageRef, "sha256:0123456789abcdef")
    assert.equal(L.parseContainers("").length, 0)
})

test("countStates", () => {
    assert.deepEqual(L.countStates(L.parseContainers(ps)), { running: 2, failed: 1, stopped: 1, unhealthy: 1 })
})

test("groupContainers: projects alphabetically, standalone last, worst first", () => {
    const groups = L.groupContainers(L.parseContainers(ps), ORDER)
    assert.deepEqual(groups.map(g => g.project), ["api", "shop", ""])
    // Worst state first, then by name: db (failed) before api and web (running).
    assert.deepEqual(groups[1].containers.map(c => c.name), ["db", "api", "web"])
})

test("freshProblems: only containers that newly failed or became unhealthy", () => {
    const containers = L.parseContainers(ps)
    const first = L.freshProblems(containers, null)
    assert.deepEqual(first.fresh, [])                  // never on the first check
    assert.deepEqual(first.states, { a1: "running", a2: "failed", a3: "running", b1: "stopped", c1: "unhealthy" })

    const again = L.freshProblems(containers, first.states)
    assert.deepEqual(again.fresh, [])                  // same problems as before

    const second = L.freshProblems(containers, { a1: "running", a2: "running", a3: "running", b1: "stopped", c1: "failed" })
    assert.deepEqual(second.fresh.map(c => c.id), ["a2", "c1"])   // c1: failed -> unhealthy is a change too
})

test("stackActions: start when any container is down, stop when any is up", () => {
    const stack = (...keys) => L.stackActions(keys.map(stateKey => ({ stateKey })))
    assert.deepEqual(stack("running", "unhealthy"), { start: false, stop: true })
    assert.deepEqual(stack("stopped", "failed"), { start: true, stop: false })
    assert.deepEqual(stack("running", "failed"), { start: true, stop: true })     // half up: both
    assert.deepEqual(stack("restarting"), { start: false, stop: true })
    assert.deepEqual(stack("paused"), { start: false, stop: false })            // unpause isn't offered
})

test("panelStates and visibleStates", () => {
    const states = ORDER.map(key => ({ key, inPanel: key !== "stopped" }))
    const counts = { failed: 1, stopped: 2, running: 3 }
    assert.deepEqual(L.visibleStates(states, counts).map(s => s.key), ["failed", "stopped", "running"])
    assert.deepEqual(L.panelStates(states, counts, false).map(s => s.key), ["failed", "running"])
    assert.deepEqual(L.panelStates(states, counts, true).map(s => s.key),
        ["failed", "unhealthy", "restarting", "paused", "running"])
})

test("shellQuote survives quotes", () => {
    assert.equal(L.shellQuote("it's"), "'it'\\''s'")
    assert.equal(L.shellQuote(""), "''")
})

// `docker image ls --no-trunc --format '{{json .}}'`, as images.sh prints it.
const imageLs = [
    { ID: "sha256:aaa111", Repository: "nginx", Tag: "1.27", Size: "192MB", CreatedSince: "2 weeks ago" },
    { ID: "sha256:bbb222", Repository: "postgres", Tag: "17", Size: "438MB", CreatedSince: "3 weeks ago" },
    { ID: "sha256:ccc333", Repository: "<none>", Tag: "<none>", Size: "88MB", CreatedSince: "5 days ago" },
    { ID: "sha256:ddd444", Repository: "api", Tag: "latest", Size: "120MB", CreatedSince: "1 day ago" },
    { ID: "sha256:0123456789abcdef", Repository: "<none>", Tag: "<none>", Size: "10MB", CreatedSince: "1 month ago" },
    { ID: "sha256:eee555", Repository: "ghcr.io/pless84/tool", Tag: "2", Size: "50MB", CreatedSince: "1 hour ago" },
].map(i => JSON.stringify(i)).join("\n") + "\n"

test("parseImages: tagged images by name, untagged ones last and deleted by id", () => {
    const images = L.parseImages(imageLs)
    assert.deepEqual(images.map(i => i.ref), ["api:latest", "ghcr.io/pless84/tool:2", "nginx:1.27", "postgres:17",
                                              "sha256:0123456789abcdef", "sha256:ccc333"])
    assert.deepEqual(images[2], { id: "sha256:aaa111", ref: "nginx:1.27", repository: "nginx", tag: "1.27", untagged: false,
                                  size: "192MB", created: "2 weeks ago" })
    assert.equal(images[5].untagged, true)
    assert.equal(images[5].repository, "")
    assert.deepEqual(L.parseImages(""), [])
})

test("imageUsers: matches a container's image by tag, implied latest, registry prefix or id", () => {
    const images = L.parseImages(imageLs)
    const byRef = ref => images.find(i => i.ref === ref)
    const containers = L.parseContainers(ps)
    assert.deepEqual(L.imageUsers(byRef("nginx:1.27"), containers).map(c => c.id), ["a1"])
    assert.deepEqual(L.imageUsers(byRef("postgres:17"), containers).map(c => c.id), ["a2"])  // stopped still counts
    assert.deepEqual(L.imageUsers(byRef("sha256:0123456789abcdef"), containers).map(c => c.id), ["b1"])
    assert.deepEqual(L.imageUsers(byRef("sha256:ccc333"), containers), [])
    // "api:1" and "api:2" are other tags than api:latest.
    assert.deepEqual(L.imageUsers(byRef("api:latest"), containers), [])
    const more = [
        { id: "x1", fullName: "x", image: "api", imageRef: "api" },
        { id: "x2", fullName: "y", image: "docker.io/library/nginx:1.27", imageRef: "docker.io/library/nginx:1.27" },
        { id: "x3", fullName: "z", image: "ghcr.io/pless84/tool:2", imageRef: "ghcr.io/pless84/tool:2" },
    ]
    assert.deepEqual(L.imageUsers(byRef("api:latest"), more).map(c => c.id), ["x1"])
    assert.deepEqual(L.imageUsers(byRef("nginx:1.27"), more).map(c => c.id), ["x2"])
    assert.deepEqual(L.imageUsers(byRef("ghcr.io/pless84/tool:2"), more).map(c => c.id), ["x3"])
})

test("exit codes and group folders", () => {
    assert.equal(L.exitCodeOf("Exited (137) 3 minutes ago"), 137)
    assert.equal(L.exitCodeOf("Up 2 hours"), null)
    const groups = L.groupContainers(L.parseContainers(ps), ORDER)
    assert.equal(groups.find(g => g.project === "shop").workingDir, "/srv/shop")
    assert.equal(groups.find(g => g.project === "api").workingDir, "")
    assert.equal(L.label("a=1,com.docker.compose.project.working_dir=/x y,b=2", "com.docker.compose.project.working_dir"), "/x y")
})

test("inspectIds: problem containers and 137 exits only", () => {
    const c = (id, stateKey, exitCode = null) => ({ id, stateKey, exitCode })
    assert.deepEqual(L.inspectIds([c("a", "running"), c("b", "failed", 1), c("c", "unhealthy"), c("d", "restarting"),
                                   c("e", "stopped", 137), c("f", "stopped", 0), c("g", "paused"), c("h", "running", null)]),
        ["b", "c", "d", "e"])
})

const inspect = [
    { id: "o1", restarts: 0, state: { OOMKilled: true, ExitCode: 137, Error: "" } },
    { id: "o2", restarts: 3, state: { OOMKilled: false, ExitCode: 1, Error: "cannot start\nnow" } },
    { id: "o3", restarts: 0, state: { Health: { Log: [{ Output: "old" }, { Output: "  curl: (7) refused\n  \n" }] } } },
    { id: "o4", restarts: 2, state: { OOMKilled: false, ExitCode: 137 } },
].map(o => JSON.stringify(o)).join("\n") + "\nnot json\n"

test("parseInspect", () => {
    const d = L.parseInspect(inspect)
    assert.deepEqual(d.o1, { oom: true, error: "", exitCode: 137, restarts: 0, health: "" })
    assert.deepEqual(d.o2, { oom: false, error: "cannot start now", exitCode: 1, restarts: 3, health: "" })
    assert.equal(d.o3.health, "curl: (7) refused")
    assert.equal(d.o3.exitCode, null)
    const long = L.parseInspect(JSON.stringify({ id: "x", state: { Health: { Log: [{ Output: "z".repeat(500) }] } } }))
    assert.equal(long.x.health.length, 200)
    assert.deepEqual(L.parseInspect(""), {})
})

test("mergeInspect: an OOM kill is failed, not stopped", () => {
    const c = (id, stateKey, exitCode = null) => ({ id, stateKey, exitCode, why: null })
    const merged = L.mergeInspect([c("o1", "stopped", 137), c("o2", "failed", 1), c("o3", "unhealthy"),
                                   c("o4", "stopped", 137), c("zz", "running")], L.parseInspect(inspect))
    assert.deepEqual(merged.map(m => m.stateKey), ["failed", "failed", "unhealthy", "stopped", "running"])
    assert.equal(merged[0].why.oom, true)
    assert.equal(merged[2].why.health, "curl: (7) refused")
    assert.equal(merged[2].exitCode, null)
    assert.equal(merged[4].why, null)
    // The input isn't changed.
    assert.equal(L.mergeInspect([c("o1", "stopped", 137)], L.parseInspect(inspect))[0].stateKey, "failed")
    // Merging makes the OOM kill a fresh problem.
    const before = L.freshProblems([c("o1", "stopped", 137)], null).states
    assert.deepEqual(L.freshProblems(merged, before).fresh.map(m => m.id), ["o1", "o2", "o3"])
})

test("formatSize", () => {
    assert.equal(L.formatSize("11.54GB"), "11.5 GB")
    assert.equal(L.formatSize("10.04GB"), "10 GB")
    assert.equal(L.formatSize("632.9MB (83%)"), "633 MB")
    assert.equal(L.formatSize("7.131GB (80%)"), "7.1 GB")
    assert.equal(L.formatSize("4.1kB"), "4.1 kB")
    assert.equal(L.formatSize("0B"), "0 B")
    assert.equal(L.formatSize(""), "")
})

test("diskSummary", () => {
    const df = [
        { Active: "3", Reclaimable: "7.131GB (80%)", Size: "8.866GB", TotalCount: "4", Type: "Images" },
        { Active: "4", Reclaimable: "0B (0%)", Size: "5.018MB", TotalCount: "4", Type: "Containers" },
        { Active: "2", Reclaimable: "632.9MB (83%)", Size: "758.2MB", TotalCount: "9", Type: "Local Volumes" },
        { Active: "0", Reclaimable: "10.04GB", Size: "11.54GB", TotalCount: "384", Type: "Build Cache" },
    ].map(r => JSON.stringify(r)).join("\n") + "\n"
    assert.deepEqual(L.diskSummary(df), [
        { key: "buildCache", size: "11.5 GB", reclaimable: "10 GB" },
        { key: "images", size: "8.9 GB", reclaimable: "7.1 GB" },
        { key: "volumes", size: "758 MB", reclaimable: "633 MB" },
    ])
    const clean = [
        { Reclaimable: "0B (0%)", Size: "1GB", Type: "Images" },
        { Reclaimable: "0B", Size: "0B", Type: "Build Cache" },
    ].map(r => JSON.stringify(r)).join("\n")
    assert.deepEqual(L.diskSummary(clean), [])
    assert.deepEqual(L.diskSummary(""), [])
})

test("mergeInspect carries the previous details forward when inspect gives none", () => {
    const c = (id, stateKey, exitCode = null) => ({ id, stateKey, exitCode, why: null })
    const shown = L.mergeInspect([c("o1", "stopped", 137)], L.parseInspect(inspect), [])
    assert.equal(shown[0].stateKey, "failed")
    // The next inspect fails: still failed with the same details, so it is not a fresh problem again.
    const again = L.mergeInspect([c("o1", "stopped", 137)], {}, shown)
    assert.equal(again[0].stateKey, "failed")
    assert.equal(again[0].why.oom, true)
    assert.deepEqual(L.freshProblems(again, L.freshProblems(shown, null).states).fresh, [])
    // Another container, or one that no longer needs inspecting, gets nothing carried over.
    assert.equal(L.mergeInspect([c("other", "stopped", 137)], {}, shown)[0].why, null)
    assert.equal(L.mergeInspect([c("o1", "running")], {}, shown)[0].why, null)
})

test("fileUrl escapes # and ?", () => {
    assert.equal(L.fileUrl("/home/jap/my stack/a#b?c"), "file:///home/jap/my%20stack/a%23b%3Fc")
})

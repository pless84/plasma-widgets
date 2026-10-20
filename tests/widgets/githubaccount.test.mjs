import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLogic, isoAgo } from "./logic.mjs"

const L = loadLogic("githubaccount")

const pr = (number, rollup, draft = false) => ({
    title: `PR ${number}`, url: `https://github.com/o/r/pull/${number}`, number, isDraft: draft,
    repository: { nameWithOwner: "o/r" },
    commits: { nodes: rollup === undefined ? [] : [{ commit: { statusCheckRollup: rollup && { state: rollup } } }] },
})

const fetched = {
    notifications: [{ id: "1", unread: true }, { id: "2", unread: false }],
    graphql: { data: {
        viewer: {
            login: "octo",
            pullRequests: { totalCount: 25, nodes: [pr(1, "FAILURE"), pr(2, "PENDING", true), pr(3, null), pr(4)] },
            repositories: { nodes: [
                { nameWithOwner: "o/r", url: "https://github.com/o/r", pushedAt: "2026-10-01T00:00:00Z",
                  defaultBranchRef: { target: { statusCheckRollup: { state: "SUCCESS" } } } },
                { nameWithOwner: "o/empty", url: "https://github.com/o/empty", pushedAt: "2026-10-01T00:00:00Z",
                  defaultBranchRef: null },
            ] },
        },
        reviews: { issueCount: 3, nodes: [{ title: "Review me", url: "https://github.com/o/r/pull/9" }, {}] },
    } },
}

test("parse", () => {
    const p = L.parse(fetched)
    assert.equal(p.login, "octo")
    assert.equal(p.prCount, 25)                         // GitHub's total, not the 4 listed
    assert.equal(p.reviewCount, 3)
    assert.equal(p.reviews.length, 1)                   // entries without a URL are skipped
    assert.deepEqual(p.pullRequests.map(x => x.ci), ["FAILURE", "PENDING", null, null])
    assert.deepEqual(p.pullRequests[1], { title: "PR 2", url: "https://github.com/o/r/pull/2", number: 2, isDraft: true,
                                          repo: "o/r", ci: "PENDING", reviewDecision: null, mergeState: null,
                                          checks: { failed: [], done: 0, total: 0 } })
    assert.equal(p.pullRequests[2].checks, null)
    assert.deepEqual(p.releases, {})
    assert.deepEqual(p.repos.map(r => [r.name, r.ci]), [["o/r", "SUCCESS"], ["o/empty", null]])
})

test("ciCategory and ciCounts", () => {
    assert.equal(L.ciCategory("SUCCESS"), "passing")
    assert.equal(L.ciCategory("FAILURE"), "failing")
    assert.equal(L.ciCategory("ERROR"), "failing")
    assert.equal(L.ciCategory("PENDING"), "running")
    assert.equal(L.ciCategory("EXPECTED"), "running")
    assert.equal(L.ciCategory(null), "")
    const p = L.parse(fetched)
    assert.deepEqual(L.ciCounts(p.pullRequests, p.repos), { failing: 1, running: 1, passing: 1 })
})

test("notificationUrl", () => {
    const n = (type, url) => ({ subject: { type, url }, repository: { html_url: "https://github.com/o/r" } })
    assert.equal(L.notificationUrl(n("PullRequest", "https://api.github.com/repos/o/r/pulls/7")), "https://github.com/o/r/pull/7")
    assert.equal(L.notificationUrl(n("Issue", "https://api.github.com/repos/o/r/issues/3")), "https://github.com/o/r/issues/3")
    assert.equal(L.notificationUrl(n("Commit", "https://api.github.com/repos/o/r/commits/abc")), "https://github.com/o/r/commit/abc")
    assert.equal(L.notificationUrl(n("Release", "https://api.github.com/repos/o/r/releases/1")), "https://github.com/o/r/releases")
    assert.equal(L.notificationUrl(n("CheckSuite", null)), "https://github.com/notifications")
})

test("freshNotifications: unread ones not seen before", () => {
    const first = L.freshNotifications(fetched.notifications, null)
    assert.deepEqual(first.fresh, [])
    assert.deepEqual(first.seen, { 1: true, 2: true })
    const later = [{ id: "1", unread: true }, { id: "2", unread: true }, { id: "3", unread: true }, { id: "4", unread: false }]
    const second = L.freshNotifications(later, first.seen)
    assert.deepEqual(second.fresh.map(n => n.id), ["3"])
    assert.deepEqual(Object.keys(second.seen).sort(), ["1", "2", "3", "4"])   // read ones too
})

test("age", () => {
    const now = Date.parse("2026-10-09T12:00:00Z")
    assert.deepEqual(L.age(isoAgo(now, 0), now), { unit: "minute", count: 1 })
    assert.deepEqual(L.age(isoAgo(now, 90), now), { unit: "hour", count: 2 })
    assert.deepEqual(L.age(isoAgo(now, 36 * 60), now), { unit: "day", count: 2 })
})

const rollup = (state, counts, nodes) => ({ state, contexts: {
    checkRunCountsByState: counts, statusContextCountsByState: [], nodes } })
const failingRollup = rollup("FAILURE", [{ state: "SUCCESS", count: 4 }, { state: "FAILURE", count: 2 }, { state: "IN_PROGRESS", count: 1 }], [
    { name: "build", conclusion: "FAILURE", detailsUrl: "https://ci/build" },
    { name: "lint", conclusion: "SUCCESS", detailsUrl: "https://ci/lint" },
    { context: "legacy/ci", state: "ERROR", targetUrl: "https://ci/legacy" },
    { name: "e2e", conclusion: "TIMED_OUT" },
])

test("parseChecks", () => {
    assert.equal(L.parseChecks(null), null)
    assert.deepEqual(L.parseChecks({ state: "SUCCESS" }), { failed: [], done: 0, total: 0 })
    assert.deepEqual(L.parseChecks(failingRollup), {
        failed: [{ name: "build", url: "https://ci/build" }, { name: "legacy/ci", url: "https://ci/legacy" }, { name: "e2e", url: "" }],
        done: 6, total: 7,
    })
})

test("checkSummary and rowUrl", () => {
    const item = { ci: "FAILURE", checks: L.parseChecks(failingRollup) }
    assert.deepEqual(L.checkSummary(item, 2), { kind: "failed", names: ["build", "legacy/ci"], more: 1 })
    assert.equal(L.rowUrl(item, "https://pr"), "https://ci/build")
    const running = { ci: "PENDING", checks: { failed: [], done: 5, total: 7 } }
    assert.deepEqual(L.checkSummary(running, 3), { kind: "running", done: 5, total: 7 })
    assert.equal(L.rowUrl(running, "https://pr"), "https://pr")
    assert.equal(L.checkSummary({ ci: "SUCCESS", checks: { failed: [], done: 1, total: 1 } }, 3), null)
    assert.equal(L.checkSummary({ ci: "FAILURE", checks: null }, 3), null)
    assert.equal(L.rowUrl({ ci: "FAILURE", checks: { failed: [{ name: "x", url: "" }] } }, "https://pr"), "https://pr")
})

test("prStatus and prCounts", () => {
    const s = (reviewDecision, mergeState, isDraft = false) => L.prStatus({ reviewDecision, mergeState, isDraft })
    assert.deepEqual(s("CHANGES_REQUESTED", "DIRTY"), ["changesRequested", "conflicts"])
    assert.deepEqual(s("APPROVED", "CLEAN"), ["approved", "ready"])
    assert.deepEqual(s(null, "BEHIND"), ["behind"])
    assert.deepEqual(s("REVIEW_REQUIRED", "BLOCKED"), ["reviewRequired"])
    assert.deepEqual(s(null, "UNSTABLE"), ["unstable"])
    assert.deepEqual(s(null, "BLOCKED", true), [])        // drafts are always BLOCKED
    assert.deepEqual(s(null, "CLEAN", true), [])
    assert.deepEqual(s(null, "UNKNOWN"), [])
    assert.deepEqual(L.prCounts([
        { reviewDecision: "CHANGES_REQUESTED", mergeState: "DIRTY" }, { reviewDecision: null, mergeState: "DIRTY" },
        { reviewDecision: "CHANGES_REQUESTED", mergeState: "CLEAN" }, { reviewDecision: "APPROVED", mergeState: "CLEAN" },
        { reviewDecision: null, mergeState: "DIRTY", isDraft: true },
    ]), { changesRequested: 2, conflicts: 2, needsAction: 3 })
})

test("recentRepos", () => {
    const now = Date.parse("2026-10-20T00:00:00Z")
    const repos = [{ name: "new", pushedAt: isoAgo(now, 60 * 24 * 3) }, { name: "edge", pushedAt: isoAgo(now, 60 * 24 * 14) },
                   { name: "old", pushedAt: isoAgo(now, 60 * 24 * 15) }]
    assert.deepEqual(L.recentRepos(repos, 14, now).map(r => r.name), ["new", "edge"])
    assert.deepEqual(L.recentRepos(repos, 30, now).map(r => r.name), ["new", "edge", "old"])
})

test("countText", () => {
    assert.equal(L.countText(12, L.notificationLimit), "12")
    assert.equal(L.countText(50, 50), "50+")
})

test("notificationUrl opens the specific release when known", () => {
    const n = { subject: { type: "Release", url: "https://api.github.com/repos/o/r/releases/12" }, repository: { html_url: "https://github.com/o/r" } }
    assert.equal(L.notificationUrl(n, { "https://api.github.com/repos/o/r/releases/12": "https://github.com/o/r/releases/tag/v1" }),
                 "https://github.com/o/r/releases/tag/v1")
    assert.equal(L.notificationUrl(n, {}), "https://github.com/o/r/releases")
    assert.equal(L.notificationUrl(n), "https://github.com/o/r/releases")
})

test("ciChanges", () => {
    const item = (n, ci) => ({ title: `PR ${n}`, url: `https://github.com/o/r/pull/${n}`, number: n, repo: "o/r", ci,
                               checks: ci === "FAILURE" ? { failed: [{ name: "build", url: "https://ci/build" }], done: 1, total: 1 } : null })
    const repo = (ci) => ({ name: "o/r", url: "https://github.com/o/r", ci, checks: null })
    // First check: remember, never notify.
    const first = L.ciChanges(null, [item(1, "FAILURE")], [repo("SUCCESS")])
    assert.deepEqual(first.events, [])
    assert.deepEqual(first.snapshot, { "pr:https://github.com/o/r/pull/1": "failing", "repo:o/r": "passing" })
    // Running -> failing and failing -> passing; a new PR and unchanged ones are quiet.
    const prev = { "pr:https://github.com/o/r/pull/1": "running", "pr:https://github.com/o/r/pull/2": "failing",
                   "pr:https://github.com/o/r/pull/3": "passing", "repo:o/r": "passing" }
    const next = L.ciChanges(prev, [item(1, "FAILURE"), item(2, "SUCCESS"), item(3, "SUCCESS"), item(4, "FAILURE")], [repo("FAILURE")])
    assert.deepEqual(next.events.map(e => [e.kind, e.title]), [["failing", "PR 1"], ["fixed", "PR 2"], ["failing", "o/r"]])
    assert.equal(next.events[0].url, "https://ci/build")
    assert.equal(next.events[1].url, "https://github.com/o/r/pull/2")
    assert.equal(next.events[2].url, "https://github.com/o/r/actions")
    // Failing -> running is not worth a notification.
    assert.deepEqual(L.ciChanges(prev, [item(2, "PENDING")], []).events, [])
})

test("ciChanges reports a fix that passes through running, once", () => {
    const pr = (ci) => [{ title: "PR 1", url: "https://github.com/o/r/pull/1", number: 1, repo: "o/r", ci, checks: null }]
    let snap = L.ciChanges(null, pr("FAILURE"), []).snapshot
    const running = L.ciChanges(snap, pr("PENDING"), [])
    assert.deepEqual(running.events, [])
    assert.equal(running.snapshot["pr:https://github.com/o/r/pull/1"], "failing")
    const passing = L.ciChanges(running.snapshot, pr("SUCCESS"), [])
    assert.deepEqual(passing.events.map(e => e.kind), ["fixed"])
    assert.deepEqual(L.ciChanges(passing.snapshot, pr("SUCCESS"), []).events, [])
})

test("ciChanges: failing -> running -> failing does not notify again", () => {
    const pr = (ci) => [{ title: "PR 1", url: "https://github.com/o/r/pull/1", number: 1, repo: "o/r", ci, checks: null }]
    const snap = L.ciChanges(null, pr("FAILURE"), []).snapshot
    const running = L.ciChanges(snap, pr("PENDING"), [])
    assert.deepEqual(L.ciChanges(running.snapshot, pr("FAILURE"), []).events, [])
})

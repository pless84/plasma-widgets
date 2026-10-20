.pragma library
// The GitHub Account widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/githubaccount.test.mjs). main.qml imports it as Logic.

function shellQuote(s) {
    return "'" + s.replace(/'/g, "'\\''") + "'"
}

// A statusCheckRollup state -> "failing" | "running" | "passing", or "" for none.
function ciCategory(state) {
    switch (state) {
    case "SUCCESS": return "passing"
    case "FAILURE":
    case "ERROR": return "failing"
    case "PENDING":
    case "EXPECTED": return "running"
    default: return ""
    }
}

// CI of your open PRs plus the default branch of your recently pushed repos -> {failing, running, passing}
function ciCounts(pullRequests, repos) {
    const counts = { failing: 0, running: 0, passing: 0 }
    pullRequests.map(pr => pr.ci).concat(repos.map(r => r.ci)).forEach(state => {
        const category = ciCategory(state)
        if (category) counts[category]++
    })
    return counts
}

// Notifications fetched per check (fetch.sh asks for the same number); a full page means there may be more.
var notificationLimit = 50

// A count as shown on a badge: "50+" when it fills the page it was counted from.
function countText(count, limit) {
    return count >= limit ? limit + "+" : String(count)
}

// Check run conclusions and status context states that count as a failure.
var failedStates = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "CANCELLED", "ACTION_REQUIRED", "ERROR"]
// Check states that mean "not finished yet".
var unfinishedStates = ["QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED", "EXPECTED"]

// A statusCheckRollup -> {failed: [{name, url}], done, total}, or null without one.
// Failed names come from the first 20 checks; the done/total counts cover all of them.
function parseChecks(rollup) {
    if (!rollup) return null
    const contexts = rollup.contexts || {}
    let total = 0
    let unfinished = 0
    ;(contexts.checkRunCountsByState || []).concat(contexts.statusContextCountsByState || []).forEach(c => {
        total += c.count
        if (unfinishedStates.includes(c.state)) unfinished += c.count
    })
    const failed = (contexts.nodes || []).filter(n => n && failedStates.includes(n.conclusion || n.state)).map(n => ({
        name: n.name || n.context,
        url: n.detailsUrl || n.targetUrl || ""
    }))
    return { failed: failed, done: total - unfinished, total: total }
}

// fetch.sh's {notifications, graphql} -> what the widget shows
function parse(data) {
    const gql = data.graphql.data
    const rollupOf = commit => commit && commit.statusCheckRollup ? commit.statusCheckRollup : null
    return {
        login: gql.viewer.login,
        notifications: data.notifications,
        // Release page URLs by the notifications' API URLs
        releases: data.releases || {},
        reviews: gql.reviews.nodes.filter(pr => pr.url),
        // Totals from GitHub, not capped at the 20 items the lists show.
        reviewCount: gql.reviews.issueCount,
        prCount: gql.viewer.pullRequests.totalCount,
        pullRequests: gql.viewer.pullRequests.nodes.map(pr => {
            const rollup = rollupOf(pr.commits.nodes.length ? pr.commits.nodes[0].commit : null)
            return {
                title: pr.title,
                url: pr.url,
                number: pr.number,
                isDraft: pr.isDraft,
                repo: pr.repository.nameWithOwner,
                reviewDecision: pr.reviewDecision || null,
                mergeState: pr.mergeStateStatus || null,
                ci: rollup ? rollup.state : null,
                checks: parseChecks(rollup)
            }
        }),
        repos: gql.viewer.repositories.nodes.map(r => {
            const rollup = rollupOf(r.defaultBranchRef ? r.defaultBranchRef.target : null)
            return {
                name: r.nameWithOwner,
                url: r.url,
                pushedAt: r.pushedAt,
                ci: rollup ? rollup.state : null,
                checks: parseChecks(rollup)
            }
        }),
    }
}

// The repos pushed within the last `days` days; older ones keep an old (stale) CI result.
function recentRepos(repos, days, now) {
    return repos.filter(r => now - new Date(r.pushedAt).getTime() <= days * 86400000)
}

// What to say about a PR's or repo's CI: {kind: "failed", names, more} naming up to maxNames failing checks,
// {kind: "running", done, total}, or null when there is nothing more to say than the state.
function checkSummary(item, maxNames) {
    const category = ciCategory(item.ci)
    const checks = item.checks
    if (!checks) return null
    if (category === "failing" && checks.failed.length > 0) {
        return { kind: "failed", names: checks.failed.slice(0, maxNames).map(f => f.name),
                 more: Math.max(checks.failed.length - maxNames, 0) }
    }
    if (category === "running" && checks.total > 0) {
        return { kind: "running", done: checks.done, total: checks.total }
    }
    return null
}

// Where clicking a PR or repo row goes: the first failing check, else the item's own page.
function rowUrl(item, fallback) {
    const failing = ciCategory(item.ci) === "failing" && item.checks
        ? item.checks.failed.find(f => f.url) : null
    return failing ? failing.url : fallback
}

// The review and merge state of one of your own PRs as keys the UI turns into words:
// "changesRequested" | "approved" | "reviewRequired", then "conflicts" | "behind" | "unstable" | "ready".
// Drafts (always BLOCKED), BLOCKED and UNKNOWN say nothing about the merge.
function prStatus(pr) {
    const keys = []
    switch (pr.reviewDecision) {
    case "CHANGES_REQUESTED": keys.push("changesRequested"); break
    case "APPROVED": keys.push("approved"); break
    case "REVIEW_REQUIRED": keys.push("reviewRequired"); break
    }
    if (!pr.isDraft) {
        switch (pr.mergeState) {
        case "DIRTY": keys.push("conflicts"); break
        case "BEHIND": keys.push("behind"); break
        case "UNSTABLE": keys.push("unstable"); break
        case "CLEAN": keys.push("ready"); break
        }
    }
    return keys
}

// How many of your PRs have changes requested, have merge conflicts, or either (needs your action).
function prCounts(pullRequests) {
    const keys = pullRequests.map(prStatus)
    const changesRequested = keys.filter(k => k.includes("changesRequested")).length
    const conflicts = keys.filter(k => k.includes("conflicts")).length
    const needsAction = keys.filter(k => k.includes("changesRequested") || k.includes("conflicts")).length
    return { changesRequested: changesRequested, conflicts: conflicts, needsAction: needsAction }
}

// The last settled (failing or passing) CI category of every PR and repo by a key, to compare with the next check.
// A "running" or unknown result keeps the previous value, so a fix going failing -> running -> passing is still seen.
function ciSnapshot(previous, pullRequests, repos) {
    const snapshot = {}
    const settle = (key, item) => {
        const now = ciCategory(item.ci)
        const settled = now === "failing" || now === "passing"
        snapshot[key] = settled ? now : (previous && previous[key]) || ""
    }
    pullRequests.forEach(pr => settle("pr:" + pr.url, pr))
    repos.forEach(r => settle("repo:" + r.name, r))
    return snapshot
}

// CI changes since the previous snapshot: {events: [{kind: "failing" | "fixed", title, subtitle, url}], snapshot}.
// "failing" is anything that wasn't failing and now is; "fixed" is failing and now passing.
// Compared against the last settled state, so failing -> running -> passing reports "fixed" once, and
// failing -> running -> failing reports nothing more (it never stopped failing as far as the user is told).
// Items missing from the previous snapshot are new, not changed. No events on the first check (previous null).
function ciChanges(previous, pullRequests, repos) {
    const events = []
    const check = (key, item, title, subtitle, fallbackUrl) => {
        if (!previous || !(key in previous)) return
        const was = previous[key]
        const now = ciCategory(item.ci)
        if (now === "failing" && was !== "failing") {
            events.push({ kind: "failing", title: title, subtitle: subtitle, url: rowUrl(item, fallbackUrl) })
        } else if (was === "failing" && now === "passing") {
            events.push({ kind: "fixed", title: title, subtitle: subtitle, url: fallbackUrl })
        }
    }
    pullRequests.forEach(pr => check("pr:" + pr.url, pr, pr.title, pr.repo + " #" + pr.number, pr.url))
    repos.forEach(r => check("repo:" + r.name, r, r.name, r.name, r.url + "/actions"))
    return { events: events, snapshot: ciSnapshot(previous, pullRequests, repos) }
}

// The github.com page for a notification (the API gives api.github.com URLs).
// releases (optional) maps release API URLs to their release pages; without a match the releases list opens.
function notificationUrl(n, releases) {
    if (n.subject.type === "Release") {
        return releases && releases[n.subject.url] || n.repository.html_url + "/releases"
    }
    if (!n.subject.url) {
        return "https://github.com/notifications"
    }
    return n.subject.url
        .replace("https://api.github.com/repos/", "https://github.com/")
        .replace("/pulls/", "/pull/")
        .replace("/commits/", "/commit/")
}

// Unread notifications not seen at the last check, and the ids to remember (read ones too, so
// one that's marked unread again doesn't pop up). Nothing is fresh on the first check (seenIds null).
function freshNotifications(notifications, seenIds) {
    const fresh = notifications.filter(n => n.unread && seenIds && !seenIds[n.id])
    const seen = {}
    notifications.forEach(n => seen[n.id] = true)
    return { fresh: fresh, seen: seen }
}

// How long ago an ISO time was, as {unit: "minute" | "hour" | "day", count}, for i18np.
function age(iso, now) {
    const minutes = Math.round((now - new Date(iso).getTime()) / 60000)
    if (minutes < 60) return { unit: "minute", count: Math.max(minutes, 1) }
    const hours = Math.round(minutes / 60)
    if (hours < 24) return { unit: "hour", count: hours }
    return { unit: "day", count: Math.round(hours / 24) }
}

// The collapsed groups list with key added, or removed if it was there
function toggled(list, key) {
    return list.includes(key) ? list.filter(k => k !== key) : list.concat([key])
}

// Which shared look colour role (see look.js) each colour setting follows when the widget
// uses the shared look.
var colorRoles = {
    colorReviews: "info",
    colorNotifications: "neutral",
    colorPullRequests: "ok",
    colorCiFailing: "error",
    colorCiRunning: "active",
    colorCiPassing: "ok",
    colorCountBackground: "countBackground"
}

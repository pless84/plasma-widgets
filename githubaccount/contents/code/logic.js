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

// fetch.sh's {notifications, graphql} -> what the widget shows
function parse(data) {
    const gql = data.graphql.data
    return {
        login: gql.viewer.login,
        notifications: data.notifications,
        reviews: gql.reviews.nodes.filter(pr => pr.url),
        // Totals from GitHub, not capped at the 20 items the lists show.
        reviewCount: gql.reviews.issueCount,
        prCount: gql.viewer.pullRequests.totalCount,
        pullRequests: gql.viewer.pullRequests.nodes.map(pr => ({
            title: pr.title,
            url: pr.url,
            number: pr.number,
            isDraft: pr.isDraft,
            repo: pr.repository.nameWithOwner,
            ci: pr.commits.nodes.length && pr.commits.nodes[0].commit.statusCheckRollup
                ? pr.commits.nodes[0].commit.statusCheckRollup.state : null
        })),
        repos: gql.viewer.repositories.nodes.map(r => ({
            name: r.nameWithOwner,
            url: r.url,
            pushedAt: r.pushedAt,
            ci: r.defaultBranchRef && r.defaultBranchRef.target.statusCheckRollup
                ? r.defaultBranchRef.target.statusCheckRollup.state : null
        })),
    }
}

// The github.com page for a notification (the API gives api.github.com URLs).
function notificationUrl(n) {
    if (n.subject.type === "Release") {
        return n.repository.html_url + "/releases"
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

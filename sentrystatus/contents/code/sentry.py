#!/usr/bin/env python3
"""Talks to Sentry's web API for the Sentry Status widget.

Usage:
  sentry.py fetch <server-url> <organization> [max-pages] [--errors-only] [--category-errors]
                  [--regressed] [--environment <name>]
      Prints {"issues": [...], "counts": {...}, "truncated": bool} as JSON: the organization's
      unresolved issues (most recently seen first, 100 per page) and how many issues are new
      (first seen in the last 24 hours), unresolved, archived and resolved. Counts cover issues
      seen in the last 90 days, Sentry's usual retention. Each issue carries its substatus
      (regressed, escalating, new, ongoing), unhandled flag, assignee name and its events in the
      last 24 hours (null without stats).
      --errors-only      only issues of level error or fatal (in the list and the counts)
      --category-errors  only issues of the error category (no performance or other issues)
      --regressed        also count the unresolved issues that regressed ("regressed" in counts)
      --environment      only events from this environment
  sentry.py <resolve|archive> <server-url> <organization> <issue-id>
      Changes one issue.

The auth token is read from the keyring, where the widget's settings page stores it
(secret-tool attributes: service plasma-sentry, server <server-url>). It is sent in the
Authorization header, so it never appears on a command line.
"""
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ISSUE_FIELDS = ("id", "shortId", "title", "culprit", "level", "firstSeen", "lastSeen", "count", "userCount",
                "permalink", "substatus", "priority", "isUnhandled")
PERIOD = "90d"
STATUS_FOR_ACTION = {"resolve": {"status": "resolved"}, "archive": {"status": "ignored"}}


def fail(message, code):
    print(message, file=sys.stderr)
    sys.exit(code)


def token_for(server):
    result = subprocess.run(["secret-tool", "lookup", "service", "plasma-sentry", "server", server],
                            capture_output=True, text=True)
    token = result.stdout.strip()
    if not token:
        fail(f"No auth token in the keyring for {server}", 3)
    return token


class BadRequest(Exception):
    """HTTP 400, which older self-hosted Sentry answers to search terms it does not know."""


def request(server, token, path_or_url, method="GET", body=None, raise_400=False):
    """Returns (parsed JSON, response headers). With raise_400, an HTTP 400 raises BadRequest."""
    url = path_or_url if path_or_url.startswith("http") else server + path_or_url
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()   # a bulk change can answer 204 with no body
            return (json.loads(raw) if raw else None), response.headers
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            fail(f"Sentry rejected the auth token ({e.code}). Check the token stored in your keyring "
                 "and that it has the event:read and event:write scopes.", 4)
        if e.code == 400 and raise_400:
            raise BadRequest()
        if e.code == 404:
            fail(f"Sentry has no organization at {url.split('?')[0]}. Check the organization slug.", 5)
        fail(f"Sentry returned HTTP {e.code} for {url.split('?')[0]}", 5)
    except urllib.error.URLError as e:
        fail(f"Could not reach {server}: {e.reason}", 6)


def issues_path(org, query, environment="", **params):
    # project=-1: every project the token can see, not only the user's own ones.
    env = {"environment": environment} if environment else {}
    query_string = urllib.parse.urlencode({"project": -1, "statsPeriod": PERIOD, "query": query, **env, **params})
    return f"/api/0/organizations/{urllib.parse.quote(org)}/issues/?{query_string}"


def next_page(headers):
    """The next page's URL from Sentry's Link header, or None."""
    for part in (headers.get("Link") or "").split(","):
        match = re.search(r'<([^>]+)>;\s*rel="next";\s*results="(true|false)"', part)
        if match and match.group(2) == "true":
            return match.group(1)
    return None


def with_filters(query, options):
    filters = ["level:[error,fatal]"] * options["errors_only"] + ["issue.category:error"] * options["category_errors"]
    return " ".join([query] + filters)


def events_24h(stats):
    """The issue's events in the last 24 hours: the sum of the 24h buckets, or None without stats."""
    try:
        return sum(int(bucket[1]) for bucket in stats["24h"])
    except (KeyError, TypeError, ValueError, IndexError):
        return None


def issue_summary(i):
    assignee = i.get("assignedTo")
    project = i.get("project") or {}
    return {**{k: i.get(k) for k in ISSUE_FIELDS}, "project": project.get("name") or project.get("slug"),
            "assignee": assignee.get("name") if isinstance(assignee, dict) else None,
            "events24h": events_24h(i.get("stats"))}


def hits(server, token, org, query, environment="", raise_400=False):
    """How many issues match: Sentry's X-Hits header, read from a one-issue page. Without that
    header, the issues on a full page are counted instead (so at most 100)."""
    results, headers = request(server, token, issues_path(org, query, environment, limit=1), raise_400=raise_400)
    try:
        return int(headers.get("X-Hits"))
    except (TypeError, ValueError):
        results, _ = request(server, token, issues_path(org, query, environment, limit=100), raise_400=raise_400)
        return len(results or [])


def fetch(server, org, max_pages, options):
    token = token_for(server)
    env = options["environment"]
    unresolved_query = with_filters("is:unresolved", options)
    issues, url, pages = [], issues_path(org, unresolved_query, env, sort="date", limit=100, groupStatsPeriod="24h"), 0
    unresolved = None
    while url and pages < max_pages:
        results, headers = request(server, token, url, raise_400=True)
        if unresolved is None and headers.get("X-Hits"):
            unresolved = int(headers.get("X-Hits"))
        issues += [issue_summary(i) for i in results]
        url, pages = next_page(headers), pages + 1
    counts = {
        "new": hits(server, token, org, with_filters("is:unresolved firstSeen:-24h", options), env),
        "unresolved": unresolved if unresolved is not None else len(issues),
        "archived": hits(server, token, org, with_filters("is:ignored", options), env),
        "resolved": hits(server, token, org, with_filters("is:resolved", options), env),
    }
    if options["regressed"]:
        try:
            counts["regressed"] = hits(server, token, org, with_filters("is:unresolved is:regressed", options), env, raise_400=True)
        except BadRequest:
            pass    # older self-hosted Sentry has no is:regressed; the badge just has no count
    print(json.dumps({"issues": issues, "counts": counts, "truncated": bool(url)}))


def parse_fetch_args(args):
    """(max pages, options) from the arguments after the organization, or None if they are invalid."""
    options = {"errors_only": False, "category_errors": False, "regressed": False, "environment": ""}
    flags = {"--errors-only": "errors_only", "--category-errors": "category_errors", "--regressed": "regressed"}
    pages, args = 1, list(args)
    if args and args[0].isdigit():
        pages = int(args.pop(0))
    while args:
        arg = args.pop(0)
        if arg in flags:
            options[flags[arg]] = True
        elif arg == "--environment" and args:
            options["environment"] = args.pop(0).strip()
        else:
            return None
    return pages, options


def main():
    if len(sys.argv) < 4:
        fail(__doc__, 2)
    command, server, org = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
    fetch_args = parse_fetch_args(sys.argv[4:]) if command == "fetch" else None
    if fetch_args:
        try:
            fetch(server, org, *fetch_args)
        except BadRequest:
            if fetch_args[1]["category_errors"]:
                fail("This Sentry doesn't support the error-category filter; switch it off in the settings", 5)
            fail("Sentry returned HTTP 400 for the issue search", 5)
    elif command in STATUS_FOR_ACTION and len(sys.argv) == 5 and sys.argv[4].isdigit():
        request(server, token_for(server), f"/api/0/organizations/{urllib.parse.quote(org)}/issues/?id={sys.argv[4]}",
                method="PUT", body=STATUS_FOR_ACTION[command])
    else:
        fail(__doc__, 2)


if __name__ == "__main__":
    main()

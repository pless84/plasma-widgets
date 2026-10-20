#!/usr/bin/env python3
"""Talks to Bugsink's canonical API for the Bugsink Status widget.

Usage:
  bugsink.py fetch <server-url> [max-pages-per-project]
      Prints {"projects": [...]} as JSON: per project its open issues (newest activity first),
      how many muted and resolved issues there are among the issues looked at, and the ids of
      the resolved ones (so the widget can spot regressions).
  bugsink.py <resolve|mute|unmute> <server-url> <issue-id>
      Changes one issue.

The API token is read from the keyring, where the widget's settings page stores it
(secret-tool attributes: service plasma-bugsink, server <server-url>). It is sent in the
Authorization header, so it never appears on a command line.
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request

ISSUE_FIELDS = ("id", "calculated_type", "calculated_value", "transaction", "first_seen", "last_seen",
                "digested_event_count", "friendly_id")


def fail(message, code):
    print(message, file=sys.stderr)
    sys.exit(code)


def token_for(server):
    result = subprocess.run(["secret-tool", "lookup", "service", "plasma-bugsink", "server", server],
                            capture_output=True, text=True)
    token = result.stdout.strip()
    if not token:
        fail(f"No API token in the keyring for {server}", 3)
    return token


def request(server, token, path_or_url, method="GET"):
    url = path_or_url if path_or_url.startswith("http") else server + path_or_url
    req = urllib.request.Request(url, method=method, data=b"" if method == "POST" else None, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            fail(f"Bugsink rejected the API token ({e.code}). Check the token stored in your keyring.", 4)
        fail(f"Bugsink returned HTTP {e.code} for {url.split('?')[0]}", 5)
    except urllib.error.URLError as e:
        fail(f"Could not reach {server}: {e.reason}", 6)


def paged(server, token, path, max_pages):
    """Yields results across pages; the last value yielded is True if pages were left unread."""
    url, pages = path, 0
    while url and pages < max_pages:
        page = request(server, token, url)
        yield from page["results"]
        url, pages = page.get("next"), pages + 1
    yield bool(url)


def friendly_id(issue, project):
    """SHOP-42 as Bugsink shows it: the API's own friendly_id, else project slug + digest_order, else None."""
    if issue.get("friendly_id"):
        return issue["friendly_id"]
    if project.get("slug") and issue.get("digest_order") is not None:
        return f"{project['slug'].upper()}-{issue['digest_order']}"
    return None


def fetch(server, max_pages):
    token = token_for(server)
    projects = []
    *project_list, _ = paged(server, token, "/api/canonical/0/projects/", 20)
    for project in project_list:
        *issues, truncated = paged(server, token,
                                   f"/api/canonical/0/issues/?project={project['id']}&sort=last_seen&order=desc",
                                   max_pages)
        open_issues = [{**{k: i.get(k) for k in ISSUE_FIELDS}, "friendly_id": friendly_id(i, project)}
                       for i in issues if not i.get("is_resolved") and not i.get("is_muted")]
        projects.append({
            "id": project["id"],
            "name": project["name"],
            "open": open_issues,
            "muted": sum(1 for i in issues if i.get("is_muted") and not i.get("is_resolved")),
            "resolved": sum(1 for i in issues if i.get("is_resolved")),
            "resolved_ids": [i["id"] for i in issues if i.get("is_resolved")],
            "truncated": truncated,
        })
    print(json.dumps({"projects": projects}))


def main():
    if len(sys.argv) < 3:
        fail(__doc__, 2)
    command, server = sys.argv[1], sys.argv[2].rstrip("/")
    if command == "fetch":
        fetch(server, int(sys.argv[3]) if len(sys.argv) > 3 else 10)
    elif command in ("resolve", "mute", "unmute") and len(sys.argv) == 4:
        request(server, token_for(server), f"/api/canonical/0/issues/{sys.argv[3]}/{command}/", method="POST")
    else:
        fail(__doc__, 2)


if __name__ == "__main__":
    main()

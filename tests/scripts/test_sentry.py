import json
from urllib.parse import urlencode

import pytest

from conftest import secret_tool

ORG = "acme"
ISSUES = f"/api/0/organizations/{ORG}/issues/"


def issues_route(query, **params):
    return f"GET {ISSUES}?" + urlencode({"project": -1, "statsPeriod": "90d", "query": query, **params})


def listing(query="is:unresolved", **params):
    return issues_route(query, **params, sort="date", limit=100, groupStatsPeriod="24h")


def issue(iid, project="shop", **kw):
    return {"id": iid, "shortId": f"SHOP-{iid}", "title": "KeyError: 'x'", "culprit": "app.views", "level": "error",
            "firstSeen": "2026-10-01T00:00:00Z", "lastSeen": "2026-10-09T00:00:00Z", "count": "3", "userCount": 1,
            "permalink": f"https://acme.sentry.io/issues/{iid}/", "project": {"slug": project, "name": project},
            "metadata": {"secret": "internals"}, **kw}


@pytest.fixture
def sentry(server, stubs):
    secret_tool(stubs, "plasma-sentry", server.url, "tok")
    page2 = f"{server.url}{ISSUES}?cursor=2"
    server.add(listing(), [issue("1", substatus="regressed", isUnhandled=True, priority="high",
                                 assignedTo={"type": "user", "name": "Ann", "email": "a@x"},
                                 stats={"24h": [[1, 2], [2, 3], [3, 0]]}), issue("2", project="blog")],
               headers={"X-Hits": "3", "Link": f'<{page2}>; rel="next"; results="true"; cursor="2"'})
    server.add(f"GET {ISSUES}?cursor=2", [issue("3")],
               headers={"Link": f'<{server.url}{ISSUES}?cursor=3>; rel="next"; results="false"; cursor="3"'})
    server.add(issues_route("is:unresolved firstSeen:-24h", limit=1), [issue("1")], headers={"X-Hits": "1"})
    server.add(issues_route("is:ignored", limit=1), [issue("9")], headers={"X-Hits": "4"})
    # No X-Hits: the issues on a full page are counted instead.
    server.add(issues_route("is:resolved", limit=1), [issue("7")])
    server.add(issues_route("is:resolved", limit=100), [issue("7"), issue("8")])
    return server


def test_fetch(sentry, run):
    result = run("sentrystatus", "sentry.py", "fetch", sentry.url + "/", ORG, "5")
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)
    assert [i["id"] for i in data["issues"]] == ["1", "2", "3"]
    assert [i["project"] for i in data["issues"]] == ["shop", "blog", "shop"]
    assert "metadata" not in data["issues"][0]                    # only the fields the widget shows
    first, second = data["issues"][0], data["issues"][1]
    assert (first["substatus"], first["isUnhandled"], first["priority"]) == ("regressed", True, "high")
    assert first["assignee"] == "Ann" and "assignedTo" not in first    # just the name
    assert first["events24h"] == 5
    assert second["events24h"] is None and second["assignee"] is None and second["substatus"] is None
    assert data["counts"] == {"new": 1, "unresolved": 3, "archived": 4, "resolved": 2}
    assert data["truncated"] is False
    assert {r["headers"]["authorization"] for r in sentry.requests} == {"Bearer tok"}


def test_fetch_stops_after_max_pages(sentry, run):
    result = run("sentrystatus", "sentry.py", "fetch", sentry.url, ORG)
    data = json.loads(result.stdout)
    assert [i["id"] for i in data["issues"]] == ["1", "2"]
    assert data["truncated"] is True


@pytest.mark.parametrize("action, status", [("resolve", "resolved"), ("archive", "ignored")])
def test_actions_put(sentry, run, action, status):
    sentry.add(f"PUT {ISSUES}?id=42", None, status=204)
    result = run("sentrystatus", "sentry.py", action, sentry.url, ORG, "42")
    assert result.returncode == 0, result.stderr
    assert sentry.requests[-1]["method"] == "PUT"
    assert sentry.requests[-1]["body"] == {"status": status}


@pytest.mark.parametrize("args", [("delete", "42"), ("resolve", "42&id=43"), ("resolve",)])
def test_bad_actions(sentry, run, args):
    assert run("sentrystatus", "sentry.py", args[0], sentry.url, ORG, *args[1:]).returncode == 2


@pytest.mark.parametrize("status, code, message", [
    (401, 4, "rejected the auth token (401)"), (404, 5, "Check the organization slug"), (500, 5, "HTTP 500"),
])
def test_http_errors(server, stubs, run, status, code, message):
    secret_tool(stubs, "plasma-sentry", server.url, "tok")
    server.add(f"GET {ISSUES}", {"detail": "nope"}, status)
    result = run("sentrystatus", "sentry.py", "fetch", server.url, ORG)
    assert result.returncode == code
    assert message in result.stderr


def test_no_token(server, stubs, run):
    secret_tool(stubs, "plasma-sentry", "https://other.example.com", "tok")
    result = run("sentrystatus", "sentry.py", "fetch", server.url, ORG)
    assert result.returncode == 3 and "No auth token" in result.stderr


def test_unreachable(stubs, run):
    secret_tool(stubs, "plasma-sentry", "http://127.0.0.1:9", "tok")
    result = run("sentrystatus", "sentry.py", "fetch", "http://127.0.0.1:9", ORG)
    assert result.returncode == 6 and "Could not reach" in result.stderr


def test_usage(run):
    assert run("sentrystatus", "sentry.py").returncode == 2
    assert run("sentrystatus", "sentry.py", "fetch", "https://sentry.io").returncode == 2


def test_filters_apply_to_every_request(server, stubs, run):
    secret_tool(stubs, "plasma-sentry", server.url, "tok")
    flt = " level:[error,fatal] issue.category:error"
    env = {"environment": "production"}
    server.add(issues_route("is:unresolved" + flt, **env, sort="date", limit=100, groupStatsPeriod="24h"), [issue("1")],
               headers={"X-Hits": "1"})
    for query, hits in (("is:unresolved firstSeen:-24h", 1), ("is:ignored", 2), ("is:resolved", 3),
                        ("is:unresolved is:regressed", 4)):
        server.add(issues_route(query + flt, **env, limit=1), [issue("9")], headers={"X-Hits": str(hits)})
    result = run("sentrystatus", "sentry.py", "fetch", server.url, ORG, "1", "--errors-only", "--category-errors",
                 "--regressed", "--environment", "production")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["counts"] == {"new": 1, "unresolved": 1, "archived": 2, "resolved": 3, "regressed": 4}


def test_no_regressed_count_unless_asked(sentry, run):
    data = json.loads(run("sentrystatus", "sentry.py", "fetch", sentry.url, ORG, "5").stdout)
    assert "regressed" not in data["counts"]


def test_bad_fetch_options(sentry, run):
    assert run("sentrystatus", "sentry.py", "fetch", sentry.url, ORG, "1", "--nope").returncode == 2
    assert run("sentrystatus", "sentry.py", "fetch", sentry.url, ORG, "1", "--environment").returncode == 2


def test_regressed_count_omitted_when_sentry_answers_400(sentry, run):
    sentry.add(issues_route("is:unresolved is:regressed", limit=1), {"detail": "bad query"}, 400)
    result = run("sentrystatus", "sentry.py", "fetch", sentry.url, ORG, "5", "--regressed")
    assert result.returncode == 0, result.stderr
    assert "regressed" not in json.loads(result.stdout)["counts"]


def test_category_filter_400_gives_a_clear_message(server, stubs, run):
    secret_tool(stubs, "plasma-sentry", server.url, "tok")
    server.add(f"GET {ISSUES}", {"detail": "bad query"}, 400)
    result = run("sentrystatus", "sentry.py", "fetch", server.url, ORG, "1", "--category-errors")
    assert result.returncode == 5
    assert "doesn't support the error-category filter" in result.stderr
    assert "Traceback" not in result.stderr

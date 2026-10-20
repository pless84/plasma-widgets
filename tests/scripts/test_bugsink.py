import json

import pytest

from conftest import secret_tool

API = "/api/canonical/0"


@pytest.fixture
def bugsink(server, stubs):
    secret_tool(stubs, "plasma-bugsink", server.url, "tok")
    server.add(f"GET {API}/projects/", {"results": [{"id": 1, "name": "Shop", "slug": "shop"}, {"id": 2, "name": "Quiet"}], "next": None})
    issue = lambda iid, **kw: {"id": iid, "calculated_type": "KeyError", "calculated_value": "'x'", "transaction": "/t",
                               "first_seen": "2026-10-01T00:00:00Z", "last_seen": "2026-10-09T00:00:00Z",
                               "digested_event_count": 3, "digest_order": {"o1": 1, "o2": 2}.get(iid, 9), "stacktrace": "secret internals", **kw}
    server.add(f"GET {API}/issues/?project=1&sort=last_seen&order=desc",
               {"results": [issue("o1"), issue("m1", is_muted=True), issue("r1", is_resolved=True),
                            issue("rm", is_resolved=True, is_muted=True)],
                "next": f"{server.url}{API}/issues/page2"})
    server.add(f"GET {API}/issues/page2", {"results": [issue("o2")], "next": None})
    server.add(f"GET {API}/issues/?project=2&sort=last_seen&order=desc", {"results": [], "next": None})
    return server


def test_fetch(bugsink, run):
    result = run("bugsinkstatus", "bugsink.py", "fetch", bugsink.url + "/")
    assert result.returncode == 0, result.stderr
    shop, quiet = json.loads(result.stdout)["projects"]
    assert [i["id"] for i in shop["open"]] == ["o1", "o2"]
    assert (shop["muted"], shop["resolved"], shop["truncated"]) == (1, 2, False)   # resolved+muted counts as resolved
    assert shop["resolved_ids"] == ["r1", "rm"]
    assert [i["friendly_id"] for i in shop["open"]] == ["SHOP-1", "SHOP-2"]       # slug + digest_order
    assert "stacktrace" not in shop["open"][0]                                     # only the fields the widget shows
    assert quiet == {"id": 2, "name": "Quiet", "open": [], "muted": 0, "resolved": 0, "resolved_ids": [], "truncated": False}
    assert {r["headers"]["authorization"] for r in bugsink.requests} == {"Bearer tok"}


def test_fetch_stops_after_max_pages(bugsink, run):
    result = run("bugsinkstatus", "bugsink.py", "fetch", bugsink.url, "1")
    shop = json.loads(result.stdout)["projects"][0]
    assert shop["truncated"] is True
    assert [i["id"] for i in shop["open"]] == ["o1"]


def test_actions_post(bugsink, run):
    bugsink.add(f"POST {API}/issues/o1/resolve/", {"ok": True})
    result = run("bugsinkstatus", "bugsink.py", "resolve", bugsink.url, "o1")
    assert result.returncode == 0, result.stderr
    assert bugsink.requests[-1]["method"] == "POST"
    assert run("bugsinkstatus", "bugsink.py", "delete", bugsink.url, "o1").returncode == 2


@pytest.mark.parametrize("status, code, message", [
    (401, 4, "rejected the API token (401)"), (500, 5, "HTTP 500"),
])
def test_http_errors(server, stubs, run, status, code, message):
    secret_tool(stubs, "plasma-bugsink", server.url, "tok")
    server.add(f"GET {API}/projects/", {"detail": "nope"}, status)
    result = run("bugsinkstatus", "bugsink.py", "fetch", server.url)
    assert result.returncode == code
    assert message in result.stderr


def test_no_token(server, stubs, run):
    secret_tool(stubs, "plasma-bugsink", "https://other.example.com", "tok")
    result = run("bugsinkstatus", "bugsink.py", "fetch", server.url)
    assert result.returncode == 3 and "No API token" in result.stderr


def test_unreachable(stubs, run):
    secret_tool(stubs, "plasma-bugsink", "http://127.0.0.1:9", "tok")
    result = run("bugsinkstatus", "bugsink.py", "fetch", "http://127.0.0.1:9")
    assert result.returncode == 6 and "Could not reach" in result.stderr


def test_usage(run):
    assert run("bugsinkstatus", "bugsink.py").returncode == 2


def test_friendly_id_from_api_or_omitted(server, stubs, run):
    secret_tool(stubs, "plasma-bugsink", server.url, "tok")
    server.add(f"GET {API}/projects/", {"results": [{"id": 1, "name": "NoSlug"}], "next": None})
    server.add(f"GET {API}/issues/?project=1&sort=last_seen&order=desc",
               {"results": [{"id": "a", "friendly_id": "X-7", "digest_order": 7}, {"id": "b", "digest_order": 8}],
                "next": None})
    result = run("bugsinkstatus", "bugsink.py", "fetch", server.url)
    assert [i["friendly_id"] for i in json.loads(result.stdout)["projects"][0]["open"]] == ["X-7", None]

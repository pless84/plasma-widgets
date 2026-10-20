"""fetch.sh / action.sh for PRTG, Docker and GitHub Account."""
import json
import shutil
from urllib.parse import parse_qs, urlsplit

import pytest

from conftest import secret_tool


# PRTG: secret-tool for the key, the real curl against the fake server.

@pytest.mark.skipif(not shutil.which("curl"), reason="needs curl")
def test_prtg_fetch(server, stubs, run):
    secret_tool(stubs, "plasma-prtg", server.url, "k3y")
    server.add("GET /api/table.json", {"sensors": [{"objid": 1, "status_raw": 5}]})
    result = run("prtgstatus", "fetch.sh", server.url)
    assert result.returncode == 0, result.stderr
    # The fake server answers every table.json alike, so the probes table isn't one and the
    # counts fall back to every sensor (test_prtgstatus.py covers the root and probe rows).
    assert json.loads(result.stdout) == {"problems": {"sensors": [{"objid": 1, "status_raw": 5}]},
                                         "root": {"probes": []},
                                         "probes": {"probes": []},
                                         "all": {"sensors": [{"objid": 1, "status_raw": 5}]},
                                         "extra": {"sensors": []}}
    queries = [parse_qs(urlsplit(r["path"]).query) for r in server.requests]
    problems, everything = queries[0], queries[-1]
    assert problems["filter_status"] == ["4", "5", "10", "13", "14"]
    assert all(q["apitoken"] == ["k3y"] for q in queries)
    assert "filter_status" not in everything


@pytest.mark.skipif(not shutil.which("curl"), reason="needs curl")
def test_prtg_fetch_extra_states(server, stubs, run):
    secret_tool(stubs, "plasma-prtg", server.url, "k3y")
    server.add("GET /api/table.json", {"sensors": [{"objid": 1, "status_raw": 7}]})
    result = run("prtgstatus", "fetch.sh", server.url, "7,8,3")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["extra"] == {"sensors": [{"objid": 1, "status_raw": 7}]}
    extra = parse_qs(urlsplit(server.requests[-1]["path"]).query)
    assert extra["filter_status"] == ["7", "8", "3"]
    assert "message_raw" in extra["columns"][0]


def test_prtg_rejects_bad_status_codes(stubs, run):
    secret_tool(stubs, "plasma-prtg", "https://prtg.example.com", "k3y")
    stubs.add("curl", 'echo \'{"sensors":[]}\'')
    result = run("prtgstatus", "fetch.sh", "https://prtg.example.com", "7,8&x=1")
    assert result.returncode == 2 and "Invalid status code" in result.stderr


@pytest.mark.skipif(not shutil.which("curl"), reason="needs curl")
def test_prtg_http_error(server, stubs, run):
    secret_tool(stubs, "plasma-prtg", server.url, "k3y")
    server.add("GET /api/table.json", {}, 401)
    result = run("prtgstatus", "fetch.sh", server.url)
    assert result.returncode != 0 and result.stdout == ""


def test_prtg_needs_server_and_key(stubs, run):
    secret_tool(stubs, "plasma-prtg", "https://prtg.example.com", "k3y")
    assert run("prtgstatus", "fetch.sh", "").returncode == 2
    result = run("prtgstatus", "fetch.sh", "https://other.example.com")
    assert result.returncode == 3 and "No API key" in result.stderr


# Docker: a stub docker CLI.

@pytest.fixture
def docker(stubs):
    stubs.add("docker", 'echo \'{"ID":"a1"}\'')
    return stubs


def test_docker_fetch(docker, run):
    assert run("dockerstatus", "fetch.sh", "").stdout == '{"ID":"a1"}\n'
    assert docker.calls("docker")[-1]["args"] == ["ps", "--all", "--no-trunc", "--format", "{{json .}}"]
    run("dockerstatus", "fetch.sh", "colima")
    assert docker.calls("docker")[-1]["args"][:3] == ["--context", "colima", "ps"]


@pytest.mark.parametrize("context, expected", [("", ["restart", "a1"]), ("colima", ["--context", "colima", "restart", "a1"])])
def test_docker_action(docker, run, context, expected):
    assert run("dockerstatus", "action.sh", context, "restart", "a1").returncode == 0
    assert docker.calls("docker")[-1]["args"] == expected


@pytest.mark.parametrize("args, expected", [
    (["down", "--project", "shop"], ["compose", "--project-name", "shop", "down"]),
    (["start", "--project", "shop"], ["compose", "--project-name", "shop", "start"]),
    (["rmi", "nginx:1.27"], ["image", "rm", "nginx:1.27"]),
    (["rmi", "sha256:ccc333"], ["image", "rm", "sha256:ccc333"]),
])
def test_docker_stack_and_image_actions(docker, run, args, expected):
    assert run("dockerstatus", "action.sh", "", *args).returncode == 0
    assert docker.calls("docker")[-1]["args"] == expected


@pytest.mark.parametrize("args", [["down", "a1"], ["rmi"], ["rmi", "--project", "shop"], ["prune", "a1"]])
def test_docker_action_refuses_bad_use(docker, run, args):
    # "down" is for whole stacks only, and nothing unknown reaches docker.
    assert run("dockerstatus", "action.sh", "", *args).returncode == 2
    assert docker.calls("docker") == []


@pytest.mark.parametrize("context", ["", "colima"])
@pytest.mark.parametrize("args", [
    ["down"], ["down", "a1"], ["down", "--project"], ["down", "--project", ""],
    ["stop", "--project"], ["stop", "--project", ""],
])
def test_docker_stack_action_needs_a_project(docker, run, context, args):
    # Removing a stack must name its project: without one compose would guess from the
    # current directory, so these are refused before docker runs.
    result = run("dockerstatus", "action.sh", context, *args)
    assert result.returncode == 2 and "needs --project <compose-project>" in result.stderr
    assert docker.calls("docker") == []


def test_docker_images(docker, run):
    assert run("dockerstatus", "images.sh", "").stdout == '{"ID":"a1"}\n'
    assert docker.calls("docker")[-1]["args"] == ["image", "ls", "--no-trunc", "--format", "{{json .}}"]
    run("dockerstatus", "images.sh", "colima")
    assert docker.calls("docker")[-1]["args"][:3] == ["--context", "colima", "image"]


def test_docker_inspect(docker, run):
    assert run("dockerstatus", "inspect.sh", "", "a1", "b2").stdout == '{"ID":"a1"}\n'
    args = docker.calls("docker")[-1]["args"]
    assert args[0] == "inspect" and args[1] == "--format" and args[3:] == ["a1", "b2"]
    assert "{{json .State}}" in args[2] and ".RestartCount" in args[2]
    run("dockerstatus", "inspect.sh", "colima", "a1")
    assert docker.calls("docker")[-1]["args"][:3] == ["--context", "colima", "inspect"]
    assert docker.calls("docker")[-1]["args"][-1] == "a1"


def test_docker_df(docker, run):
    assert run("dockerstatus", "df.sh", "").stdout == '{"ID":"a1"}\n'
    assert docker.calls("docker")[-1]["args"] == ["system", "df", "--format", "{{json .}}"]
    run("dockerstatus", "df.sh", "colima")
    assert docker.calls("docker")[-1]["args"][:3] == ["--context", "colima", "system"]


@pytest.mark.parametrize("context, expected", [
    ("", ["compose", "--project-name", "shop", "stop"]),
    ("colima", ["--context", "colima", "compose", "--project-name", "shop", "stop"]),
])
def test_docker_stack_action(docker, run, context, expected):
    assert run("dockerstatus", "action.sh", context, "stop", "--project", "shop").returncode == 0
    assert docker.calls("docker")[-1]["args"] == expected


@pytest.mark.parametrize("args", [("rm", "a1"), ("kill", "--project", "shop")])
def test_docker_action_rejects_other_commands(docker, run, args):
    result = run("dockerstatus", "action.sh", "", *args)
    assert result.returncode == 2 and "Unknown action" in result.stderr
    assert docker.calls("docker") == []


# GitHub Account: a stub gh CLI.

@pytest.fixture
def gh(stubs):
    stubs.add("gh", """
case "$1 $2" in
  "auth token") [ "$6" = "work" ] && echo gho_work && exit 0; exit 1 ;;
  "api notifications") echo '[{"id":"1"}]' ;;
  "api graphql") echo '{"data":{"viewer":{"login":"octo"}}}' ;;
esac""", record_env=("GH_TOKEN",))
    return stubs


def test_github_fetch(gh, run):
    result = run("githubaccount", "fetch.sh", "", env={"GH_TOKEN": ""})
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"notifications": [{"id": "1"}], "graphql": {"data": {"viewer": {"login": "octo"}}}}
    calls = gh.calls("gh")
    assert [c["args"][:2] for c in calls] == [["api", "notifications"], ["api", "graphql"]]
    assert all(c["env"]["GH_TOKEN"] == "" for c in calls)      # gh's active account


def test_github_fetch_as_another_account(gh, run):
    result = run("githubaccount", "fetch.sh", "work", env={"GH_TOKEN": ""})
    assert result.returncode == 0, result.stderr
    api_calls = [c for c in gh.calls("gh") if c["args"][0] == "api"]
    assert api_calls and all(c["env"]["GH_TOKEN"] == "gho_work" for c in api_calls)
    assert not any("gho_work" in " ".join(c["args"]) for c in gh.calls("gh"))   # never on a command line


def test_github_fetch_unknown_account(gh, run):
    result = run("githubaccount", "fetch.sh", "nobody")
    assert result.returncode == 4 and "not logged in as nobody" in result.stderr


def test_github_mark_read(gh, run):
    assert run("githubaccount", "fetch.sh", "", "mark-read").returncode == 0
    assert gh.calls("gh")[0]["args"] == ["api", "-X", "PUT", "notifications", "--silent"]

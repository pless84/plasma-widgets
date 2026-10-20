import importlib.util
import json
import urllib.request
from pathlib import Path

import pytest

from conftest import secret_tool


@pytest.fixture
def dokploy(server, stubs):
    secret_tool(stubs, "plasma-dokploy", server.url, "key")
    server.add("GET /api/project.all", [{
        "projectId": "p1", "name": "Shop", "env": {"SECRET": "x"},
        "environments": [{
            "environmentId": "e1", "name": "production",
            "applications": [{"applicationId": "a1", "name": "web", "applicationStatus": "done", "env": "TOKEN=1"}],
            "compose": [{"composeId": "c1", "name": "stack", "composeStatus": "running"}],
            "postgres": [{"postgresId": "d1"}],
            "libsql": [{"libsqlId": "l1"}],
            "mysql": None,
        }],
    }])
    server.add("GET /api/postgres.one?postgresId=d1", {
        "name": "shop-db", "applicationStatus": "error", "databasePassword": "hunter2",
        "server": {"name": "edge-1", "sshKeyId": "k", "ipAddress": "10.0.0.9"},
        "backups": [{"enabled": True, "schedule": "0 3 * * *", "databaseType": "postgres", "database": "shopdb",
                     "destination": {"name": "s3", "bucket": "secret-bucket"},
                     "deployments": [
                         {"deploymentId": "b1", "status": "done", "createdAt": "2026-10-01T03:00:00Z", "logPath": "/l/1"},
                         {"deploymentId": "b2", "status": "error", "createdAt": "2026-10-02T03:00:00Z",
                          "errorMessage": "upload failed", "logPath": "/l/2"}]}],
    })
    server.add("GET /api/libsql.one?libsqlId=l1", {"name": "edge-sql", "applicationStatus": "done", "server": None, "backups": []})
    server.add("GET /api/deployment.allCentralized", [
        {"deploymentId": "x1", "applicationId": "a1", "status": "done", "title": "Old", "createdAt": "2026-10-01T10:00:00Z",
         "application": {"applicationId": "a1", "server": {"name": "edge-1"}}, "logPath": "/secret"},
        {"deploymentId": "x2", "applicationId": "a1", "status": "error", "title": "Fix login", "description": "Hash: abc1234def",
         "errorMessage": "build failed", "createdAt": "2026-10-02T10:00:00Z", "startedAt": "2026-10-02T10:00:01Z",
         "finishedAt": "2026-10-02T10:01:33Z", "application": {"applicationId": "a1", "server": {"name": "edge-1"}},
         "logPath": "/secret"},
        {"deploymentId": "x3", "applicationId": "a1", "status": "done", "title": "Preview", "isPreviewDeployment": True,
         "createdAt": "2026-10-03T10:00:00Z", "application": {"applicationId": "a1"}},
    ])
    return server


def test_fetch(dokploy, run):
    result = run("dokploystatus", "dokploy.py", "fetch", dokploy.url + "/")
    assert result.returncode == 0, result.stderr
    dep = {"id": "x2", "status": "error", "title": "Fix login", "description": "Hash: abc1234def",
           "errorMessage": "build failed", "createdAt": "2026-10-02T10:00:00Z",
           "startedAt": "2026-10-02T10:00:01Z", "finishedAt": "2026-10-02T10:01:33Z"}
    assert json.loads(result.stdout) == {"projects": [{"id": "p1", "name": "Shop", "environments": [{
        "id": "e1", "name": "production", "services": [
            {"type": "application", "id": "a1", "name": "web", "status": "done", "deployment": dep, "server": "edge-1"},
            {"type": "compose", "id": "c1", "name": "stack", "status": "running", "deployment": None},  # not in the history: never deployed
            {"type": "postgres", "id": "d1", "name": "shop-db", "status": "error", "server": "edge-1", "backups": [{
                "enabled": True, "schedule": "0 3 * * *", "last": {
                    "id": "b2", "status": "error",
                    "createdAt": "2026-10-02T03:00:00Z", "startedAt": None, "finishedAt": None}}]},
            {"type": "libsql", "id": "l1", "name": "edge-sql", "status": "done", "server": "", "backups": []},
        ]}]}]}
    for secret in ("hunter2", "TOKEN", "SECRET", "secret-bucket", "shopdb", "10.0.0.9", "/secret", "/l/", "upload failed"):
        assert secret not in result.stdout
    assert {r["headers"]["x-api-key"] for r in dokploy.requests} == {"key"}


def test_fetch_without_all_centralized(dokploy, run):
    """Older Dokploy: only failed services are asked for their deployments."""
    dokploy.add("GET /api/project.all", [{"projectId": "p1", "name": "Shop", "environments": [{
        "environmentId": "e1", "name": "production",
        "applications": [{"applicationId": "a1", "name": "web", "applicationStatus": "error"},
                         {"applicationId": "a2", "name": "ok", "applicationStatus": "done"}],
        "compose": [{"composeId": "c1", "name": "stack", "composeStatus": "done"}]}]}])
    dokploy.add("GET /api/deployment.allCentralized", {"message": "No procedure"}, 404)
    dokploy.add("GET /api/deployment.all?applicationId=a1", [
        {"deploymentId": "x8", "status": "done", "title": "Old", "createdAt": "2026-10-01T10:00:00Z"},
        {"deploymentId": "x9", "status": "error", "title": "T", "errorMessage": "boom", "createdAt": "2026-10-02T10:00:00Z"}])
    result = run("dokploystatus", "dokploy.py", "fetch", dokploy.url)
    assert result.returncode == 0, result.stderr
    web, ok, stack = json.loads(result.stdout)["projects"][0]["environments"][0]["services"]
    assert web["deployment"]["id"] == "x9" and web["deployment"]["errorMessage"] == "boom"
    assert "deployment" not in ok and "deployment" not in stack
    assert not [r for r in dokploy.requests if "a2" in r["path"] or "c1" in r["path"]]


def test_actions(dokploy, run):
    dokploy.add("POST /api/compose.deploy", None)
    result = run("dokploystatus", "dokploy.py", "deploy", dokploy.url, "compose", "c1")
    assert result.returncode == 0, result.stderr
    assert dokploy.requests[-1]["body"] == {"composeId": "c1"}


@pytest.mark.parametrize("args", [("delete", "compose", "c1"), ("deploy", "server", "s1"), ("deploy", "compose")])
def test_rejects_unknown_actions_and_types(dokploy, run, args):
    action, *rest = args
    assert run("dokploystatus", "dokploy.py", action, dokploy.url, *rest).returncode == 2
    assert not dokploy.requests


def test_http_error_shows_dokploys_message(server, stubs, run):
    secret_tool(stubs, "plasma-dokploy", server.url, "key")
    server.add("GET /api/project.all", {"message": "Database is down"}, 500)
    result = run("dokploystatus", "dokploy.py", "fetch", server.url)
    assert result.returncode == 5
    assert "HTTP 500 for project.all: Database is down" in result.stderr


def test_rejected_key(server, stubs, run):
    secret_tool(stubs, "plasma-dokploy", server.url, "key")
    server.add("GET /api/project.all", {}, 401)
    result = run("dokploystatus", "dokploy.py", "fetch", server.url)
    assert result.returncode == 4 and "rejected the API key" in result.stderr


def test_no_key(server, stubs, run):
    secret_tool(stubs, "plasma-dokploy", "https://other.example.com", "key")
    assert run("dokploystatus", "dokploy.py", "fetch", server.url).returncode == 3


def load_script():
    spec = importlib.util.spec_from_file_location("dokploy_script", Path(__file__).parents[2] / "dokploystatus/contents/code/dokploy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("message", [
    "Error: Command failed: docker run --env DB_PASSWORD=hunter2 --env 'API=a b' -e TOKEN=abc123 img\nstderr: boom",
    "rclone sync --s3-secret-access-key=AKIASECRET99 --s3-access-key-id AKIAID123 /data s3:bucket failed",
    "could not connect to postgres://admin:s3cr3t@db.internal:5432/app",
    "PGPASSWORD=s3cr3t pg_dump failed",
    "mysqldump -u root -pTOPSECRET shop failed",
    "request failed: Authorization: Bearer abc.def.ghi",
])
def test_redact_leaves_no_secret(message):
    out = load_script().redact(message)
    assert out and "\n" not in out and len(out) <= 160
    for secret in ("hunter2", "a b", "abc123", "AKIASECRET99", "AKIAID123", "s3cr3t", "TOPSECRET", "abc.def.ghi", "docker run"):
        assert secret not in out


def test_redact_keeps_a_plain_reason_and_shortens_command_failures():
    script = load_script()
    assert script.redact("build failed: exit code 1") == "build failed: exit code 1"
    assert script.redact("Error: Command failed: docker build --env A=b .\nnpm ERR! missing script") == "npm ERR! missing script"
    assert script.redact("Command failed: docker build --env A=b .") == "Command failed"
    assert script.redact(None) is None and script.redact("") is None


def test_fetch_redacts_deployment_errors_and_drops_backup_errors(dokploy, run):
    dokploy.add("GET /api/deployment.allCentralized", [
        {"deploymentId": "x2", "applicationId": "a1", "status": "error", "createdAt": "2026-10-02T10:00:00Z",
         "errorMessage": "Error: Command failed: docker build --env DB_PASSWORD=hunter2 .\ndeploy failed postgres://u:p4ss@h/db",
         "application": {"applicationId": "a1", "server": None}}])
    result = run("dokploystatus", "dokploy.py", "fetch", dokploy.url)
    assert result.returncode == 0, result.stderr
    for secret in ("hunter2", "p4ss", "docker build", "upload failed"):
        assert secret not in result.stdout
    web = json.loads(result.stdout)["projects"][0]["environments"][0]["services"][0]
    assert web["deployment"]["errorMessage"] == "deploy failed postgres://***@h/db"
    assert web["server"] == ""      # the relation is embedded and has no server: the Dokploy host


def test_fetch_service_missing_from_all_centralized_was_never_deployed_and_server_needs_a_relation(dokploy, run):
    dokploy.add("GET /api/deployment.allCentralized", [
        {"deploymentId": "x1", "applicationId": "a1", "status": "done", "createdAt": "2026-10-01T10:00:00Z"}])
    services = json.loads(run("dokploystatus", "dokploy.py", "fetch", dokploy.url).stdout)["projects"][0]["environments"][0]["services"]
    web, stack = services[0], services[1]
    assert web["deployment"]["id"] == "x1" and "server" not in web      # no application relation embedded: no server
    # allCentralized is the whole history (checked against a real Dokploy), so no entry means never deployed.
    assert stack["deployment"] is None and "server" not in stack


class Reply:
    def __init__(self, raw):
        self.raw = raw

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return self.raw


@pytest.mark.parametrize("failure", [TimeoutError("timed out"), OSError("reset"), Reply(b"<html>not json</html>")])
def test_soft_call_falls_back_on_timeout_and_non_json(monkeypatch, failure):
    def urlopen(req, timeout):
        if isinstance(failure, Exception):
            raise failure
        return failure
    monkeypatch.setattr(urllib.request, "urlopen", urlopen)
    assert load_script().call("http://x", "k", "deployment.allCentralized", soft=True) is None
    with pytest.raises(SystemExit):
        load_script().call("http://x", "k", "project.all")


def test_all_centralized_uses_a_longer_timeout(monkeypatch):
    seen = []

    def urlopen(req, timeout):
        seen.append((req.full_url.rsplit("/", 1)[-1], timeout))
        return Reply(b"[]")
    monkeypatch.setattr(urllib.request, "urlopen", urlopen)
    load_script().latest_deployments("http://x", "k", [])
    assert seen == [("deployment.allCentralized", 120)]

#!/usr/bin/env python3
"""Talks to Dokploy's API for the Dokploy Status widget.

Usage:
  dokploy.py fetch <server-url>
      Prints {"projects": [...]} as JSON: every project with its environments and their
      services (applications, compose stacks and databases) with name, type and status, the
      newest deployment of applications and compose stacks, and the server name and backup
      state of databases.
  dokploy.py <deploy|start|stop> <server-url> <service-type> <service-id>
      Deploys, starts or stops one service. Types: application, compose, postgres, mysql,
      mariadb, mongo, redis, libsql.

The API key is read from the keyring, where the widget's settings page stores it
(secret-tool attributes: service plasma-dokploy, server <server-url>). It is sent in the
x-api-key header, so it never appears on a command line. Only names, statuses, deployment
and backup results are copied out of Dokploy's responses, field by field; database passwords,
environment variables, backup credentials and logs are not.
"""
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

DATABASE_TYPES = ("postgres", "mysql", "mariadb", "mongo", "redis", "libsql")
SERVICE_TYPES = ("application", "compose") + DATABASE_TYPES


def fail(message, code):
    print(message, file=sys.stderr)
    sys.exit(code)


def key_for(server):
    result = subprocess.run(["secret-tool", "lookup", "service", "plasma-dokploy", "server", server],
                            capture_output=True, text=True)
    key = result.stdout.strip()
    if not key:
        fail(f"No API key in the keyring for {server}", 3)
    return key


def call(server, key, endpoint, params=None, body=None, soft=False, timeout=30):
    """soft: any failure (HTTP error, unreachable, timeout, a reply that is not JSON) gives None."""
    url = f"{server}/api/{endpoint}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if body is not None else "GET", headers={
        "x-api-key": key,
        "Accept": "application/json",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if soft:
            return None
        if e.code in (401, 403):
            fail(f"Dokploy rejected the API key ({e.code}). Check the key stored in your keyring.", 4)
        detail = ""
        try:
            detail = json.loads(e.read()).get("message", "")
        except Exception:
            pass
        fail(f"Dokploy returned HTTP {e.code} for {endpoint}" + (f": {detail}" if detail else ""), 5)
    except urllib.error.URLError as e:
        if soft:
            return None
        fail(f"Could not reach {server}: {e.reason}", 6)
    except (OSError, ValueError) as e:     # read timeout, dropped connection, a body that is not JSON
        if soft:
            return None
        fail(f"Dokploy gave no usable answer for {endpoint} ({type(e).__name__})", 6)


def clip(text, limit=300):
    return text[:limit] if isinstance(text, str) else None


VALUE = r"""(?:"[^"]*"|'[^']*'|\S+)"""
SECRET_NAME = r"[\w.-]*(?:key|secret|passw(?:or)?d|token|credential)[\w.-]*"
REDACTIONS = (
    (re.compile(rf"(--{SECRET_NAME})(?:=|\s+){VALUE}", re.I), r"\1=***"),             # --s3-secret-access-key=...
    (re.compile(rf"(--env(?:-file)?|\s-e)(=|\s+)([\w.-]+)=(?:{VALUE})?", re.I), r"\1\2\3=***"),  # --env KEY=VALUE
    (re.compile(rf"\b({SECRET_NAME})=({VALUE})?", re.I), r"\1=***"),                  # PGPASSWORD=..., API_TOKEN=...
    (re.compile(r"(\w+://)[^/\s@]*@"), r"\1***@"),                                      # scheme://user:pass@host
    (re.compile(r"(?<!\S)-p(?=\S)\S+"), "-p***"),                                       # mysql -pSECRET
    (re.compile(r"(authorization:?)\s+(?:(?:bearer|basic)\s+)?\S+", re.I), r"\1 ***"),
    (re.compile(r"(bearer)\s+\S+", re.I), r"\1 ***"),
)


def redact(text):
    """A deployment's error message as one short line that holds no secrets. Dokploy's free
    text can contain the failed shell command with environment variables, backup (S3/rclone)
    credentials and connection strings; command lines are dropped down to their reason, and
    what looks like a secret in the line that stays is masked."""
    lines = [re.sub(r"Command failed\b.*", "Command failed", line.strip(), flags=re.I)
             for line in (text or "").splitlines() if line.strip()]
    line = next((l for l in lines if not re.fullmatch(r"(?:\w*Error:\s*)?Command failed", l, re.I)), lines[0] if lines else "")
    for pattern, replacement in REDACTIONS:
        line = pattern.sub(replacement, line)
    return line[:160] or None


def deployment_out(d):
    """The few fields of a deployment the widget shows (never its log path or log)."""
    return {"id": d.get("deploymentId"), "status": d.get("status"), "title": clip(d.get("title"), 200),
            "description": clip(d.get("description"), 200), "errorMessage": redact(d.get("errorMessage")),
            "createdAt": d.get("createdAt"), "startedAt": d.get("startedAt"), "finishedAt": d.get("finishedAt")}


def is_service_deployment(d):
    """Plain deploys; not previews, schedule runs or volume backups."""
    return not (d.get("isPreviewDeployment") or d.get("previewDeploymentId") or d.get("scheduleId")
                or d.get("volumeBackupId") or d.get("backupId"))


def newest(deployments, accept=is_service_deployment):
    """The newest accepted deployment of a list, or None."""
    deployments = [d for d in deployments or [] if isinstance(d, dict) and accept(d)]
    return max(deployments, key=lambda d: d.get("createdAt") or "", default=None)


def latest_deployments(server, key, projects):
    """({service id: newest deployment}, {service id: server name}, complete) for applications
    and compose stacks. Uses deployment.allCentralized: one call with the whole deployment history
    (so a longer timeout), checked against a real Dokploy to cover every deployed service; then
    complete is True and a service missing from it has never been deployed. A server name is only
    taken from a relation the reply embeds. Without that call (older Dokploy, a timeout, a reply
    that is not JSON), deployment.all / deployment.allByCompose are asked for the failed services
    only, and complete is False."""
    rows = call(server, key, "deployment.allCentralized", soft=True, timeout=120)
    deployments, servers = {}, {}
    if isinstance(rows, list):
        for d in rows:
            if not isinstance(d, dict) or not is_service_deployment(d):
                continue
            for kind in ("application", "compose"):
                service_id = d.get(f"{kind}Id")
                if not service_id:
                    continue
                related = d.get(kind)
                if isinstance(related, dict) and "server" in related:
                    servers[service_id] = (related["server"] or {}).get("name") or ""
                if service_id not in deployments or (d.get("createdAt") or "") > (deployments[service_id].get("createdAt") or ""):
                    deployments[service_id] = d
        return {i: deployment_out(d) for i, d in deployments.items()}, servers, True
    for project in projects:
        for env in project.get("environments", []):
            for kind, status_key, endpoint, listing in (("application", "applicationStatus", "deployment.all", "applications"),
                                                        ("compose", "composeStatus", "deployment.allByCompose", "compose")):
                for service in env.get(listing) or []:
                    if service.get(status_key) == "error":
                        d = newest(call(server, key, endpoint, {f"{kind}Id": service[f"{kind}Id"]}, soft=True))
                        if d:
                            deployments[service[f"{kind}Id"]] = deployment_out(d)
    return deployments, servers, False


def backup_run_out(d):
    """A backup run's id, status and times. Never its error message: that is free text from the
    failed backup command and can hold credentials."""
    return {"id": d.get("deploymentId"), "status": d.get("status"), "createdAt": d.get("createdAt"),
            "startedAt": d.get("startedAt"), "finishedAt": d.get("finishedAt")}


def backups_out(backups):
    """Per backup: whether it is on, its schedule and its newest run. Nothing else of a backup
    (destination, credentials, database name) is copied."""
    out = []
    for backup in backups or []:
        last = newest(backup.get("deployments"), lambda d: True)
        out.append({"enabled": bool(backup.get("enabled")), "schedule": clip(backup.get("schedule"), 60),
                    "last": last and backup_run_out(last)})
    return out


def service_extras(latest, service_id):
    """The newest deployment and the server name of an application or compose stack. The
    deployment is None (never deployed) when the full history doesn't have one, and left out when
    only some services were asked (unknown). The server is left out when Dokploy didn't say."""
    deployments, servers, complete = latest
    out = {}
    if service_id in deployments:
        out["deployment"] = deployments[service_id]
    elif complete:
        out["deployment"] = None
    if service_id in servers:
        out["server"] = servers[service_id]
    return out


def fetch(server):
    key = key_for(server)
    projects = []
    all_projects = call(server, key, "project.all")
    latest = latest_deployments(server, key, all_projects)
    for project in all_projects:
        environments = []
        for env in project.get("environments", []):
            services = []
            for app in env.get("applications") or []:
                services.append({"type": "application", "id": app["applicationId"], "name": app["name"],
                                 "status": app.get("applicationStatus"), **service_extras(latest, app["applicationId"])})
            for compose in env.get("compose") or []:
                services.append({"type": "compose", "id": compose["composeId"], "name": compose["name"],
                                 "status": compose.get("composeStatus"), **service_extras(latest, compose["composeId"])})
            for db_type in DATABASE_TYPES:
                for db in env.get(db_type) or []:
                    db_id = db[f"{db_type}Id"]
                    detail = call(server, key, f"{db_type}.one", {f"{db_type}Id": db_id}) or {}
                    services.append({"type": db_type, "id": db_id, "name": detail.get("name", db_type),
                                     "status": detail.get("applicationStatus"),
                                     "server": (detail.get("server") or {}).get("name") or "",
                                     "backups": backups_out(detail.get("backups"))})
            environments.append({"id": env["environmentId"], "name": env["name"], "services": services})
        projects.append({"id": project["projectId"], "name": project["name"], "environments": environments})
    print(json.dumps({"projects": projects}))


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "fetch":
        fetch(sys.argv[2].rstrip("/"))
    elif len(sys.argv) == 5 and sys.argv[1] in ("deploy", "start", "stop") and sys.argv[3] in SERVICE_TYPES:
        action, server, service_type, service_id = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3], sys.argv[4]
        call(server, key_for(server), f"{service_type}.{action}", body={f"{service_type}Id": service_id})
    else:
        fail(__doc__, 2)


if __name__ == "__main__":
    main()

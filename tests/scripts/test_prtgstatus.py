"""PRTG Status fetch.sh: the root row for the counts, the probes for per-probe lines, the
sensor-table fallback, the new columns."""
import json
import shutil
from urllib.parse import parse_qs, urlsplit

import pytest

from conftest import secret_tool

ROOT = {"treesize": 1, "probes": [{"objid": 0, "probe": "", "upsens_raw": 9, "undefinedsens_raw": 3, "totalsens_raw": 12}]}
PROBES = {"treesize": 2, "probes": [{"objid": 1, "probe": "Local", "upsens": 5, "totalsens": 5},
                                    {"objid": 2, "probe": "Remote", "undefinedsens": 3, "totalsens": 3}]}
SENSORS = {"sensors": [{"objid": 9, "status_raw": 5}]}


class ByContent(dict):
    """Routes keyed by the table.json "content" ("sensors", or "root"/"probes" for content=probes
    filtered to objid 0 / parentid 0), since FakeServer only matches whole paths."""

    def get(self, key, default=None):
        query = parse_qs(urlsplit(key.split(" ", 1)[1]).query)
        content = query.get("content", [""])[0]
        if content == "probes":
            content = "root" if "filter_objid" in query else "probes"
        return super().get(content, default)


def serve(server, sensors, probes, root=ROOT, root_status=200):
    server.routes = ByContent({"sensors": (200, sensors, {}), "probes": (200, probes, {}),
                               "root": (root_status, root, {})})


def queries(server):
    return [parse_qs(urlsplit(r["path"]).query) for r in server.requests]


@pytest.mark.skipif(not shutil.which("curl"), reason="needs curl")
def test_counts_come_from_the_root_row(server, stubs, run):
    secret_tool(stubs, "plasma-prtg", server.url, "k3y")
    serve(server, SENSORS, PROBES)
    result = run("prtgstatus", "fetch.sh", server.url)
    assert result.returncode == 0, result.stderr
    out = json.loads(result.stdout)
    assert out["root"] == ROOT and out["probes"] == PROBES and out["problems"] == SENSORS
    assert out["all"] == {"sensors": []}                      # every sensor is no longer pulled
    sent = queries(server)
    assert [q["content"] for q in sent] == [["sensors"], ["probes"], ["probes"]]
    assert sent[1]["filter_objid"] == ["0"] and sent[2]["filter_parentid"] == ["0"]
    assert "downsens" in sent[1]["columns"][0] and "partialdownsens" in sent[1]["columns"][0]
    assert all(q["apitoken"] == ["k3y"] for q in sent)


@pytest.mark.skipif(not shutil.which("curl"), reason="needs curl")
def test_problem_columns(server, stubs, run):
    secret_tool(stubs, "plasma-prtg", server.url, "k3y")
    serve(server, SENSORS, PROBES)
    run("prtgstatus", "fetch.sh", server.url, "7")
    for q in [q for q in queries(server) if q["content"] == ["sensors"]]:
        columns = q["columns"][0].split(",")
        assert {"priority", "downtimesince", "probe", "group", "status_raw"} <= set(columns)
    assert len([q for q in queries(server) if q["content"] == ["sensors"]]) == 2   # problems and extra


@pytest.mark.skipif(not shutil.which("curl"), reason="needs curl")
@pytest.mark.parametrize("root_answer", [(404, {}), (200, {"probes": []}), (200, SENSORS)])
def test_falls_back_to_counting_every_sensor(server, stubs, run, root_answer):
    secret_tool(stubs, "plasma-prtg", server.url, "k3y")
    serve(server, SENSORS, PROBES, root=root_answer[1], root_status=root_answer[0])
    result = run("prtgstatus", "fetch.sh", server.url)
    assert result.returncode == 0, result.stderr
    out = json.loads(result.stdout)
    assert out["root"] == {"probes": []}
    assert out["all"] == SENSORS
    assert any(q["count"] == ["50000"] for q in queries(server))

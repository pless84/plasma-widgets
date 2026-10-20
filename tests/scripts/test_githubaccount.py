"""GitHub Account fetch.sh: the team review filter and release page lookup (release.sh), with a stub gh CLI."""
import json

import pytest


@pytest.fixture
def gh(stubs):
    stubs.add("gh", """
case "$1 $2" in
  "api notifications") echo '[{"subject":{"type":"Release","url":"https://api.github.com/repos/o/r/releases/12"}}]' ;;
  "api graphql") echo '{"data":{}}' ;;
  "api https://api.github.com/repos/o/r/releases/12") echo https://github.com/o/r/releases/tag/v1 ;;
esac""")
    return stubs


def graphql_query(gh):
    return next(c["args"][-1] for c in gh.calls("gh") if c["args"][:2] == ["api", "graphql"])


def test_team_review_requests_counted_by_default(gh, run):
    assert run("githubaccount", "fetch.sh", "").returncode == 0
    assert "is:pr review-requested:@me" in graphql_query(gh)


def test_direct_review_requests_only(gh, run):
    assert run("githubaccount", "fetch.sh", "", "-", "direct-only").returncode == 0
    assert "user-review-requested:@me" in graphql_query(gh)


def test_fetch_does_not_look_up_releases(gh, run):
    result = run("githubaccount", "fetch.sh", "")
    assert "releases" not in json.loads(result.stdout)
    assert [c["args"][:2] for c in gh.calls("gh")] == [["api", "notifications"], ["api", "graphql"]]


def test_release_script_prints_the_release_page(gh, run):
    result = run("githubaccount", "release.sh", "", "https://api.github.com/repos/o/r/releases/12")
    assert result.stdout.strip() == "https://github.com/o/r/releases/tag/v1"


def test_release_script_rejects_other_urls(gh, run):
    result = run("githubaccount", "release.sh", "", "https://evil.example/releases/1")
    assert result.returncode != 0
    assert gh.calls("gh") == []

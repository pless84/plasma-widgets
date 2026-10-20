#!/bin/sh
# Prints {"problems": <table>, "root": <table>, "probes": <table>, "all": <table>, "extra": <table>} from PRTG's
# table API: full details for every sensor that is not Up or paused, the per-state sensor counts
# of every probe (cheap, and the source of the widget's counts), just the status of every sensor
# (only fetched when the probes table is unusable, as the old way to count), and full details
# for the sensors in the extra status codes (the other states the widget lists; an empty table
# when none are given).
# Usage: fetch.sh <server-url> [<comma-separated status codes>]
# The API key is read from the keyring. The widget's settings page saves it there,
# or it can be stored by hand with:
#   secret-tool store --label="PRTG API key" service plasma-prtg server <server-url>
# It is handed to curl on stdin so it never appears in the process list.
set -e

server=$1
extra_codes=$2
if [ -z "$server" ]; then
    echo "No PRTG server configured" >&2
    exit 2
fi

key=$(secret-tool lookup service plasma-prtg server "$server") || true
if [ -z "$key" ]; then
    echo "No API key in the keyring for $server" >&2
    exit 3
fi

fetch() {
    printf 'url = "%s/api/table.json?%s&apitoken=%s"\n' "$server" "$1" "$key" \
        | curl --silent --show-error --fail --max-time 30 --config -
}

# Status codes: 4 Warning, 5 Down, 10 Unusual, 13 Down (acknowledged), 14 Down (partial)
columns="objid,device,sensor,status,status_raw,message_raw,lastvalue,priority,downtimesince,probe,group"
problems=$(fetch "content=sensors&count=500&columns=$columns&filter_status=4&filter_status=5&filter_status=10&filter_status=13&filter_status=14")

# The counts. content=probes lists every object in the tree (root, probes, groups, devices),
# each with the sensor counts of everything below it. The root row (objid 0) holds the totals,
# and the root's children are the probes, for the per-probe lines. If PRTG doesn't answer with
# the root row, count every sensor instead.
counts="objid,probe,upsens,downsens,partialdownsens,downacksens,warnsens,unusualsens,pausedsens,undefinedsens,totalsens"
root=$(fetch "content=probes&count=1&columns=$counts&filter_objid=0" 2>/dev/null) || root=""
probes=$(fetch "content=probes&count=100&columns=$counts&filter_parentid=0" 2>/dev/null) || probes=""
case $root in
    *'"probes"'*'"objid"'*) all='{"sensors":[]}' ;;
    *) root='{"probes":[]}'; all=$(fetch "content=sensors&count=50000&columns=objid,status_raw") ;;
esac
case $probes in
    *'"probes"'*) ;;
    *) probes='{"probes":[]}' ;;
esac

extra='{"sensors":[]}'
if [ -n "$extra_codes" ]; then
    filter=""
    for code in $(echo "$extra_codes" | tr ',' ' '); do
        case $code in
            *[!0-9]*) echo "Invalid status code: $code" >&2; exit 2 ;;
        esac
        filter="$filter&filter_status=$code"
    done
    extra=$(fetch "content=sensors&count=500&columns=$columns$filter")
fi

printf '{"problems":%s,"root":%s,"probes":%s,"all":%s,"extra":%s}\n' "$problems" "$root" "$probes" "$all" "$extra"

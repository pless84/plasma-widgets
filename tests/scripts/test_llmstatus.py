"""LLM Status: gpu.sh with a stub nvidia-smi."""


def test_gpu_nvidia_reports_temperature_and_power(stubs, run):
    stubs.add("nvidia-smi", 'case "$1" in --query-compute-apps*) ;; *) echo "37, 2471, 12227, 39, 28.50, 250.00, NVIDIA GeForce RTX 5070";; esac')
    result = run("llmstatus", "gpu.sh")
    assert result.returncode == 0
    assert result.stdout == "37, 2471, 12227, 39, 28.50, 250.00, NVIDIA GeForce RTX 5070\n"
    assert stubs.calls("nvidia-smi")[0]["args"] == [
        "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,name",
        "--format=csv,noheader,nounits"]


def test_gpu_nvidia_lists_compute_processes_after_a_marker(stubs, run):
    stubs.add("nvidia-smi", 'case "$1" in --query-compute-apps*) echo "2201, /usr/bin/blender, 2048";; '
                            '*) echo "37, 2471, 12227, 39, 28, 250, GPU";; esac')
    result = run("llmstatus", "gpu.sh")
    assert result.returncode == 0
    assert result.stdout == "37, 2471, 12227, 39, 28, 250, GPU\n# apps\n2201, /usr/bin/blender, 2048\n"
    assert stubs.calls("nvidia-smi")[-1]["args"] == [
        "--query-compute-apps=pid,process_name,used_memory", "--format=csv,noheader,nounits"]


def test_gpu_nvidia_without_compute_processes_has_no_marker(stubs, run):
    stubs.add("nvidia-smi", 'case "$1" in --query-compute-apps*) ;; *) echo "37, 2471, 12227, 39, 28, 250, GPU";; esac')
    result = run("llmstatus", "gpu.sh")
    assert result.stdout == "37, 2471, 12227, 39, 28, 250, GPU\n"


def test_gpu_nvidia_failing_is_not_an_error(stubs, run):
    # e.g. the driver isn't loaded: the script falls back to AMD's counters and still succeeds.
    stubs.add("nvidia-smi", "echo 'NVIDIA-SMI has failed' >&2; exit 9")
    result = run("llmstatus", "gpu.sh")
    assert result.returncode == 0
    assert "NVIDIA-SMI has failed" not in result.stdout


def test_gpu_nvidia_old_driver_retries_the_four_field_query(stubs, run):
    # A driver that rejects the temperature and power fields still gets its load and memory read.
    stubs.add("nvidia-smi", 'case "$1" in --query-compute-apps*) ;; '
                            '*temperature*) echo "Field not valid" >&2; exit 2;; '
                            '*) echo "37, 2471, 12227, GeForce GTX 680";; esac')
    result = run("llmstatus", "gpu.sh")
    assert result.returncode == 0
    assert result.stdout == "37, 2471, 12227, GeForce GTX 680\n"
    queries = [c["args"][0] for c in stubs.calls("nvidia-smi")]
    assert queries[0].endswith("power.limit,name")
    assert queries[1] == "--query-gpu=utilization.gpu,memory.used,memory.total,name"


def test_gpu_nvidia_failing_on_both_queries_falls_through(stubs, run):
    stubs.add("nvidia-smi", "exit 9")
    result = run("llmstatus", "gpu.sh")
    assert result.returncode == 0
    assert len([c for c in stubs.calls("nvidia-smi") if c["args"][0].startswith("--query-gpu")]) == 2

"""Export BOINC client state as Prometheus metrics on LISTEN_PORT /metrics.

Reads BOINC's GUI RPC on each scrape.
`python boinc_exporter.py --once` prints the metrics once instead.
"""
import os
import socket
import sys
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOST = os.environ.get("BOINC_HOST", "127.0.0.1")
PORT = int(os.environ.get("BOINC_PORT", "31416"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9101"))

# result.state from BOINC's lib/common_defs.h
RESULT_STATES = {1: "downloading", 3: "error", 4: "uploading", 5: "done", 6: "aborted", 7: "upload failed"}
ACTIVE_TASK_EXECUTING = 1
SCHEDULER_SCHEDULED = 2

HELP = {
    "boinc_up": "Whether the BOINC client answered GUI RPC.",
    "boinc_host_cpus": "CPUs the BOINC client sees.",
    "boinc_suspend_reason": "Why BOINC is not computing (bitmask; 0 = computing).",
    "boinc_project_info": "Attached project.",
    "boinc_project_host_credit": "Total credit of this host.",
    "boinc_project_host_rac": "Recent average credit of this host.",
    "boinc_project_user_credit": "Total credit of the account.",
    "boinc_project_user_rac": "Recent average credit of the account.",
    "boinc_project_resource_share": "Resource share.",
    "boinc_project_rpc_failures": "Consecutive failed scheduler requests.",
    "boinc_project_jobs_succeeded": "Tasks completed successfully on this host.",
    "boinc_project_jobs_failed": "Tasks that failed on this host.",
    "boinc_project_last_rpc_timestamp_seconds": "Last scheduler request.",
    "boinc_project_next_rpc_timestamp_seconds": "Earliest next scheduler request (0 = no backoff).",
    "boinc_project_disk_usage_bytes": "Disk used by the project.",
    "boinc_task_info": "Task and its status.",
    "boinc_task_fraction_done": "Task progress, 0-1.",
    "boinc_task_elapsed_seconds": "Wall-clock time the task has run.",
    "boinc_task_cpu_seconds": "CPU time the task has used.",
    "boinc_task_remaining_seconds": "Estimated CPU time remaining.",
    "boinc_task_deadline_timestamp_seconds": "Report deadline.",
    "boinc_task_memory_bytes": "Task working set size.",
}


class Client:
    def __init__(self):
        self.sock = socket.create_connection((HOST, PORT), timeout=15)
        # get_state and get_cc_status are read-only: BOINC serves them to
        # local connections without the GUI RPC password.

    def rpc(self, body):
        self.sock.sendall(f"<boinc_gui_rpc_request>\n{body}\n</boinc_gui_rpc_request>\n\003".encode())
        buf = b""
        while not buf.endswith(b"\003"):
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("BOINC closed the connection")
            buf += chunk
        return ET.fromstring(buf.rstrip(b"\003"))

    def close(self):
        self.sock.close()


def num(el, tag):
    try:
        return float(el.findtext(tag) or 0)
    except ValueError:
        return 0.0


def project_label(master_url, name):
    if name:
        return name
    u = urlparse(master_url)
    return (u.netloc + u.path).rstrip("/")


def task_status(result, suspend_reason):
    state = int(num(result, "state"))
    if state != 2:
        return RESULT_STATES.get(state, "unknown")
    task = result.find("active_task")
    if task is None:
        return "waiting"
    running = (
        num(task, "active_task_state") == ACTIVE_TASK_EXECUTING
        and num(task, "scheduler_state") == SCHEDULER_SCHEDULED
        and suspend_reason == 0
    )
    return "running" if running else "paused"


def collect():
    client = Client()
    try:
        state = client.rpc("<get_state/>").find("client_state")
        suspend_reason = int(num(client.rpc("<get_cc_status/>").find("cc_status"), "task_suspend_reason"))
    finally:
        client.close()

    samples = [("boinc_up", {}, 1), ("boinc_suspend_reason", {}, suspend_reason)]
    samples.append(("boinc_host_cpus", {}, num(state.find("host_info"), "p_ncpus")))

    projects, apps, wu_app = {}, {}, {}
    current = None
    for el in state:
        if el.tag == "project":
            url = el.findtext("master_url")
            current = projects[url] = project_label(url, el.findtext("project_name"))
            p = {"project": current}
            samples += [
                ("boinc_project_info", {**p, "url": url, "user": el.findtext("user_name") or "",
                                        "team": el.findtext("team_name") or ""}, 1),
                ("boinc_project_host_credit", p, num(el, "host_total_credit")),
                ("boinc_project_host_rac", p, num(el, "host_expavg_credit")),
                ("boinc_project_user_credit", p, num(el, "user_total_credit")),
                ("boinc_project_user_rac", p, num(el, "user_expavg_credit")),
                ("boinc_project_resource_share", p, num(el, "resource_share")),
                ("boinc_project_rpc_failures", p, num(el, "nrpc_failures")),
                ("boinc_project_jobs_succeeded", p, num(el, "njobs_success")),
                ("boinc_project_jobs_failed", p, num(el, "njobs_error")),
                ("boinc_project_last_rpc_timestamp_seconds", p, num(el, "last_rpc_time")),
                ("boinc_project_next_rpc_timestamp_seconds", p, num(el, "min_rpc_time")),
                ("boinc_project_disk_usage_bytes", p, num(el, "disk_usage")),
            ]
        elif el.tag == "app":
            apps[(current, el.findtext("name"))] = el.findtext("user_friendly_name") or el.findtext("name")
        elif el.tag == "workunit":
            wu_app[el.findtext("name")] = el.findtext("app_name")

    for r in state.findall("result"):
        project = projects.get(r.findtext("project_url"), r.findtext("project_url"))
        app_name = wu_app.get(r.findtext("wu_name"), "")
        labels = {"project": project, "app": apps.get((project, app_name), app_name), "task": r.findtext("name")}
        task = r.find("active_task")
        samples += [
            ("boinc_task_info", {**labels, "status": task_status(r, suspend_reason)}, 1),
            ("boinc_task_remaining_seconds", labels, num(r, "estimated_cpu_time_remaining")),
            ("boinc_task_deadline_timestamp_seconds", labels, num(r, "report_deadline")),
        ]
        if task is not None:
            samples += [
                ("boinc_task_fraction_done", labels, num(task, "fraction_done")),
                ("boinc_task_elapsed_seconds", labels, num(task, "elapsed_time")),
                ("boinc_task_cpu_seconds", labels, num(task, "current_cpu_time")),
                ("boinc_task_memory_bytes", labels, num(task, "working_set_size_smoothed")),
            ]
    return samples


def escape(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def render(samples):
    lines, seen = [], set()
    for name in HELP:
        for metric, labels, value in samples:
            if metric != name:
                continue
            if name not in seen:
                seen.add(name)
                lines += [f"# HELP {name} {HELP[name]}", f"# TYPE {name} gauge"]
            label_str = ",".join(f'{k}="{escape(v)}"' for k, v in labels.items())
            value = repr(float(value))
            lines.append(f"{name}{{{label_str}}} {value}" if label_str else f"{name} {value}")
    return "\n".join(lines) + "\n"


def scrape():
    try:
        return render(collect())
    except Exception as e:  # BOINC restarting, wrong password, ...
        print(f"boinc_exporter: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
        return render([("boinc_up", {}, 0)])


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = scrape().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    if "--once" in sys.argv:
        sys.stdout.write(scrape())
        return
    ThreadingHTTPServer.address_family = socket.AF_INET6
    ThreadingHTTPServer(("::", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()

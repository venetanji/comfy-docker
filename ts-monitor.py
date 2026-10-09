#!/usr/bin/env python3
"""Real-time Tailscale network monitor.

Auto-discovers all running Tailscale containers plus the host Tailscale
daemon, and shows live per-instance traffic rates, connection counts and
peer status in a single terminal dashboard.

Usage:
    python3 ts-monitor.py [--interval SECONDS]

Ctrl+C to exit.
"""

import argparse
import json
import subprocess
import sys
import time
from collections import defaultdict
from datetime import datetime
from typing import Optional

from rich import box
from rich.console import Console, Group as RGroup
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

# ── Constants ─────────────────────────────────────────────────────────────────

TCP_STATES = {
    "01": "ESTAB",     "02": "SYN_SENT", "03": "SYN_RECV",
    "04": "FIN_WAIT1", "05": "FIN_WAIT2", "06": "TIME_WAIT",
    "07": "CLOSE",     "08": "CLOSE_WAIT","09": "LAST_ACK",
    "0A": "LISTEN",    "0B": "CLOSING",
}

TS_REFRESH_SECS = 8   # how often to re-query tailscale status (expensive)


# ── Discovery ─────────────────────────────────────────────────────────────────

def discover_instances() -> list[dict]:
    """Return list of instance descriptors, one per Tailscale node."""
    instances = []

    # 1. Host Tailscale daemon
    try:
        subprocess.run(["tailscale", "status"], capture_output=True, check=True, timeout=2)
        instances.append({
            "id":        "host",
            "label":     "host",
            "container": None,   # use host /proc directly
        })
    except Exception:
        pass

    # 2. Running containers with tailscale image or name
    try:
        out = subprocess.run(
            ["docker", "ps", "--format", "{{json .}}"],
            capture_output=True, text=True, timeout=5
        ).stdout
        for line in out.strip().splitlines():
            try:
                d = json.loads(line)
                name  = d.get("Names", "")
                image = d.get("Image", "")
                if "tailscale" in name.lower() or "tailscale" in image.lower():
                    instances.append({
                        "id":        name,
                        "label":     name,
                        "container": name,
                    })
            except Exception:
                continue
    except Exception:
        pass

    return instances


# ── Data collection ────────────────────────────────────────────────────────────

def _read_proc_file(container: Optional[str], path: str) -> str:
    """Read a /proc file from a container or the host."""
    if container is None:
        try:
            return open(path).read()
        except OSError:
            return ""
    try:
        return subprocess.run(
            ["docker", "exec", container, "cat", path],
            capture_output=True, text=True, timeout=2
        ).stdout
    except Exception:
        return ""


def read_net_dev(container: Optional[str]) -> dict:
    """Parse /proc/net/dev. Returns {iface: {rx_bytes, tx_bytes, rx_packets, tx_packets}}."""
    raw = _read_proc_file(container, "/proc/net/dev")
    result = {}
    for line in raw.strip().splitlines()[2:]:
        parts = line.split()
        if len(parts) >= 10:
            iface = parts[0].rstrip(":")
            try:
                result[iface] = {
                    "rx_bytes":   int(parts[1]),
                    "rx_packets": int(parts[2]),
                    "tx_bytes":   int(parts[9]),
                    "tx_packets": int(parts[10]),
                }
            except (ValueError, IndexError):
                pass
    return result


def read_connections(container: Optional[str]) -> dict:
    """Count TCP connections by state from /proc/net/tcp + tcp6."""
    counts: dict[str, int] = defaultdict(int)
    for proto in ("tcp", "tcp6"):
        raw = _read_proc_file(container, f"/proc/net/{proto}")
        for line in raw.strip().splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 4:
                state = TCP_STATES.get(parts[3].upper(), parts[3])
                counts[state] += 1
    return dict(counts)


def get_ts_status(container: Optional[str]) -> Optional[dict]:
    """Return parsed tailscale status --json, or None."""
    try:
        if container is None:
            out = subprocess.run(
                ["tailscale", "status", "--json"],
                capture_output=True, text=True, timeout=5
            ).stdout
        else:
            out = subprocess.run(
                ["docker", "exec", container, "tailscale", "status", "--json"],
                capture_output=True, text=True, timeout=5
            ).stdout
        return json.loads(out)
    except Exception:
        return None


def get_ts_self_name(status: Optional[dict]) -> str:
    if not status:
        return "?"
    self_ = status.get("Self", {})
    name = self_.get("HostName") or self_.get("DNSName", "?").split(".")[0]
    ips  = self_.get("TailscaleIPs", [])
    ip   = ips[0] if ips else "?"
    return f"{name} ({ip})"


# ── Formatting ────────────────────────────────────────────────────────────────

def fmt_rate(bps: float) -> str:
    for unit in ("B/s", "KB/s", "MB/s", "GB/s"):
        if abs(bps) < 1024:
            return f"{bps:7.1f} {unit}"
        bps /= 1024
    return f"{bps:7.1f} GB/s"


def fmt_bytes(b: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(b) < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} TB"


def rate_style(bps: float) -> str:
    if bps > 5_000_000:  return "bold bright_green"
    if bps > 500_000:    return "bright_green"
    if bps > 10_000:     return "green"
    if bps > 0:          return "dim green"
    return "dim"


# ── Table builders ────────────────────────────────────────────────────────────

def build_traffic_table(instances: list[dict],
                        prev_net: dict, curr_net: dict,
                        interval: float,
                        ts_names: dict) -> Table:
    t = Table(
        box=box.SIMPLE_HEAD,
        title="[bold cyan]Traffic (tailscale0)[/bold cyan]",
        title_justify="left", expand=True, padding=(0, 1),
    )
    t.add_column("Instance",    style="cyan",  no_wrap=True, min_width=28)
    t.add_column("TS Name",     style="yellow", no_wrap=True, min_width=22)
    t.add_column("↓ RX/s",      justify="right", min_width=13)
    t.add_column("↑ TX/s",      justify="right", min_width=13)
    t.add_column("↓ RX total",  justify="right", style="dim", min_width=10)
    t.add_column("↑ TX total",  justify="right", style="dim", min_width=10)

    for inst in instances:
        ctr = inst["container"]
        cid = inst["id"]
        c_ifaces = curr_net.get(cid, {})
        p_ifaces = prev_net.get(cid, {})

        if "tailscale0" not in c_ifaces:
            t.add_row(inst["label"], "[dim]offline[/]", "-", "-", "-", "-")
            continue

        c = c_ifaces["tailscale0"]
        p = p_ifaces.get("tailscale0", c)
        rx = max(0.0, (c["rx_bytes"] - p["rx_bytes"]) / interval)
        tx = max(0.0, (c["tx_bytes"] - p["tx_bytes"]) / interval)

        rs, ts_ = rate_style(rx), rate_style(tx)
        t.add_row(
            inst["label"],
            ts_names.get(cid, "…"),
            f"[{rs}]{fmt_rate(rx)}[/]",
            f"[{ts_}]{fmt_rate(tx)}[/]",
            fmt_bytes(c["rx_bytes"]),
            fmt_bytes(c["tx_bytes"]),
        )
    return t


def build_conn_table(instances: list[dict], connections: dict) -> Table:
    t = Table(
        box=box.SIMPLE_HEAD,
        title="[bold cyan]TCP Connections[/bold cyan]",
        title_justify="left", expand=True, padding=(0, 1),
    )
    t.add_column("Instance",    style="cyan",   no_wrap=True, min_width=28)
    t.add_column("ESTABLISHED", justify="right", min_width=13)
    t.add_column("TIME_WAIT",   justify="right", style="yellow", min_width=10)
    t.add_column("CLOSE_WAIT",  justify="right", style="yellow", min_width=10)
    t.add_column("LISTEN",      justify="right", style="blue",   min_width=7)

    for inst in instances:
        c = connections.get(inst["id"], {})
        estab = c.get("ESTAB", 0)
        t.add_row(
            inst["label"],
            f"[{'bright_green' if estab > 0 else 'dim'}]{estab}[/]",
            str(c.get("TIME_WAIT", 0)),
            str(c.get("CLOSE_WAIT", 0)),
            str(c.get("LISTEN", 0)),
        )
    return t


def build_peers_table(instances: list[dict], ts_statuses: dict) -> Table:
    t = Table(
        box=box.SIMPLE_HEAD,
        title="[bold cyan]Active Tailscale Peers[/bold cyan]",
        title_justify="left", expand=True, padding=(0, 1),
    )
    t.add_column("Instance", style="cyan",   no_wrap=True, min_width=28)
    t.add_column("Peer",     style="white",  no_wrap=True, min_width=18)
    t.add_column("IP",       style="yellow", no_wrap=True, min_width=14)
    t.add_column("Status",   no_wrap=True,   min_width=12)
    t.add_column("Relay",    style="dim",    min_width=8)

    for inst in instances:
        status = ts_statuses.get(inst["id"])
        if status is None:
            t.add_row(inst["label"], "—", "—", "[dim]no data[/]", "")
            continue

        peers = status.get("Peer", {})
        active_peers = [p for p in peers.values()
                        if p.get("Active") or p.get("Online")]
        if not active_peers:
            t.add_row(inst["label"], "[dim](no active peers)[/]", "", "", "")
            continue

        first = True
        for peer in active_peers:
            name   = peer.get("HostName", "?")
            ip     = (peer.get("TailscaleIPs") or ["?"])[0]
            active = peer.get("Active", False)
            relay  = peer.get("Relay") or "direct"
            badge  = "[bright_green]● active[/]" if active else "[green]○ online[/]"

            t.add_row(inst["label"] if first else "", name, ip, badge, relay)
            first = False
    return t


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Real-time Tailscale network monitor")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="Refresh interval in seconds (default: 2)")
    args = parser.parse_args()
    interval = args.interval

    console = Console()
    console.print("[cyan]Discovering Tailscale instances…[/cyan]")

    instances = discover_instances()
    if not instances:
        console.print("[red]No Tailscale instances found.[/red]")
        sys.exit(1)

    console.print(f"Found [green]{len(instances)}[/green] instance(s). Starting monitor…")
    time.sleep(0.5)

    # Seed initial stats
    prev_net: dict = {i["id"]: read_net_dev(i["container"]) for i in instances}
    connections: dict = {}
    ts_statuses: dict = {}
    ts_names: dict = {}
    last_ts_refresh = 0.0

    with Live(console=console, refresh_per_second=1 / interval, screen=True) as live:
        while True:
            tick = time.monotonic()

            # Network I/O
            curr_net = {i["id"]: read_net_dev(i["container"]) for i in instances}
            actual_interval = max(time.monotonic() - tick, 0.01) + interval

            # Connections
            connections = {i["id"]: read_connections(i["container"]) for i in instances}

            # Tailscale peer status (throttled)
            if time.time() - last_ts_refresh >= TS_REFRESH_SECS:
                for inst in instances:
                    st = get_ts_status(inst["container"])
                    ts_statuses[inst["id"]] = st
                    ts_names[inst["id"]] = get_ts_self_name(st)
                last_ts_refresh = time.time()

            now = datetime.now().strftime("%H:%M:%S")
            total_instances = len(instances)
            header = Text(
                f"  {total_instances} instance(s)   "
                f"interval {interval}s   "
                f"peers refreshed every {TS_REFRESH_SECS}s   "
                f"Ctrl+C to exit",
                style="dim",
            )

            display = RGroup(
                header,
                build_traffic_table(instances, prev_net, curr_net, actual_interval, ts_names),
                build_conn_table(instances, connections),
                build_peers_table(instances, ts_statuses),
            )
            live.update(Panel(
                display,
                title=f"[bold blue]Tailscale Monitor[/bold blue]   [dim]{now}[/dim]",
                border_style="blue",
            ))

            prev_net = curr_net

            elapsed = time.monotonic() - tick
            time.sleep(max(0.0, interval - elapsed))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nExiting.")
        sys.exit(0)

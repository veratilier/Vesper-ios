"""Read-only, authenticated host metrics for the Vesper Studio page."""

from __future__ import annotations

import os
import time
from pathlib import Path


def _cpu_times() -> tuple[int, int]:
    values = [int(value) for value in Path('/proc/stat').read_text().splitlines()[0].split()[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle


def _cpu_percent() -> float:
    total_before, idle_before = _cpu_times()
    time.sleep(0.15)
    total_after, idle_after = _cpu_times()
    elapsed = total_after - total_before
    return round(100 * (1 - (idle_after - idle_before) / elapsed), 1) if elapsed > 0 else 0.0


def _memory() -> dict[str, int]:
    values = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        key, _, amount = line.partition(':')
        if key in {'MemTotal', 'MemAvailable'}:
            values[key] = int(amount.strip().split()[0]) * 1024
    total = values['MemTotal']
    return {'totalBytes': total, 'usedBytes': max(0, total - values['MemAvailable'])}


def _storage() -> dict[str, int]:
    disk = os.statvfs('/')
    total = disk.f_blocks * disk.f_frsize
    available = disk.f_bavail * disk.f_frsize
    return {'totalBytes': total, 'usedBytes': max(0, total - available)}


def snapshot() -> dict:
    return {
        'observedAt': int(time.time()),
        'cpu': {'usedPercent': _cpu_percent(), 'load1': round(os.getloadavg()[0], 2),
                'logicalCores': os.cpu_count() or 1},
        'memory': _memory(),
        'storage': _storage(),
        'uptimeSeconds': int(float(Path('/proc/uptime').read_text().split()[0])),
    }


def dispatch(handler, path, services):
    if path != ['system-status']:
        return False
    if handler.command != 'GET':
        handler.send_json(405, {'error': 'Method not allowed'})
    else:
        handler.send_json(200, snapshot())
    return True

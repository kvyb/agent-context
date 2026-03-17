#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import sys
import unittest

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from mem0_common import build_memory_metadata, parse_iso, unix_timestamp
from mem0_search import build_search_filters, filter_hits_by_time


class Mem0BridgeTests(unittest.TestCase):
    def test_build_memory_metadata_flattens_filterable_fields(self) -> None:
        payload = {
            "id": "task-segment-1",
            "scope": "task_segment",
            "occurredAt": "2026-03-16T10:15:00Z",
            "appName": "Slack",
            "project": "ManyChat",
            "summary": "Blocked on ManyChat webhook regression",
            "entities": ["ManyChat", "Webhook"],
            "metadata": {
                "status": "blocked",
                "workspace": "manychat-core",
            },
        }

        metadata = build_memory_metadata(payload)

        self.assertEqual(metadata["scope"], "task_segment")
        self.assertEqual(metadata["project"], "ManyChat")
        self.assertEqual(metadata["status"], "blocked")
        self.assertEqual(metadata["workspace"], "manychat-core")
        self.assertEqual(metadata["occurred_at"], "2026-03-16T10:15:00Z")
        self.assertEqual(metadata["event_day"], "2026-03-16")
        self.assertEqual(metadata["event_timestamp"], unix_timestamp(parse_iso("2026-03-16T10:15:00Z")))
        self.assertIn("blocker", metadata["categories"])

    def test_build_search_filters_uses_explicit_time_window(self) -> None:
        start = parse_iso("2026-03-15T00:00:00Z")
        end = parse_iso("2026-03-18T00:00:00Z")

        filters = build_search_filters({"project": "ManyChat"}, start=start, end=end)

        self.assertEqual(
            filters,
            {
                "AND": [
                    {"event_timestamp": {"gte": unix_timestamp(start), "lt": unix_timestamp(end)}},
                    {"project": "ManyChat"},
                ]
            },
        )

    def test_filter_hits_by_time_drops_undated_hits_when_window_is_explicit(self) -> None:
        start = parse_iso("2026-03-15T00:00:00Z")
        end = parse_iso("2026-03-18T00:00:00Z")

        hits = [
            {
                "memory": "ManyChat work on the 16th",
                "occurred_at": "2026-03-16T08:00:00Z",
                "metadata": {},
            },
            {
                "memory": "Undated memory should not leak into explicit window queries",
                "metadata": {},
            },
        ]

        filtered = filter_hits_by_time(hits, start=start, end=end)

        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0]["memory"], "ManyChat work on the 16th")


if __name__ == "__main__":
    unittest.main()

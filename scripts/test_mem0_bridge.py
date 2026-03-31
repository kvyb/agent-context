#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import sys
import unittest
from unittest import mock

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from mem0_common import build_mem0_config, build_memory_metadata, parse_iso, unix_timestamp
from mem0_search import (
    build_search_filters,
    call_get_all,
    corpus_candidate_limit,
    expand_day_filters,
    filter_hits_by_time,
    rerank_candidate_limit,
    semantic_candidate_limit,
    should_use_rerank,
)


class Mem0BridgeTests(unittest.TestCase):
    def test_build_mem0_config_adds_llm_reranker_defaults(self) -> None:
        with mock.patch.dict(
            "os.environ",
            {
                "OPENROUTER_API_KEY": "test-key",
                "AGENT_CONTEXT_MEM0_LLM_MODEL": "google/gemini-3.1-flash-lite-preview",
            },
            clear=False,
        ):
            config = build_mem0_config()

        self.assertEqual(config["reranker"]["provider"], "llm_reranker")
        self.assertEqual(config["reranker"]["config"]["provider"], "openai")
        self.assertEqual(config["reranker"]["config"]["temperature"], 0.0)
        self.assertEqual(config["reranker"]["config"]["top_k"], 6)
        self.assertEqual(config["reranker"]["config"]["max_tokens"], 16)
        self.assertIn("Score how useful this memory is", config["reranker"]["config"]["scoring_prompt"])

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

    def test_build_search_filters_keeps_only_exact_mem0_side_filters(self) -> None:
        start = parse_iso("2026-03-15T00:00:00Z")
        end = parse_iso("2026-03-18T00:00:00Z")

        filters = build_search_filters({"project": "ManyChat"}, start=start, end=end)

        self.assertEqual(filters, {"project": "ManyChat"})

    def test_expand_day_filters_adds_exact_event_days_for_short_windows(self) -> None:
        start = parse_iso("2026-03-15T00:00:00Z")
        end = parse_iso("2026-03-17T00:00:00Z")

        variants = expand_day_filters({"project": "ManyChat"}, start=start, end=end)

        self.assertEqual(
            variants,
            [
                {"project": "ManyChat", "event_day": "2026-03-15"},
                {"project": "ManyChat", "event_day": "2026-03-16"},
            ],
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

    def test_filter_hits_by_time_prefers_event_time_over_mem0_created_at(self) -> None:
        start = parse_iso("2026-03-29T16:00:00Z")
        end = parse_iso("2026-03-30T16:00:00Z")

        hits = [
            {
                "memory": "Zoom meeting on March 30",
                "created_at": "2026-03-31T03:13:28.087360-07:00",
                "metadata": {
                    "occurred_at": "2026-03-30T11:18:14.624446Z",
                    "app_name": "zoom.us",
                },
            }
        ]

        filtered = filter_hits_by_time(hits, start=start, end=end)

        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0]["memory"], "Zoom meeting on March 30")

    def test_rerank_candidate_limit_keeps_llm_pool_small(self) -> None:
        self.assertEqual(rerank_candidate_limit(3), 6)
        self.assertEqual(rerank_candidate_limit(5), 7)
        self.assertEqual(rerank_candidate_limit(10), 8)

    def test_candidate_limits_expand_scope_queries_without_exploding(self) -> None:
        self.assertEqual(semantic_candidate_limit(5), 12)
        self.assertEqual(semantic_candidate_limit(20), 24)
        self.assertEqual(corpus_candidate_limit(3), 36)
        self.assertEqual(corpus_candidate_limit(20), 100)

    def test_rerank_is_disabled_for_wide_multi_query_batches(self) -> None:
        self.assertTrue(should_use_rerank({"queries": ["manychat blockers"]}, 8))
        self.assertFalse(should_use_rerank({"queries": ["q1", "q2", "q3"]}, 8))

    def test_rerank_is_disabled_when_timeout_budget_is_tight(self) -> None:
        self.assertFalse(should_use_rerank({"queries": ["manychat blockers"], "timeout_seconds": 6}, 8))
        self.assertTrue(should_use_rerank({"queries": ["manychat blockers"], "timeout_seconds": 20}, 8))

    def test_call_get_all_reads_scoped_corpus(self) -> None:
        memory = mock.Mock()
        memory.get_all.side_effect = [
            {
                "results": [
                    {"memory": "Worked on playbox-platform in Warp"},
                    {"memory": "Zoom call about asset updates"},
                ]
            },
            {"results": []},
            {"results": []},
        ]

        rows = call_get_all(
            memory,
            user_id="agent-context-user",
            agent_id="agent-context-tracker",
            limit=20,
            filters={"scope": "asset_analysis"},
        )

        self.assertEqual(len(rows), 2)
        self.assertGreaterEqual(memory.get_all.call_count, 1)

    def test_scoped_query_should_fall_back_to_search_when_get_all_is_empty(self) -> None:
        memory = mock.Mock()
        memory.get_all.return_value = {"results": []}
        memory.search.side_effect = [
            {
                "results": [
                    {
                        "id": "zoom-1",
                        "memory": "Zoom meeting about feedback loop and Wednesday follow-up",
                        "metadata": {"occurred_at": "2026-03-30T11:00:00Z", "app_name": "zoom.us"},
                    }
                ]
            }
        ]

        payload = {
            "queries": ["What were the calls yesterday about?"],
            "start": "2026-03-29T16:00:00Z",
            "end": "2026-03-30T16:00:00Z",
            "timeout_seconds": 0,
        }
        filters = build_search_filters(payload, start=parse_iso(payload["start"]), end=parse_iso(payload["end"]))

        collected = []
        for variant in expand_day_filters(filters, start=parse_iso(payload["start"]), end=parse_iso(payload["end"])):
            collected.extend(
                call_get_all(
                    memory,
                    user_id="about-time-user",
                    agent_id="about-time-tracker",
                    limit=corpus_candidate_limit(24),
                    filters=variant,
                )
            )

        if not collected:
            rows = []
            for query in payload["queries"]:
                rows.extend(
                    memory.search(
                        query=query,
                        user_id="about-time-user",
                        agent_id="about-time-tracker",
                        limit=corpus_candidate_limit(24),
                    )["results"]
                )
            collected = rows

        filtered = filter_hits_by_time(collected, start=parse_iso(payload["start"]), end=parse_iso(payload["end"]))
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0]["memory"], "Zoom meeting about feedback loop and Wednesday follow-up")


if __name__ == "__main__":
    unittest.main()

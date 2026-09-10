#!/usr/bin/env python3
"""Normalize and compare CI and local timing observations."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from statistics import median
from typing import Any

SCHEMA_VERSION = 1
CI_SOURCE = "github-actions"
LOCAL_SOURCE = "local"
LOCAL_STATUSES = {"success", "failed", "cancelled", "timed_out"}
MAX_TEXT_LENGTH = 1000

_CI_CONTEXT_FIELDS = (
    "repository",
    "workflow",
    "workflow_id",
    "event",
    "event_class",
    "workload_label",
    "validation_contract",
    "runner_toolchain",
    "cache_state",
)
_COMPARISON_CONTEXT_FIELDS = ("environment", "cache_state", "local_command")
_RECONSTRUCTION_LABELS = (
    ("collection.run_id", "observation.provenance.run_id"),
    ("collection.attempt", "observation.provenance.attempt"),
    ("job page total_count", "observation.provenance.total_count"),
    ("collection.captured_at", "observation.provenance.captured_at"),
    ("run.conclusion", "observation.conclusion"),
)


class InputError(ValueError):
    """Input does not satisfy the measurement contract."""


class ExecutionError(RuntimeError):
    """A file operation required to complete the command failed."""


@dataclass(frozen=True)
class _Variants:
    context: int = 1
    jobset: int = 1
    workflow: int = 1


def _object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InputError(f"{label} must be an object")
    return value


def _string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise InputError(f"{label} must be a non-empty string")
    return value


def _integer(value: Any, label: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise InputError(f"{label} must be an integer")
    if positive and value <= 0:
        raise InputError(f"{label} must be positive")
    return value


def _schema_version(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value != SCHEMA_VERSION:
        raise InputError(f"unsupported {label}")
    return value


def _number(value: Any, label: str, *, allow_none: bool = False) -> float | None:
    if value is None and allow_none:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InputError(f"{label} must be a finite number")
    try:
        number = float(value)
    except OverflowError as exc:
        raise InputError(f"{label} must be a finite number") from exc
    if not math.isfinite(number) or number < 0:
        raise InputError(f"{label} must be a finite non-negative number")
    return number


def _boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise InputError(f"{label} must be a boolean")
    return value


def _timestamp(value: Any, label: str) -> datetime:
    text = _string(value, label)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise InputError(f"{label} must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise InputError(f"{label} must include a timezone")
    return parsed


def _seconds(start: datetime, end: datetime, label: str) -> float:
    value = (end - start).total_seconds()
    if value < 0 or not math.isfinite(value):
        raise InputError(f"{label} has a reversed interval")
    return value


def _ids(value: Any, label: str) -> list[int]:
    if not isinstance(value, list):
        raise InputError(f"{label} must be a list")
    result = [_integer(item, f"{label} item", positive=True) for item in value]
    if len(result) != len(set(result)):
        raise InputError(f"{label} contains duplicate IDs")
    return result


def _schema(value: Any, source: str) -> dict[str, Any]:
    data = _object(value, "input")
    _schema_version(data.get("schema_version"), "schema_version")
    if data.get("source") != source:
        raise InputError(f"source must be {source}")
    return data


def _safe_text(value: Any, label: str) -> str:
    text = _string(value, label)
    if len(text) > MAX_TEXT_LENGTH:
        raise InputError(f"{label} is too long")
    return text


def _ci_context(context: Any) -> dict[str, Any]:
    context = _object(context, "context")
    result: dict[str, Any] = {}
    for key in _CI_CONTEXT_FIELDS:
        if key in context:
            value = context[key]
            if (
                key == "workflow_id"
                and isinstance(value, int)
                and not isinstance(value, bool)
            ):
                value = str(value)
            result[key] = _safe_text(value, f"context.{key}")
    for key in ("repository", "workload_label", "validation_contract"):
        if key not in result:
            raise InputError(f"context.{key} is required")
    return result


def _local_context(data: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key in ("command", "revision", "environment", "cache_state", "workload_label"):
        result[key] = _safe_text(data.get(key), key)
    benchmark = _object(data.get("benchmark_source"), "benchmark_source")
    benchmark_source = {
        "tool": _safe_text(benchmark.get("tool"), "benchmark_source.tool"),
        "evidence_file": _safe_text(
            benchmark.get("evidence_file"), "benchmark_source.evidence_file"
        ),
    }
    if benchmark.get("version") is not None:
        benchmark_source["version"] = _safe_text(
            benchmark["version"], "benchmark_source.version"
        )
    result["benchmark_source"] = benchmark_source
    if data.get("captured_at") is not None:
        result["captured_at"] = _timestamp(
            data["captured_at"], "captured_at"
        ).isoformat()
    return result


def _job_summary(
    job: dict[str, Any], selected: bool
) -> tuple[dict[str, Any], datetime | None, datetime | None]:
    job_id = _integer(job.get("id"), "job.id", positive=True)
    summary: dict[str, Any] = {
        "id": job_id,
        "name": _safe_text(job.get("name", str(job_id)), "job.name"),
        "status": _safe_text(job.get("status"), "job.status"),
        "conclusion": job.get("conclusion"),
        "selected": selected,
    }
    if summary["conclusion"] is not None:
        summary["conclusion"] = _safe_text(summary["conclusion"], "job.conclusion")
    started = (
        _timestamp(job["started_at"], "job.started_at")
        if job.get("started_at") is not None
        else None
    )
    completed = (
        _timestamp(job["completed_at"], "job.completed_at")
        if job.get("completed_at") is not None
        else None
    )
    summary["started_at"] = job.get("started_at")
    summary["completed_at"] = job.get("completed_at")
    summary["duration_seconds"] = (
        _seconds(started, completed, "job interval")
        if started is not None and completed is not None
        else None
    )
    return summary, started, completed


def _collect_jobs(
    pages: Any, run_id: int, attempt: int
) -> tuple[dict[int, dict[str, Any]], int]:
    if not isinstance(pages, list) or not pages:
        raise InputError("job_pages must be a non-empty list")
    jobs: dict[int, dict[str, Any]] = {}
    total_counts: set[int] = set()
    for page_number, page in enumerate(pages, 1):
        page = _object(page, f"job_pages[{page_number}]")
        total = _integer(page.get("total_count"), "job page total_count")
        if total < 0:
            raise InputError("job page total_count must be non-negative")
        total_counts.add(total)
        page_jobs = page.get("jobs")
        if not isinstance(page_jobs, list):
            raise InputError("job page jobs must be a list")
        for job in page_jobs:
            job = _object(job, "job")
            job_id = _integer(job.get("id"), "job.id", positive=True)
            if job.get("run_id") is not None and job.get("run_id") != run_id:
                raise InputError("job.run_id does not match run identity")
            if job.get("run_attempt") is not None and job.get("run_attempt") != attempt:
                raise InputError("job.run_attempt does not match run identity")
            if job_id in jobs:
                raise InputError("duplicate job ID")
            jobs[job_id] = job
    if len(total_counts) > 1:
        raise InputError("job page totals conflict")
    return jobs, total_counts.pop()


def _eligibility_reasons(
    created: datetime,
    job_times: dict[int, tuple[datetime | None, datetime | None]],
    selected_ids: list[int],
    selected_jobs: list[dict[str, Any]],
    status: str,
    conclusion: str | None,
    attempt: int,
    reasons: list[str],
) -> tuple[list[datetime], list[datetime]]:
    complete_times: list[datetime] = []
    selected_started: list[datetime] = []
    for job in selected_jobs:
        job_status = _safe_text(job.get("status"), "job.status")
        job_conclusion = job.get("conclusion")
        if job_status != "completed" or job_conclusion != "success":
            reasons.append(f"selected_job_{job.get('id')}_not_successful")
        started, completed = job_times[job["id"]]
        if completed is None:
            reasons.append(f"selected_job_{job.get('id')}_missing_completion")
        else:
            _seconds(created, completed, "full wait")
            complete_times.append(completed)
        if started is not None:
            selected_started.append(started)
    if not selected_ids:
        reasons.append("no_selected_jobs")
    if not selected_jobs:
        reasons.append("selected_jobs_unavailable")
    if status != "completed" or conclusion != "success":
        reasons.append(f"run_{status}_{conclusion or 'no_conclusion'}")
    if attempt > 1:
        reasons.append("rerun_no_creation_anchor")
    return complete_times, selected_started


def _ci_observation(capture: Any) -> dict[str, Any]:
    capture = _object(capture, "capture")
    context = _ci_context(capture.get("context"))
    run = _object(capture.get("run"), "capture.run")
    run_id = _integer(run.get("id"), "run.id", positive=True)
    attempt = _integer(run.get("run_attempt"), "run.run_attempt", positive=True)
    workflow_id = _integer(run.get("workflow_id"), "run.workflow_id", positive=True)
    created = _timestamp(run.get("created_at"), "run.created_at")
    status = _safe_text(run.get("status"), "run.status")
    conclusion = run.get("conclusion")
    if conclusion is not None:
        conclusion = _safe_text(conclusion, "run.conclusion")

    if context.get("workflow_id") is not None and context["workflow_id"] != str(
        workflow_id
    ):
        raise InputError("context.workflow_id does not match run.workflow_id")
    if context.get("event") is not None and context["event"] != run.get("event"):
        raise InputError("context.event does not match run.event")
    if context.get("event_class") is not None and context["event_class"] != run.get(
        "event"
    ):
        raise InputError("context.event_class does not match run.event")

    collection = _object(capture.get("collection"), "collection")
    requested_value = collection.get("run_id")
    requested = _integer(requested_value, "collection.run_id", positive=True)
    requested_attempt = _integer(
        collection.get("attempt"), "collection.attempt", positive=True
    )
    if requested != run_id or requested_attempt != attempt:
        raise InputError("collection request does not match run identity")
    selected_ids = _ids(collection.get("selected_job_ids"), "selected_job_ids")
    expected_ids = _ids(collection.get("expected_job_ids"), "expected_job_ids")
    if not set(selected_ids).issubset(expected_ids):
        raise InputError("selected_job_ids must be a subset of expected_job_ids")
    captured = _timestamp(collection.get("captured_at"), "collection.captured_at")
    _seconds(created, captured, "capture interval")

    jobs, expected_total = _collect_jobs(capture.get("job_pages"), run_id, attempt)
    reasons: list[str] = []
    if expected_total < len(jobs):
        reasons.append("inconsistent_job_population")
    elif expected_total != len(jobs):
        reasons.append("incomplete_job_pages")
    missing_expected = [job_id for job_id in expected_ids if job_id not in jobs]
    if missing_expected:
        reasons.append("missing_expected_jobs")
    selected_id_set = set(selected_ids)
    selected_jobs = [jobs[job_id] for job_id in selected_ids if job_id in jobs]
    summaries: list[dict[str, Any]] = []
    job_times: dict[int, tuple[datetime | None, datetime | None]] = {}
    for job_id, job in jobs.items():
        summary, started, completed = _job_summary(job, job_id in selected_id_set)
        summaries.append(summary)
        job_times[job_id] = (started, completed)
        if started is not None:
            _seconds(created, started, "job after creation")
        if completed is not None:
            _seconds(created, completed, "job after creation")
            _seconds(completed, captured, "job before capture")
    complete_times, selected_started = _eligibility_reasons(
        created,
        job_times,
        selected_ids,
        selected_jobs,
        status,
        conclusion,
        attempt,
        reasons,
    )
    selected_completed = max(complete_times) if complete_times else None
    eligible = not reasons and selected_completed is not None
    duration = _seconds(created, selected_completed, "full wait") if eligible else None
    pre_start = (
        _seconds(created, min(selected_started), "pre-start interval")
        if selected_started
        else None
    )
    identity = {
        "run_id": run_id,
        "run_attempt": attempt,
        "workflow_id": workflow_id,
        "head_sha": _safe_text(run.get("head_sha"), "run.head_sha"),
        "event": _safe_text(run.get("event"), "run.event"),
    }
    return {
        "identity": identity,
        "context": context,
        "status": status,
        "conclusion": conclusion,
        "created_at": created.isoformat(),
        "selected_completed_at": (
            selected_completed.isoformat() if selected_completed else None
        ),
        "duration_seconds": duration,
        "eligibility": eligible,
        "reasons": sorted(reasons),
        "pre_start_seconds": pre_start,
        "jobs": sorted(summaries, key=lambda summary: summary["id"]),
        "selected_job_names": sorted(
            summary["name"] for summary in summaries if summary["selected"]
        ),
        "provenance": {
            "run_id": requested,
            "selected_job_ids": selected_ids,
            "expected_job_ids": expected_ids,
            "total_count": expected_total,
            "attempt": requested_attempt,
            "captured_at": collection["captured_at"],
        },
    }


def _normalize_ci(value: Any) -> dict[str, Any]:
    data = _schema(value, CI_SOURCE)
    captures = data.get("captures")
    if not isinstance(captures, list) or not captures:
        raise InputError("captures must be a non-empty list")
    observations = []
    identities: set[tuple[int, int]] = set()
    for index, capture in enumerate(captures):
        try:
            observation = _ci_observation(capture)
            identity = observation["identity"]
            key = (identity["run_id"], identity["run_attempt"])
            if key in identities:
                raise InputError("duplicate run_id/run_attempt pair")
            identities.add(key)
        except InputError as exc:
            raise InputError(f"captures[{index}]: {exc}") from exc
        observations.append(observation)
    contexts = {json.dumps(item["context"], sort_keys=True) for item in observations}
    return {
        "schema_version": SCHEMA_VERSION,
        "source": CI_SOURCE,
        "context": observations[0]["context"],
        "context_variants": len(contexts),
        "observations": observations,
        "exclusions": [
            {"identity": item["identity"], "reasons": item["reasons"]}
            for item in observations
            if not item["eligibility"]
        ],
    }


def _local_observation(sample: Any, benchmark: dict[str, str]) -> dict[str, Any]:
    sample = _object(sample, "sample")
    sample_id = _safe_text(sample.get("id"), "sample.id")
    status = _safe_text(sample.get("status"), "sample.status")
    if status not in LOCAL_STATUSES:
        raise InputError(f"unknown sample status: {status}")
    duration = _number(
        sample.get("duration_seconds"), "sample.duration_seconds", allow_none=True
    )
    exit_code = sample.get("exit_code")
    if exit_code is not None:
        exit_code = _integer(exit_code, "sample.exit_code")
    warmup = _boolean(sample.get("warmup"), "sample.warmup")
    reasons: list[str] = []
    if status == "success":
        if exit_code != 0:
            raise InputError("successful sample requires exit_code 0")
        if duration is None:
            raise InputError("successful sample requires duration_seconds")
    elif status == "failed":
        if exit_code is None or exit_code == 0:
            raise InputError("failed sample requires a nonzero exit_code")
        reasons.append("failed")
    elif status in {"cancelled", "timed_out"}:
        if exit_code == 0:
            raise InputError(f"{status} sample cannot have exit_code 0")
        reasons.append(status)
    else:
        raise InputError(f"unhandled sample status: {status}")
    if warmup:
        reasons.append("warmup")
    eligible = status == "success" and not warmup
    return {
        "identity": {"id": sample_id},
        "duration_seconds": duration,
        "eligibility": eligible,
        "reasons": reasons,
        "status": status,
        "exit_code": exit_code,
        "warmup": warmup,
        "provenance": benchmark,
    }


def _normalize_local(value: Any) -> dict[str, Any]:
    data = _schema(value, LOCAL_SOURCE)
    samples = data.get("samples")
    if not isinstance(samples, list) or not samples:
        raise InputError("samples must be a non-empty list")
    context = _local_context(data)
    observations = []
    identities: set[str] = set()
    for sample in samples:
        observation = _local_observation(sample, context["benchmark_source"])
        sample_id = observation["identity"]["id"]
        if sample_id in identities:
            raise InputError("duplicate sample id")
        identities.add(sample_id)
        observations.append(observation)
    return {
        "schema_version": SCHEMA_VERSION,
        "source": LOCAL_SOURCE,
        "context": context,
        "observations": observations,
        "exclusions": [
            {"identity": item["identity"], "reasons": item["reasons"]}
            for item in observations
            if not item["eligibility"]
        ],
    }


def _relabel_reconstruction_error(exc: InputError) -> InputError:
    message = str(exc)
    for old, new in _RECONSTRUCTION_LABELS:
        message = message.replace(old, new)
    return InputError(message)


def _check_ci_observation(
    item: dict[str, Any],
    identity: dict[str, Any],
    duration: float | None,
    eligible: bool,
    seen: set[tuple[str, str]],
    ci_contexts: set[str],
    ci_jobsets: set[str],
    ci_workflows: set[tuple[int, str]],
) -> dict[str, Any]:
    observation_context = _ci_context(item.get("context"))
    ci_contexts.add(json.dumps(observation_context, sort_keys=True))
    if not isinstance(item.get("selected_job_names"), list):
        raise InputError("CI observation selected_job_names must be a list")
    selected_names = item["selected_job_names"]
    if any(not isinstance(name, str) or not name for name in selected_names):
        raise InputError("CI observation selected_job_names must be a string list")
    ci_jobsets.add(json.dumps(sorted(selected_names)))
    run_id = _integer(
        identity.get("run_id"), "observation.identity.run_id", positive=True
    )
    run_attempt = _integer(
        identity.get("run_attempt"),
        "observation.identity.run_attempt",
        positive=True,
    )
    semantic_key = ("ci", f"{run_id}:{run_attempt}")
    if semantic_key in seen:
        raise InputError("duplicate CI run_id/run_attempt identity")
    seen.add(semantic_key)
    _integer(
        identity.get("workflow_id"),
        "observation.identity.workflow_id",
        positive=True,
    )
    _safe_text(identity.get("head_sha"), "observation.identity.head_sha")
    event = _safe_text(identity.get("event"), "observation.identity.event")
    ci_workflows.add((identity["workflow_id"], event))
    if not isinstance(item.get("jobs"), list):
        raise InputError("CI observation jobs must be a list")
    _timestamp(item.get("created_at"), "observation.created_at")
    completed = item.get("selected_completed_at")
    if completed is not None:
        _timestamp(completed, "observation.selected_completed_at")
    if eligible and completed is None:
        raise InputError("eligible CI observation requires completion")

    provenance = _object(item.get("provenance"), "observation.provenance")
    status = _safe_text(item.get("status"), "observation.status")
    try:
        rebuilt = _ci_observation(
            {
                "context": item["context"],
                "run": {
                    "id": identity["run_id"],
                    "run_attempt": identity["run_attempt"],
                    "workflow_id": identity["workflow_id"],
                    "head_sha": identity["head_sha"],
                    "event": identity["event"],
                    "created_at": item["created_at"],
                    "status": status,
                    "conclusion": item.get("conclusion"),
                },
                "job_pages": [
                    {
                        "total_count": provenance.get("total_count"),
                        "jobs": item["jobs"],
                    }
                ],
                "collection": provenance,
            }
        )
    except InputError as exc:
        raise _relabel_reconstruction_error(exc) from exc
    for field in (
        "eligibility",
        "reasons",
        "duration_seconds",
        "selected_completed_at",
        "pre_start_seconds",
        "selected_job_names",
        "jobs",
    ):
        if item.get(field) != rebuilt[field]:
            raise InputError(f"CI {field} does not match capture evidence")
    return item | {"duration_seconds": duration}


def _check_local_observation(
    item: dict[str, Any],
    identity: dict[str, Any],
    context: dict[str, Any],
    duration: float | None,
    seen: set[tuple[str, str]],
) -> dict[str, Any]:
    sample_id = _string(identity.get("id"), "observation.identity.id")
    semantic_key = ("local", sample_id)
    if semantic_key in seen:
        raise InputError("duplicate local observation id")
    seen.add(semantic_key)
    rebuilt = _local_observation(
        item | {"id": identity["id"]}, context["benchmark_source"]
    )
    for field in ("eligibility", "reasons", "duration_seconds", "provenance"):
        if item.get(field) != rebuilt[field]:
            raise InputError(f"local {field} does not match sample evidence")
    return item | {"duration_seconds": duration}


def _dataset_context(data: dict[str, Any], source: str) -> dict[str, Any]:
    if source == CI_SOURCE:
        return _ci_context(data.get("context"))
    return _local_context(_object(data.get("context"), "context"))


def _validate_normalized(value: Any) -> tuple[dict[str, Any], _Variants]:
    data = _object(value, "dataset")
    source = _string(data.get("source"), "dataset.source")
    if source not in {CI_SOURCE, LOCAL_SOURCE}:
        raise InputError("dataset source is invalid")
    _schema_version(data.get("schema_version"), "dataset schema_version")
    context = _dataset_context(data, source)
    observations = data.get("observations")
    if not isinstance(observations, list):
        raise InputError("dataset observations must be a list")
    exclusions = data.get("exclusions")
    if not isinstance(exclusions, list):
        raise InputError("dataset exclusions must be a list")
    seen: set[tuple[str, str]] = set()
    checked: list[dict[str, Any]] = []
    ci_contexts: set[str] = set()
    ci_jobsets: set[str] = set()
    ci_workflows: set[tuple[int, str]] = set()
    for index, item_value in enumerate(observations):
        try:
            item = _object(item_value, "observation")
            identity = _object(item.get("identity"), "observation.identity")
            duration = _number(
                item.get("duration_seconds"),
                "observation.duration_seconds",
                allow_none=True,
            )
            eligible = _boolean(item.get("eligibility"), "observation.eligibility")
            reasons = item.get("reasons")
            if not isinstance(reasons, list) or any(
                not isinstance(reason, str) for reason in reasons
            ):
                raise InputError("observation.reasons must be a string list")
            if eligible and (duration is None or reasons):
                raise InputError(
                    "eligible observation requires a duration and no reasons"
                )
            if not eligible and not reasons:
                raise InputError("excluded observation requires a reason")
            if source == CI_SOURCE:
                checked_item = _check_ci_observation(
                    item,
                    identity,
                    duration,
                    eligible,
                    seen,
                    ci_contexts,
                    ci_jobsets,
                    ci_workflows,
                )
            else:
                checked_item = _check_local_observation(
                    item, identity, context, duration, seen
                )
        except InputError as exc:
            raise InputError(f"observations[{index}]: {exc}") from exc
        checked.append(checked_item)
    expected_exclusions = [
        {"identity": item["identity"], "reasons": item["reasons"]}
        for item in checked
        if not item["eligibility"]
    ]
    if exclusions != expected_exclusions:
        raise InputError("dataset exclusions do not match observations")
    if source == CI_SOURCE:
        if not checked:
            raise InputError("CI dataset must contain observations")
        actual_context_variants = len(ci_contexts)
        declared = data.get("context_variants")
        if not isinstance(declared, int) or isinstance(declared, bool):
            raise InputError("context_variants must be an integer")
        if declared != actual_context_variants:
            raise InputError("context_variants does not match observations")
        if context != _ci_context(checked[0]["context"]):
            raise InputError("dataset context does not match first observation")
        normalized = {
            "schema_version": SCHEMA_VERSION,
            "source": source,
            "context": context,
            "context_variants": actual_context_variants,
            "observations": checked,
            "exclusions": exclusions,
        }
        return normalized, _Variants(
            context=actual_context_variants,
            jobset=len(ci_jobsets),
            workflow=len(ci_workflows),
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "source": source,
        "context": context,
        "observations": checked,
        "exclusions": exclusions,
    }, _Variants()


def _side(data: dict[str, Any]) -> dict[str, Any]:
    values = [
        float(item["duration_seconds"])
        for item in data["observations"]
        if item["eligibility"]
    ]
    return {
        "eligible_count": len(values),
        "excluded_count": len(data["observations"]) - len(values),
        # Decimal avoids float median overflowing to inf on huge finite values,
        # which json.dumps(allow_nan=False) would then reject.
        "median_seconds": float(median([Decimal(str(value)) for value in values]))
        if values
        else None,
        "min_seconds": min(values) if values else None,
        "max_seconds": max(values) if values else None,
    }


def _side_provenance(data: dict[str, Any]) -> dict[str, Any]:
    context = data["context"]
    if data["source"] == CI_SOURCE:
        first = data["observations"][0]["identity"]
        return {
            "repository": context["repository"],
            "workflow_id": first["workflow_id"],
            "event": first["event"],
            "runs": [
                {
                    "run_id": item["identity"]["run_id"],
                    "run_attempt": item["identity"]["run_attempt"],
                    "head_sha": item["identity"]["head_sha"],
                }
                for item in data["observations"]
                if item["eligibility"]
            ],
        }
    return {
        "revision": context.get("revision"),
        "command": context.get("command"),
        "benchmark_source": context["benchmark_source"],
    }


def _comparison_context(data: dict[str, Any], variants: _Variants) -> dict[str, Any]:
    context = data["context"]
    if data["source"] == CI_SOURCE:
        observations = data["observations"]
        first = observations[0]["identity"]
        return {
            "repository": context["repository"],
            "workflow_id": first["workflow_id"] if variants.workflow == 1 else None,
            "event_class": first["event"] if variants.workflow == 1 else None,
            "workload_label": context["workload_label"],
            "validation_contract": context["validation_contract"],
            "environment": context.get("runner_toolchain"),
            "cache_state": context.get("cache_state"),
            "selected_job_names": sorted(observations[0].get("selected_job_names", []))
            if variants.jobset == 1
            else None,
        }
    return {
        "workload_label": context["workload_label"],
        "environment": context["environment"],
        "cache_state": context["cache_state"],
        "local_command": context["command"],
    }


def _acknowledge(
    ack: Any, differences: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if ack is None:
        return [], list(differences)
    ack = _object(ack, "acknowledgements")
    _schema_version(ack.get("schema_version"), "acknowledgement schema_version")
    _safe_text(ack.get("plan_ref"), "acknowledgements.plan_ref")
    entries = ack.get("differences")
    if not isinstance(entries, list):
        raise InputError("acknowledgements.differences must be a list")
    allowed = {"environment", "cache_state", "local command"}
    acknowledged_triples: set[tuple[str, str, str]] = set()
    for entry in entries:
        entry = _object(entry, "acknowledgement difference")
        field = _safe_text(entry.get("field"), "acknowledgement field")
        if field not in allowed:
            raise InputError("acknowledgement field is not allowed")
        triple = (
            field,
            json.dumps(entry.get("before"), sort_keys=True),
            json.dumps(entry.get("after"), sort_keys=True),
        )
        if triple in acknowledged_triples:
            raise InputError("duplicate acknowledgement difference")
        acknowledged_triples.add(triple)
    expected = {
        (
            item["field"],
            json.dumps(item["before"], sort_keys=True),
            json.dumps(item["after"], sort_keys=True),
        ): item
        for item in differences
    }
    if not acknowledged_triples.issubset(expected.keys()):
        raise InputError("acknowledgement does not match observed differences")
    acknowledged = [
        item for triple, item in expected.items() if triple in acknowledged_triples
    ]
    unacknowledged = [
        item for triple, item in expected.items() if triple not in acknowledged_triples
    ]
    return acknowledged, unacknowledged


def _unknown(value: Any) -> bool:
    return value is None or (
        isinstance(value, str) and value.strip().casefold() in {"", "unknown"}
    )


def _compare_datasets(
    before: dict[str, Any],
    before_variants: _Variants,
    after: dict[str, Any],
    after_variants: _Variants,
    minimum_samples: int,
    ack: Any = None,
) -> dict[str, Any]:
    minimum_samples = _integer(minimum_samples, "minimum_samples", positive=True)
    reasons: list[str] = []
    if before["source"] != after["source"]:
        reasons.append("measurement_sources_differ")
    for kind in ("context", "workflow", "jobset"):
        for side_name, variants in (
            ("before", before_variants),
            ("after", after_variants),
        ):
            if getattr(variants, kind) > 1:
                reasons.append(f"{side_name}_mixed_{kind}")
    before_context = _comparison_context(before, before_variants)
    after_context = _comparison_context(after, after_variants)
    fields = (
        (
            "repository",
            "workflow_id",
            "event_class",
            "workload_label",
            "validation_contract",
            "selected_job_names",
        )
        if before["source"] == CI_SOURCE
        else ("workload_label",)
    )
    for field in fields:
        if _unknown(before_context.get(field)) or _unknown(after_context.get(field)):
            reasons.append(f"context_{field}_unknown")
        elif before_context.get(field) != after_context.get(field):
            reasons.append(f"context_{field}_differs")
    differences = [
        {
            "field": "local command" if field == "local_command" else field,
            "before": before_context.get(field),
            "after": after_context.get(field),
        }
        for field in _COMPARISON_CONTEXT_FIELDS
        if before_context.get(field) != after_context.get(field)
    ]
    unknown_fields = (
        _COMPARISON_CONTEXT_FIELDS
        if before["source"] == LOCAL_SOURCE
        else _COMPARISON_CONTEXT_FIELDS[:2]
    )
    unknown_context = [
        field
        for field in unknown_fields
        if _unknown(before_context.get(field)) or _unknown(after_context.get(field))
    ]
    if unknown_context:
        reasons.append("comparison_context_unknown")
    acknowledged, unacknowledged = _acknowledge(ack, differences)
    if unacknowledged:
        reasons.append("context_differences_not_acknowledged")
    before_side = _side(before)
    after_side = _side(after)
    if before_side["eligible_count"] < minimum_samples:
        reasons.append("before_insufficient_samples")
    if after_side["eligible_count"] < minimum_samples:
        reasons.append("after_insufficient_samples")
    comparable = not reasons
    saved = None
    percent = None
    direction = "unavailable"
    if comparable:
        saved = before_side["median_seconds"] - after_side["median_seconds"]
        direction = (
            "observed_faster"
            if saved > 0
            else "observed_slower"
            if saved < 0
            else "unchanged"
        )
        if before_side["median_seconds"] != 0:
            candidate_percent = saved / before_side["median_seconds"] * 100
            percent = candidate_percent if math.isfinite(candidate_percent) else None
    return {
        "schema_version": SCHEMA_VERSION,
        "source": before["source"] if before["source"] == after["source"] else None,
        "minimum_samples": minimum_samples,
        "comparability": comparable,
        "reasons": reasons,
        "context_differences": differences,
        "acknowledgement_plan_ref": ack["plan_ref"] if ack is not None else None,
        "acknowledged_differences": acknowledged,
        "provenance": {
            "before": _side_provenance(before),
            "after": _side_provenance(after),
        },
        "before": before_side,
        "after": after_side,
        "delta": {
            "saved_seconds": saved,
            "saved_percent": percent,
            "direction": direction,
        },
    }


def _read_json(path: str) -> Any:
    try:
        with Path(path).open(encoding="utf-8") as stream:
            return json.load(stream)
    except RecursionError as exc:
        raise InputError(f"input {path} is nested too deeply") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"invalid JSON input {path}: {exc}") from exc
    except UnicodeError as exc:
        raise InputError(f"invalid text input {path}: {exc}") from exc
    except OSError as exc:
        raise ExecutionError(f"cannot read JSON input {path}: {exc}") from exc


def _load_normalized(path: str) -> tuple[dict[str, Any], _Variants]:
    try:
        return _validate_normalized(_read_json(path))
    except InputError as exc:
        raise InputError(f"{path}: {exc}") from exc


def _write_json(value: Any, path: str | None, force: bool) -> None:
    encoded = json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if path is None:
        if force:
            raise InputError("--force requires an output path")
        print(encoded, end="")
        return
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | ((os.O_TRUNC | os.O_NOFOLLOW) if force else os.O_EXCL)
    )
    try:
        descriptor = os.open(path, flags, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            os.fchmod(descriptor, 0o600)
            stream.write(encoded)
    except FileExistsError as exc:
        raise ExecutionError(
            f"output {path} already exists; pass --force to overwrite"
        ) from exc
    except OSError as exc:
        raise ExecutionError(f"cannot write output {path}: {exc}") from exc


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("ci", "local"):
        command = subparsers.add_parser(name)
        command.add_argument("--input", required=True)
        command.add_argument("--output")
        command.add_argument("--force", action="store_true")
    compare = subparsers.add_parser("compare")
    compare.add_argument("--before", required=True)
    compare.add_argument("--after", required=True)
    compare.add_argument("--minimum-samples", required=True, type=int)
    compare.add_argument("--acknowledgements")
    compare.add_argument("--output")
    compare.add_argument("--force", action="store_true")
    from_hyperfine = subparsers.add_parser("from-hyperfine")
    from_hyperfine.add_argument("--input", required=True)
    from_hyperfine.add_argument("--command", dest="hyperfine_command", required=True)
    from_hyperfine.add_argument("--revision", required=True)
    from_hyperfine.add_argument("--environment", required=True)
    from_hyperfine.add_argument("--cache-state", required=True)
    from_hyperfine.add_argument("--workload-label", required=True)
    from_hyperfine.add_argument("--sample-prefix", default="sample")
    from_hyperfine.add_argument("--tool-version")
    from_hyperfine.add_argument("--captured-at")
    from_hyperfine.add_argument("--output")
    from_hyperfine.add_argument("--force", action="store_true")
    return parser


def _from_hyperfine(args: argparse.Namespace) -> dict[str, Any]:
    export = _read_json(args.input)
    export = _object(export, "hyperfine export")
    results = export.get("results")
    if not isinstance(results, list) or len(results) != 1:
        raise InputError("hyperfine export must contain exactly one result")
    result = _object(results[0], "hyperfine result")
    times = result.get("times")
    exit_codes = result.get("exit_codes")
    if not isinstance(times, list) or not times:
        raise InputError("hyperfine result.times must be a non-empty list")
    if not isinstance(exit_codes, list):
        raise InputError("hyperfine result.exit_codes must be a list")
    if len(times) != len(exit_codes):
        raise InputError(
            "hyperfine result.times and exit_codes must be the same length"
        )
    samples = []
    for index, (time_value, exit_code) in enumerate(zip(times, exit_codes)):
        duration = _number(time_value, f"times[{index}]")
        if (
            exit_code is None
            or isinstance(exit_code, bool)
            or not isinstance(exit_code, int)
        ):
            raise InputError(f"exit_codes[{index}] must be an integer")
        samples.append(
            {
                "id": f"{args.sample_prefix}-{index}",
                "status": "success" if exit_code == 0 else "failed",
                "duration_seconds": duration,
                "exit_code": exit_code,
                "warmup": False,
            }
        )
    if args.captured_at is not None:
        captured_at = args.captured_at
    else:
        mtime = Path(args.input).stat().st_mtime
        captured_at = datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()
    benchmark_source = {"tool": "hyperfine", "evidence_file": args.input}
    if args.tool_version is not None:
        benchmark_source["version"] = args.tool_version
    payload = {
        "schema_version": SCHEMA_VERSION,
        "source": LOCAL_SOURCE,
        "command": args.hyperfine_command,
        "revision": args.revision,
        "environment": args.environment,
        "cache_state": args.cache_state,
        "workload_label": args.workload_label,
        "captured_at": captured_at,
        "benchmark_source": benchmark_source,
        "samples": samples,
    }
    return _normalize_local(payload)


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "ci":
            result = _normalize_ci(_read_json(args.input))
        elif args.command == "local":
            result = _normalize_local(_read_json(args.input))
        elif args.command == "from-hyperfine":
            result = _from_hyperfine(args)
        else:
            ack = _read_json(args.acknowledgements) if args.acknowledgements else None
            before, before_variants = _load_normalized(args.before)
            after, after_variants = _load_normalized(args.after)
            result = _compare_datasets(
                before,
                before_variants,
                after,
                after_variants,
                args.minimum_samples,
                ack,
            )
        _write_json(result, args.output, args.force)
    except InputError as exc:
        print(f"ci-optimize: {exc}", file=sys.stderr)
        return 2
    except ExecutionError as exc:
        print(f"ci-optimize: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

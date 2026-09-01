#!/usr/bin/env python3
"""Validate attributable Android TOTAL PSS telemetry memory evidence."""

from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PEAK_DELTA_LIMIT_KB = 96 * 1024
SETTLED_DELTA_LIMIT_KB = 48 * 1024
BASELINE_STAGE = "baseline"
SETTLED_STAGE = "settled"
OPERATION_STAGES = (
    "index",
    "replay",
    "directCsv",
    "share_telemetryCsv",
    "share_telemetryJson",
    "share_rawTranscript",
    "share_recoveredTranscript",
    "share_pidCsv",
    "coordinatorExact32MiB",
    "connectedFresh",
    "connectedStale",
    "allocatedCut",
    "crossFeatureBusy",
    "cleanupOpportunity",
)
REQUIRED_STAGES = (BASELINE_STAGE, *OPERATION_STAGES, SETTLED_STAGE)
AMBIENT_STAGES = ("launch", "idle")
ALLOWED_SAMPLE_STAGES = (*REQUIRED_STAGES, *AMBIENT_STAGES)
STAGE_MARKER = re.compile(
    r"TELLTALE_MEMORY_STAGE stage=(\w+) edge=(BEGIN|END) epochUs=(\d+)"
)
MIN_SAMPLES_PER_STAGE = 3
MAX_SAMPLE_GAP_US = 1_000_000
MAX_SAMPLE_DURATION_US = 1_000_000
SAMPLE_COLUMNS = (
    "sample_start_epoch_us",
    "sample_end_epoch_us",
    "stage",
    "total_pss_kb",
    "marker_epoch_us",
    "pid",
)


@dataclass(frozen=True)
class _PssSample:
    sample_start_epoch_us: int
    sample_end_epoch_us: int
    stage: str
    total_pss_kb: int
    marker_epoch_us: int
    pid: int


def _read_samples(
    samples_path: str,
) -> tuple[list[_PssSample], dict[str, list[_PssSample]]]:
    with Path(samples_path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if tuple(reader.fieldnames or ()) != SAMPLE_COLUMNS:
            raise ValueError("invalid TOTAL PSS TSV schema")
        rows = list(reader)
    samples: list[_PssSample] = []
    by_stage: dict[str, list[_PssSample]] = {}
    for number, row in enumerate(rows, start=2):
        if set(row) != set(SAMPLE_COLUMNS):
            raise ValueError(f"invalid TOTAL PSS sample at line {number}")
        try:
            sample = _PssSample(
                sample_start_epoch_us=int(row["sample_start_epoch_us"]),
                sample_end_epoch_us=int(row["sample_end_epoch_us"]),
                stage=row["stage"],
                total_pss_kb=int(row["total_pss_kb"]),
                marker_epoch_us=int(row["marker_epoch_us"]),
                pid=int(row["pid"]),
            )
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"invalid TOTAL PSS sample at line {number}") from error
        if sample.stage not in ALLOWED_SAMPLE_STAGES:
            raise ValueError(
                f"unknown TOTAL PSS sample stage at line {number}: {sample.stage}"
            )
        if (
            not sample.stage
            or sample.sample_start_epoch_us <= 0
            or sample.sample_end_epoch_us <= 0
            or sample.sample_end_epoch_us < sample.sample_start_epoch_us
            or sample.total_pss_kb <= 0
            or sample.marker_epoch_us < 0
            or sample.pid <= 0
        ):
            raise ValueError(f"invalid TOTAL PSS sample at line {number}")
        if (
            sample.sample_end_epoch_us - sample.sample_start_epoch_us
            > MAX_SAMPLE_DURATION_US
        ):
            raise ValueError(
                f"TOTAL PSS sample duration exceeds {MAX_SAMPLE_DURATION_US} us"
            )
        if samples and sample.sample_start_epoch_us <= samples[-1].sample_end_epoch_us:
            raise ValueError(
                "TOTAL PSS sample timestamps are not strictly increasing or overlap"
            )
        samples.append(sample)
        by_stage.setdefault(sample.stage, []).append(sample)
    pids = {sample.pid for sample in samples}
    if len(pids) != 1:
        raise ValueError("TOTAL PSS samples do not have a stable PID")
    for required in REQUIRED_STAGES:
        stage_samples = by_stage.get(required, [])
        if len(stage_samples) < MIN_SAMPLES_PER_STAGE:
            raise ValueError(
                f"{required} requires at least {MIN_SAMPLES_PER_STAGE} TOTAL PSS samples"
            )
        for previous, current in zip(stage_samples, stage_samples[1:]):
            if (
                current.sample_end_epoch_us - previous.sample_end_epoch_us
                > MAX_SAMPLE_GAP_US
            ):
                raise ValueError(
                    f"{required} TOTAL PSS sample gap exceeds {MAX_SAMPLE_GAP_US} us"
                )
    return samples, by_stage


def _validate_markers(log: str) -> dict[str, dict[str, int]]:
    markers: dict[str, dict[str, int]] = {}
    positions: dict[str, dict[str, int]] = {}
    for match in STAGE_MARKER.finditer(log):
        stage, edge, raw_epoch = match.groups()
        if stage not in REQUIRED_STAGES:
            continue
        if edge in markers.setdefault(stage, {}):
            raise ValueError(f"duplicate {edge} marker for {stage}")
        markers[stage][edge] = int(raw_epoch)
        positions.setdefault(stage, {})[edge] = match.start()
    for stage in REQUIRED_STAGES:
        edges = markers.get(stage, {})
        if set(edges) != {"BEGIN", "END"}:
            raise ValueError(f"missing timestamped BEGIN/END markers for {stage}")
        if edges["BEGIN"] >= edges["END"]:
            raise ValueError(f"non-increasing marker timestamps for {stage}")
        if positions[stage]["BEGIN"] >= positions[stage]["END"]:
            raise ValueError(f"END marker precedes BEGIN for {stage}")
    for previous, current in zip(REQUIRED_STAGES, REQUIRED_STAGES[1:]):
        if positions[previous]["END"] >= positions[current]["BEGIN"]:
            raise ValueError(
                f"required stages overlap or are out of log order: {previous}, {current}"
            )
        if markers[previous]["END"] >= markers[current]["BEGIN"]:
            raise ValueError(
                f"required stages overlap or are out of epoch order: {previous}, {current}"
            )
    return markers


def _validate_sample_attribution(
    by_stage: dict[str, list[_PssSample]],
    markers: dict[str, dict[str, int]],
) -> None:
    for stage in REQUIRED_STAGES:
        begin = markers[stage]["BEGIN"]
        end = markers[stage]["END"]
        stage_samples = by_stage[stage]
        if stage_samples[0].sample_end_epoch_us - begin > MAX_SAMPLE_GAP_US:
            raise ValueError(
                f"{stage} BEGIN-to-first TOTAL PSS sample gap exceeds "
                f"{MAX_SAMPLE_GAP_US} us"
            )
        if end - stage_samples[-1].sample_end_epoch_us > MAX_SAMPLE_GAP_US:
            raise ValueError(
                f"{stage} last TOTAL PSS sample-to-END gap exceeds "
                f"{MAX_SAMPLE_GAP_US} us"
            )
        for sample in stage_samples:
            if sample.marker_epoch_us != begin:
                raise ValueError(
                    f"{stage} TOTAL PSS marker epoch does not match BEGIN marker"
                )
            if not (
                begin
                <= sample.sample_start_epoch_us
                <= sample.sample_end_epoch_us
                <= end
            ):
                raise ValueError(
                    f"{stage} TOTAL PSS sample timestamp is outside its marker window"
                )
    for ambient_stage in AMBIENT_STAGES:
        for sample in by_stage.get(ambient_stage, []):
            for required_stage in REQUIRED_STAGES:
                begin = markers[required_stage]["BEGIN"]
                end = markers[required_stage]["END"]
                if (
                    sample.sample_start_epoch_us <= end
                    and sample.sample_end_epoch_us >= begin
                ):
                    raise ValueError(
                        f"{ambient_stage} TOTAL PSS sample overlaps "
                        f"{required_stage} marker window"
                    )


def analyze(samples_path: str, log_path: str) -> dict[str, Any]:
    samples, by_stage = _read_samples(samples_path)
    log = Path(log_path).read_text(encoding="utf-8", errors="strict")
    markers = _validate_markers(log)
    _validate_sample_attribution(by_stage, markers)

    required_proof = (
        "TELLTALE_MEMORY_INDEX bytes=104857600",
        "TELLTALE_MEMORY_REPLAY lanes=4",
        "TELLTALE_MEMORY_DIRECT_CSV bytes=",
        "TELLTALE_MEMORY_PRODUCTION_EXPORT extensions=csv,json",
        "TELLTALE_MEMORY_PRODUCTION_SHARE kind=rawTranscript",
        "TELLTALE_MEMORY_PRODUCTION_SHARE kind=recoveredTranscript",
        "TELLTALE_MEMORY_PRODUCTION_SHARE kind=pidCsv",
        "TELLTALE_MEMORY_EXACT32 elapsedMs=",
        "TELLTALE_MEMORY_CONNECTED stale=false result=selected platformCalls=1",
        "TELLTALE_MEMORY_CONNECTED stale=true result=null platformCalls=0",
        "TELLTALE_MEMORY_BUSY share=shareBusy crossFeature=artifactBusy",
        "TELLTALE_MEMORY_CLOCK_ONLY retained=2",
        "TELLTALE_MEMORY_NEXT_OPPORTUNITY_CLEANUP remaining=0",
        "TELLTALE_MEMORY_RECONSTRUCTION scope=freshCoordinator state=handedOffLease result=pending",
        "TELLTALE_MEMORY_PLUGIN_MIRROR path=",
        "ownership=observedOnly",
        "TELLTALE_MEMORY_APP_STAGING root=",
        "TELLTALE_MEMORY_CRASH_CUT_READY cut=allocated",
        "TELLTALE_MEMORY_CRASH_CUT_READY cut=handedOffLease",
        "TELLTALE_MEMORY_CRASH_CUT_READY cut=postPlatform",
        "TELLTALE_MEMORY_CRASH_CUT_READY cut=pendingResult",
        "TELLTALE_MEMORY_CRASH_CUT_READY cut=neverResult",
        "TELLTALE_MEMORY_RESIDUE_READY epochUs=",
        "TELLTALE_MEMORY_MEASURE_COMPLETE epochUs=",
        "All tests passed!",
    )
    missing = [proof for proof in required_proof if proof not in log]
    for kind in (
        "telemetryCsv",
        "telemetryJson",
        "rawTranscript",
        "recoveredTranscript",
        "pidCsv",
    ):
        if re.search(
            rf"TELLTALE_MEMORY_FINGERPRINT kind={kind} .*"
            r"bytes=\d+ fingerprint=fnv1a64:[0-9a-f]{16} .*ledgerBytes=\d+",
            log,
        ) is None:
            missing.append(f"verified source/ledger fingerprint for {kind}")
    if missing:
        raise ValueError(f"missing memory proof markers: {missing}")
    exact_limit = re.search(r"TELLTALE_MEMORY_EXACT32 elapsedMs=(\d+)", log)
    if exact_limit is None or int(exact_limit.group(1)) <= 2000:
        raise ValueError("exact-limit coordinator operation did not exceed two seconds")

    baseline = min(sample.total_pss_kb for sample in by_stage[BASELINE_STAGE])
    stage_peaks = {
        stage: max(sample.total_pss_kb for sample in by_stage[stage])
        for stage in OPERATION_STAGES
    }
    peak_stage = max(stage_peaks, key=stage_peaks.__getitem__)
    peak = stage_peaks[peak_stage]
    settled = by_stage[SETTLED_STAGE][-1].total_pss_kb
    peak_delta = peak - baseline
    settled_delta = settled - baseline
    if peak_delta > PEAK_DELTA_LIMIT_KB:
        raise ValueError(
            f"peak TOTAL PSS delta {peak_delta} KiB in {peak_stage} exceeds 96 MiB"
        )
    if settled_delta > SETTLED_DELTA_LIMIT_KB:
        raise ValueError(
            f"settled TOTAL PSS delta {settled_delta} KiB exceeds 48 MiB"
        )

    return {
        "baseline_kb": baseline,
        "peak_kb": peak,
        "peak_stage": peak_stage,
        "settled_kb": settled,
        "peak_delta_kb": peak_delta,
        "settled_delta_kb": settled_delta,
        "stage_peaks_kb": stage_peaks,
        "marker_epochs_us": markers,
        "sample_pid": samples[0].pid,
        "sample_counts": {
            stage: len(by_stage[stage]) for stage in REQUIRED_STAGES
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = analyze(args.samples, args.log)
    Path(args.output).write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()

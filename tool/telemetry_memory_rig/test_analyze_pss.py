import tempfile
import unittest
from pathlib import Path

from analyze_pss import REQUIRED_STAGES, analyze


START_EPOCH_US = 1_700_000_000_000_000
STAGE_WINDOW_US = 4_000_000
STAGE_SEPARATION_US = 100_000
PID = 3210


def marker_epochs() -> dict[str, tuple[int, int]]:
    return {
        stage: (
            START_EPOCH_US + index * (STAGE_WINDOW_US + STAGE_SEPARATION_US),
            START_EPOCH_US
            + index * (STAGE_WINDOW_US + STAGE_SEPARATION_US)
            + STAGE_WINDOW_US,
        )
        for index, stage in enumerate(REQUIRED_STAGES)
    }


def good_log() -> str:
    lines = []
    epochs = marker_epochs()
    for stage in REQUIRED_STAGES:
        begin, end = epochs[stage]
        lines.append(
            f"TELLTALE_MEMORY_STAGE stage={stage} edge=BEGIN epochUs={begin}"
        )
        lines.append(f"TELLTALE_MEMORY_STAGE stage={stage} edge=END epochUs={end}")
    lines.extend(
        [
            "TELLTALE_MEMORY_INDEX bytes=104857600 projection=10",
            "TELLTALE_MEMORY_REPLAY lanes=4",
            "TELLTALE_MEMORY_DIRECT_CSV bytes=1 maxBuffers=1",
            "TELLTALE_MEMORY_PRODUCTION_EXPORT extensions=csv,json",
            "TELLTALE_MEMORY_PRODUCTION_SHARE kind=rawTranscript",
            "TELLTALE_MEMORY_PRODUCTION_SHARE kind=recoveredTranscript",
            "TELLTALE_MEMORY_PRODUCTION_SHARE kind=pidCsv",
            "TELLTALE_MEMORY_EXACT32 elapsedMs=2001",
            "TELLTALE_MEMORY_CONNECTED stale=false result=selected platformCalls=1",
            "TELLTALE_MEMORY_CONNECTED stale=true result=null platformCalls=0",
            "TELLTALE_MEMORY_BUSY share=shareBusy crossFeature=artifactBusy",
            "TELLTALE_MEMORY_CLOCK_ONLY retained=2",
            "TELLTALE_MEMORY_NEXT_OPPORTUNITY_CLEANUP remaining=0",
            "TELLTALE_MEMORY_RECONSTRUCTION scope=freshCoordinator state=handedOffLease result=pending",
            "TELLTALE_MEMORY_PLUGIN_MIRROR path=/cache/share_plus files=0 bytes=0 ownership=observedOnly",
            "TELLTALE_MEMORY_APP_STAGING root=fixture sources=1 sourceBytes=1 ledgers=1 ledgerBytes=1 temps=0 tempBytes=0",
            "TELLTALE_MEMORY_CRASH_CUT_READY cut=allocated",
            "TELLTALE_MEMORY_CRASH_CUT_READY cut=handedOffLease",
            "TELLTALE_MEMORY_CRASH_CUT_READY cut=postPlatform",
            "TELLTALE_MEMORY_CRASH_CUT_READY cut=pendingResult",
            "TELLTALE_MEMORY_CRASH_CUT_READY cut=neverResult",
            *[
                f"TELLTALE_MEMORY_FINGERPRINT kind={kind} id={'a' * 32} "
                "bytes=1 fingerprint=fnv1a64:0000000000000001 "
                "result=selected ledgerBytes=256"
                for kind in (
                    "telemetryCsv",
                    "telemetryJson",
                    "rawTranscript",
                    "recoveredTranscript",
                    "pidCsv",
                )
            ],
            "TELLTALE_MEMORY_RESIDUE_READY epochUs=1700000000000100",
            "TELLTALE_MEMORY_MEASURE_COMPLETE epochUs=1700000000000101",
            "All tests passed!",
        ]
    )
    return "\n".join(lines)


def samples_with(
    *,
    peak_kb: int = 198_304,
    settled_kb: int = 149_152,
    offsets_by_stage: dict[str, tuple[int, ...]] | None = None,
    intervals_by_stage: dict[str, tuple[tuple[int, int], ...]] | None = None,
    marker_override_by_stage: dict[str, int] | None = None,
    pid_by_stage: dict[str, int] | None = None,
) -> str:
    offsets_by_stage = offsets_by_stage or {}
    intervals_by_stage = intervals_by_stage or {}
    marker_override_by_stage = marker_override_by_stage or {}
    pid_by_stage = pid_by_stage or {}
    lines = [
        "sample_start_epoch_us\tsample_end_epoch_us\tstage\t"
        "total_pss_kb\tmarker_epoch_us\tpid"
    ]
    epochs = marker_epochs()
    for stage_index, stage in enumerate(REQUIRED_STAGES):
        begin, _ = epochs[stage]
        intervals = intervals_by_stage.get(stage)
        if intervals is None:
            offsets = offsets_by_stage.get(
                stage, (1_000_000, 2_000_000, 3_000_000)
            )
            intervals = tuple((offset - 100_000, offset) for offset in offsets)
        for sample_index, (start_offset, end_offset) in enumerate(intervals):
            value = 100_000 + stage_index + sample_index
            if stage == "replay" and sample_index == 1:
                value = peak_kb
            if stage == "settled" and sample_index == len(intervals) - 1:
                value = settled_kb
            lines.append(
                f"{begin + start_offset}\t{begin + end_offset}\t{stage}\t{value}\t"
                f"{marker_override_by_stage.get(stage, begin)}\t"
                f"{pid_by_stage.get(stage, PID)}"
            )
    return "\n".join(lines) + "\n"


class AnalyzePssTest(unittest.TestCase):
    def analyze_fixture(self, samples_text: str, log_text: str):
        with tempfile.TemporaryDirectory() as root:
            samples = Path(root) / "pss.tsv"
            log = Path(root) / "flutter-measure.log"
            samples.write_text(samples_text, encoding="utf-8")
            log.write_text(log_text, encoding="utf-8")
            return analyze(str(samples), str(log))

    def test_accepts_hard_gate_and_sample_gap_boundaries(self):
        result = self.analyze_fixture(
            samples_with(
                offsets_by_stage={"index": (1_000_000, 2_000_000, 3_000_000)}
            ),
            good_log(),
        )
        self.assertEqual(result["peak_delta_kb"], 96 * 1024)
        self.assertEqual(result["settled_delta_kb"], 48 * 1024)
        self.assertEqual(result["peak_stage"], "replay")
        self.assertEqual(result["sample_pid"], PID)
        self.assertEqual(result["sample_counts"]["index"], 3)

    def test_rejects_peak_above_hard_gate(self):
        with self.assertRaisesRegex(ValueError, "replay exceeds 96 MiB"):
            self.analyze_fixture(samples_with(peak_kb=198_305), good_log())

    def test_rejects_settled_above_hard_gate(self):
        with self.assertRaisesRegex(ValueError, "settled TOTAL PSS delta.*48 MiB"):
            self.analyze_fixture(samples_with(settled_kb=149_153), good_log())

    def test_rejects_fewer_than_three_required_stage_samples(self):
        with self.assertRaisesRegex(
            ValueError, "index requires at least 3 TOTAL PSS samples"
        ):
            self.analyze_fixture(
                samples_with(offsets_by_stage={"index": (100_000, 500_000)}),
                good_log(),
            )

    def test_rejects_sample_gap_above_one_second(self):
        with self.assertRaisesRegex(ValueError, "index TOTAL PSS sample gap exceeds"):
            self.analyze_fixture(
                samples_with(
                    offsets_by_stage={"index": (0, 1_000_001, 2_000_000)}
                ),
                good_log(),
            )

    def test_rejects_observed_samsung_sample_gap_without_loosening_gate(self):
        with self.assertRaisesRegex(ValueError, "index TOTAL PSS sample gap exceeds"):
            self.analyze_fixture(
                samples_with(
                    offsets_by_stage={"index": (0, 1_003_041, 2_000_000)}
                ),
                good_log(),
            )

    def test_rejects_probe_duration_above_one_second(self):
        with self.assertRaisesRegex(ValueError, "sample duration exceeds"):
            self.analyze_fixture(
                samples_with(
                    intervals_by_stage={
                        "index": (
                            (100_000, 1_100_001),
                            (1_200_000, 2_000_000),
                            (2_100_000, 3_000_000),
                        )
                    }
                ),
                good_log(),
            )

    def test_rejects_begin_to_first_sample_gap_above_one_second(self):
        with self.assertRaisesRegex(ValueError, "BEGIN-to-first.*gap exceeds"):
            self.analyze_fixture(
                samples_with(
                    offsets_by_stage={
                        "index": (1_000_001, 2_000_000, 3_000_000)
                    }
                ),
                good_log(),
            )

    def test_rejects_last_sample_to_end_gap_above_one_second(self):
        with self.assertRaisesRegex(ValueError, "sample-to-END gap exceeds"):
            self.analyze_fixture(
                samples_with(
                    offsets_by_stage={
                        "index": (1_000_000, 2_000_000, 2_999_999)
                    }
                ),
                good_log(),
            )

    def test_rejects_unstable_pid(self):
        with self.assertRaisesRegex(ValueError, "do not have a stable PID"):
            self.analyze_fixture(
                samples_with(pid_by_stage={"directCsv": PID + 1}), good_log()
            )

    def test_rejects_non_increasing_sample_timestamps(self):
        text = samples_with()
        first, second = text.splitlines()[1:3]
        first_fields = first.split("\t")
        second_fields = second.split("\t")
        second_fields[0:2] = first_fields[0:2]
        duplicate_epoch = "\t".join(second_fields)
        text = text.replace(second, duplicate_epoch, 1)
        with self.assertRaisesRegex(ValueError, "not strictly increasing"):
            self.analyze_fixture(text, good_log())

    def test_rejects_marker_epoch_not_equal_to_stage_begin(self):
        with self.assertRaisesRegex(ValueError, "marker epoch does not match BEGIN"):
            self.analyze_fixture(
                samples_with(marker_override_by_stage={"replay": 42}), good_log()
            )

    def test_rejects_sample_before_marker_window(self):
        with self.assertRaisesRegex(ValueError, "outside its marker window"):
            self.analyze_fixture(
                samples_with(
                    offsets_by_stage={
                        "index": (-1, 999_999, 1_999_999, 2_999_999, 3_999_999)
                    }
                ),
                good_log(),
            )

    def test_rejects_sample_after_marker_window(self):
        with self.assertRaisesRegex(ValueError, "outside its marker window"):
            self.analyze_fixture(
                samples_with(
                    intervals_by_stage={
                        "index": (
                            (900_000, 1_000_000),
                            (1_900_000, 2_000_000),
                            (2_900_000, 3_000_000),
                            (3_900_000, 4_000_000),
                            (4_000_001, 4_100_001),
                        )
                    }
                ),
                good_log(),
            )

    def test_rejects_old_tsv_schema(self):
        old_schema = samples_with().replace(
            "sample_start_epoch_us\tsample_end_epoch_us\tstage\t"
            "total_pss_kb\tmarker_epoch_us\tpid",
            "epoch_ms\tstage\ttotal_pss_kb\tmarker_epoch_us\tpid",
        )
        with self.assertRaisesRegex(ValueError, "invalid TOTAL PSS TSV schema"):
            self.analyze_fixture(old_schema, good_log())

    def test_rejects_unknown_sample_stage(self):
        lines = samples_with().splitlines()
        fields = lines[1].split("\t")
        fields[2] = "mystery"
        lines[1] = "\t".join(fields)
        with self.assertRaisesRegex(ValueError, "unknown TOTAL PSS sample stage"):
            self.analyze_fixture("\n".join(lines) + "\n", good_log())

    def test_rejects_launch_sample_overlapping_required_marker_window(self):
        lines = samples_with().splitlines()
        begin, _ = marker_epochs()["baseline"]
        lines.append(
            f"{begin + 3_100_000}\t{begin + 3_200_000}\tlaunch\t999999\t0\t{PID}"
        )
        header, *rows = lines
        rows.sort(key=lambda row: int(row.split("\t", 1)[0]))
        with self.assertRaisesRegex(
            ValueError, "launch TOTAL PSS sample overlaps baseline marker window"
        ):
            self.analyze_fixture("\n".join((header, *rows)) + "\n", good_log())

    def test_rejects_idle_sample_overlapping_required_marker_window(self):
        lines = samples_with().splitlines()
        begin, _ = marker_epochs()["replay"]
        lines.append(
            f"{begin + 3_100_000}\t{begin + 3_200_000}\tidle\t999999\t0\t{PID}"
        )
        header, *rows = lines
        rows.sort(key=lambda row: int(row.split("\t", 1)[0]))
        with self.assertRaisesRegex(
            ValueError, "idle TOTAL PSS sample overlaps replay marker window"
        ):
            self.analyze_fixture("\n".join((header, *rows)) + "\n", good_log())

    def test_accepts_launch_and_idle_samples_outside_required_marker_windows(self):
        lines = samples_with().splitlines()
        epochs = marker_epochs()
        launch_end = epochs["baseline"][0] - 100_000
        idle_start = epochs["baseline"][1] + 10_000
        lines.extend(
            (
                f"{launch_end - 100_000}\t{launch_end}\tlaunch\t999999\t0\t{PID}",
                f"{idle_start}\t{idle_start + 50_000}\tidle\t999999\t0\t{PID}",
            )
        )
        header, *rows = lines
        rows.sort(key=lambda row: int(row.split("\t", 1)[0]))
        result = self.analyze_fixture("\n".join((header, *rows)) + "\n", good_log())
        self.assertEqual(result["peak_stage"], "replay")

    def test_rejects_surplus_tsv_field(self):
        text = samples_with()
        first_row = text.splitlines()[1]
        malformed = text.replace(first_row, f"{first_row}\tunexpected", 1)
        with self.assertRaisesRegex(
            ValueError, "invalid TOTAL PSS sample at line 2"
        ):
            self.analyze_fixture(malformed, good_log())

    def test_rejects_invalid_sample_fields(self):
        valid_row = samples_with().splitlines()[1]
        fields = valid_row.split("\t")
        for index, invalid_value in (
            (0, "0"),
            (1, "0"),
            (3, "0"),
            (4, "-1"),
            (5, "0"),
        ):
            with self.subTest(column=index):
                invalid_fields = fields.copy()
                invalid_fields[index] = invalid_value
                invalid_row = "\t".join(invalid_fields)
                invalid = samples_with().replace(valid_row, invalid_row, 1)
                with self.assertRaisesRegex(
                    ValueError, "invalid TOTAL PSS sample at line 2"
                ):
                    self.analyze_fixture(invalid, good_log())

    def test_rejects_missing_timestamped_end_marker(self):
        _, end = marker_epochs()["directCsv"]
        log = good_log().replace(
            f"TELLTALE_MEMORY_STAGE stage=directCsv edge=END epochUs={end}\n", ""
        )
        with self.assertRaisesRegex(
            ValueError, "missing timestamped BEGIN/END markers for directCsv"
        ):
            self.analyze_fixture(samples_with(), log)

    def test_rejects_duplicate_stage_marker(self):
        duplicate = (
            good_log()
            + "\nTELLTALE_MEMORY_STAGE stage=index edge=BEGIN epochUs=1800000000000000"
        )
        with self.assertRaisesRegex(ValueError, "duplicate BEGIN marker for index"):
            self.analyze_fixture(samples_with(), duplicate)

    def test_rejects_non_increasing_local_marker_epochs(self):
        begin, end = marker_epochs()["directCsv"]
        log = good_log().replace(
            f"stage=directCsv edge=END epochUs={end}",
            f"stage=directCsv edge=END epochUs={begin}",
        )
        with self.assertRaisesRegex(ValueError, "non-increasing marker timestamps"):
            self.analyze_fixture(samples_with(), log)

    def test_rejects_end_before_begin_in_log_order(self):
        begin, end = marker_epochs()["directCsv"]
        begin_line = f"TELLTALE_MEMORY_STAGE stage=directCsv edge=BEGIN epochUs={begin}"
        end_line = f"TELLTALE_MEMORY_STAGE stage=directCsv edge=END epochUs={end}"
        log = good_log().replace(
            f"{begin_line}\n{end_line}", f"{end_line}\n{begin_line}"
        )
        with self.assertRaisesRegex(ValueError, "END marker precedes BEGIN"):
            self.analyze_fixture(samples_with(), log)

    def test_rejects_required_stage_overlap_in_log_order(self):
        baseline_begin, baseline_end = marker_epochs()["baseline"]
        index_begin, index_end = marker_epochs()["index"]
        ordered = "\n".join(
            (
                f"TELLTALE_MEMORY_STAGE stage=baseline edge=BEGIN epochUs={baseline_begin}",
                f"TELLTALE_MEMORY_STAGE stage=baseline edge=END epochUs={baseline_end}",
                f"TELLTALE_MEMORY_STAGE stage=index edge=BEGIN epochUs={index_begin}",
                f"TELLTALE_MEMORY_STAGE stage=index edge=END epochUs={index_end}",
            )
        )
        overlapping = "\n".join(
            (
                f"TELLTALE_MEMORY_STAGE stage=baseline edge=BEGIN epochUs={baseline_begin}",
                f"TELLTALE_MEMORY_STAGE stage=index edge=BEGIN epochUs={index_begin}",
                f"TELLTALE_MEMORY_STAGE stage=baseline edge=END epochUs={baseline_end}",
                f"TELLTALE_MEMORY_STAGE stage=index edge=END epochUs={index_end}",
            )
        )
        with self.assertRaisesRegex(ValueError, "overlap or are out of log order"):
            self.analyze_fixture(samples_with(), good_log().replace(ordered, overlapping))

    def test_rejects_required_stage_overlap_in_epoch_order(self):
        _, baseline_end = marker_epochs()["baseline"]
        index_begin, _ = marker_epochs()["index"]
        log = good_log().replace(
            f"stage=index edge=BEGIN epochUs={index_begin}",
            f"stage=index edge=BEGIN epochUs={baseline_end}",
        )
        with self.assertRaisesRegex(ValueError, "overlap or are out of epoch order"):
            self.analyze_fixture(samples_with(), log)

    def test_rejects_missing_production_export_proof(self):
        log = good_log().replace("extensions=csv,json", "extensions=missing")
        with self.assertRaisesRegex(ValueError, "missing memory proof markers"):
            self.analyze_fixture(samples_with(), log)


if __name__ == "__main__":
    unittest.main()

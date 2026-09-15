import unittest
from datetime import date
from types import SimpleNamespace as NS
from unittest.mock import Mock, patch
import sync


def response(values, count):
    return NS(dimension_headers=[NS(name="pagePath")], metric_headers=[NS(name="screenPageViews")],
              metadata=NS(subject_to_thresholding=False, sampling_metadatas=[]), row_count=count,
              rows=[NS(dimension_values=[NS(value=p)], metric_values=[NS(value=str(n))]) for p, n in values])


class Tests(unittest.TestCase):
    def test_homepage_filter_on_every_report(self):
        for report in sync.REPORTS:
            request = sync.report_request(sync.PROPERTY_ID, sync.STREAM_ID, report, "2026-09-15")
            self.assertEqual(request["dimension_filter"]["filter"]["field_name"], "streamId")
            self.assertEqual(request["dimension_filter"]["filter"]["string_filter"]["value"], "15781098262")

    def test_pagination(self):
        client = Mock()
        client.run_report.side_effect = [response([("/liga", 12)], 2), response([("/news", 8)], 2)]
        rows, _, _ = sync.fetch_report(client, {"offset": 0})
        self.assertEqual(len(rows), 2)
        self.assertEqual(client.run_report.call_args.kwargs["request"]["offset"], 1)

    def test_retries_replace_same_snapshot_and_empty_clears_stale_rows(self):
        collection = Mock()
        with patch.object(sync, "REPORTS", {"overview": ([], [])}), patch.object(sync, "fetch_report", return_value=([], False, False)):
            for _ in range(2):
                sync.sync(Mock(), collection, "123", "456", date(2026, 9, 15), lookback=1)
        first, second = collection.replace_one.call_args_list
        self.assertEqual(first.args[0], second.args[0])
        self.assertEqual(second.args[1]["rows"], [])
        self.assertTrue(second.kwargs["upsert"])

    def test_failed_fetch_preserves_previous_snapshot(self):
        collection = Mock()
        with patch.object(sync, "REPORTS", {"overview": ([], [])}), patch.object(sync, "fetch_report", side_effect=RuntimeError()):
            with self.assertRaises(RuntimeError):
                sync.sync(Mock(), collection, "123", "456", date(2026, 9, 15), lookback=1)
        collection.replace_one.assert_not_called()


if __name__ == "__main__":
    unittest.main()

import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('perf_summary', Path(__file__).resolve().parents[1] / 'perf-summary.py')
perf = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(perf)


def line(message, **more):
    return {'eventMessage': message, 'timestamp': '2026-11-25 10:00:00.000000-0800', **more}


class PerfSummaryTests(unittest.TestCase):
    def test_start_steps_are_counted_every_time_not_only_when_slow(self):
        times, stalls = perf.gather([
            line('took: start launcher 412 ms'), line('took: start launcher 2630 ms'), line('took: start listed 3100 ms'),
            line('slow: bridge live 1500 ms'), line('took: bridge live 9 ms'), line('took: start 12 ms'),
        ])
        self.assertEqual(times[('start', 'launcher')], [412.0, 2630.0])
        self.assertEqual(times[('start', 'listed')], [3100.0])
        # Only steps of a start are read from "took:" lines; a bridge call is known from its signposts and slow lines.
        self.assertEqual(times[('bridge', 'live')], [1500.0])
        self.assertNotIn(('start', ''), times)
        self.assertEqual(stalls, [])
        table = perf.table(times, 'start', 10)
        self.assertIn('launcher', table)
        self.assertLess(table.index('listed'), table.index('launcher'))

    def test_a_log_without_starts_says_so(self):
        times, _ = perf.gather([line('slow: route v1/state 1200 ms')])
        self.assertEqual(perf.table(times, 'start', 10), 'No start calls in the log.\n')
        self.assertIn('v1/state', perf.table(times, 'route', 10))

    def test_signposts_still_time_bridge_calls(self):
        begin = {'signpostType': 'begin', 'signpostName': 'bridge', 'signpostID': 7}
        end = {'signpostType': 'end', 'signpostName': 'bridge', 'signpostID': 7}
        times, _ = perf.gather([
            {**line('live'), **begin},
            {**line('live'), **end, 'timestamp': '2026-11-25 10:00:00.250000-0800'},
        ])
        self.assertEqual([round(value) for value in times[('bridge', 'live')]], [250])


if __name__ == '__main__':
    unittest.main()

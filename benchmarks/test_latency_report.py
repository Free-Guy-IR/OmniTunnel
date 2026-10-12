#!/usr/bin/env python3
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latency_report as lr


class LatencyReportTest(unittest.TestCase):
    def test_parse_basic(self):
        text = ('64 bytes from h: icmp_seq=1 ttl=50 time=12.3 ms\n'
                '64 bytes from h: icmp_seq=2 ttl=50 time=8 ms\n')
        self.assertEqual(lr.parse_rtts(text), [12.3, 8.0])

    def test_parse_less_than(self):
        self.assertEqual(lr.parse_rtts('time<1 ms'), [1.0])

    def test_summary_empty(self):
        self.assertEqual(lr.summarize([]), {'samples': 0})

    def test_quantiles(self):
        vals = [float(i) for i in range(1, 101)]
        s = lr.summarize(vals)
        self.assertEqual(s['samples'], 100)
        self.assertEqual(s['min_ms'], 1.0)
        self.assertEqual(s['max_ms'], 100.0)
        self.assertAlmostEqual(s['p50_ms'], 50.5, places=2)
        self.assertAlmostEqual(s['p95_ms'], 95.05, places=2)
        self.assertAlmostEqual(s['p99_ms'], 99.01, places=2)

    def test_no_input_mutation(self):
        vals = [3.0, 1.0, 2.0]
        lr.summarize(vals)
        self.assertEqual(vals, [3.0, 1.0, 2.0])

    def test_refuses_network_without_flag(self):
        rc = lr.main(['latency_report.py', '--host', '127.0.0.1'])
        self.assertEqual(rc, 2)


if __name__ == '__main__':
    unittest.main()

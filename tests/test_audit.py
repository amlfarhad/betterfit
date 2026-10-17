import json
import os
from pathlib import Path
import tempfile
import unittest

from fitbit_audit.oauth import pkce_challenge, check_callback, load_client, private_json, SCOPES
from fitbit_audit.api import fetch_pages, time_filter, summarize_points


class OAuthTests(unittest.TestCase):
    def test_pkce_rfc7636_vector(self):
        self.assertEqual(pkce_challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
                         'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')

    def test_callback_requires_exact_state(self):
        self.assertEqual(check_callback('state=expected&code=test-code', 'expected'), 'test-code')
        for query in ('code=test-code', 'state=wrong&code=test-code',
                      'state=expected&state=wrong&code=test-code',
                      'state=expected&error=access_denied'):
            with self.assertRaises(ValueError):
                check_callback(query, 'expected')

    def test_only_requested_readonly_scopes(self):
        self.assertEqual(len(SCOPES), 4)
        self.assertTrue(all(s.endswith('.readonly') for s in SCOPES))

    def test_private_storage_and_no_symlink_following(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'token.json'
            private_json(p, {'test': 1})
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(p.read_text()), {'test': 1})
            link = Path(temp) / 'link.json'
            link.symlink_to(p)
            with self.assertRaises(ValueError):
                private_json(link, {'test': 2})
            self.assertEqual(json.loads(p.read_text()), {'test': 1})

    def test_rejects_credentials_with_untrusted_endpoints(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / 'client.json'
            private_json(p, {'installed': {'client_id': 'example', 'token_uri': 'https://evil.example/token',
                                          'auth_uri': 'https://accounts.google.com/o/oauth2/auth'}})
            with self.assertRaises(ValueError):
                load_client(p)


class DataTests(unittest.TestCase):
    def test_pagination_follows_all_pages(self):
        calls = []
        def request(path, query):
            calls.append(dict(query))
            return ({'dataPoints': [{'steps': {'count': 0}}], 'nextPageToken': 'next'}
                    if 'pageToken' not in query else {'dataPoints': [{'steps': {'count': 2}}]})
        points = fetch_pages(request, '/test', {'pageSize': 25})
        self.assertEqual(len(points), 2)
        self.assertEqual(calls[1]['pageToken'], 'next')

    def test_repeated_page_token_fails_instead_of_looping(self):
        with self.assertRaises(ValueError):
            fetch_pages(lambda *a: {'nextPageToken': 'same', 'dataPoints': []}, '/test', {})

    def test_sleep_filters_by_end_not_start(self):
        query = time_filter('sleep', '2026-09-22', '2026-09-30')
        self.assertIn('sleep.interval.end_time', query)
        self.assertNotIn('start_time', query)

    def test_sample_and_daily_filters_are_distinct(self):
        self.assertIn('heart_rate.sample_time.physical_time', time_filter('heart-rate', '2026-09-22', '2026-09-30'))
        self.assertIn('daily_heart_rate_variability.date', time_filter('daily-heart-rate-variability', '2026-09-22', '2026-09-30'))

    def test_exercise_requires_civil_session_time(self):
        query = time_filter('exercise', '2026-09-22', '2026-09-30')
        self.assertEqual(query, 'exercise.interval.civil_start_time >= "2026-09-22" AND exercise.interval.civil_start_time < "2026-09-30"')

    def test_sleep_respiratory_summary_is_a_sample(self):
        query = time_filter('respiratory-rate-sleep-summary', '2026-09-22', '2026-09-30')
        self.assertIn('respiratory_rate_sleep_summary.sample_time.physical_time', query)

    def test_unknown_metric_is_rejected(self):
        with self.assertRaises(ValueError):
            time_filter('nutrition-log', '2026-09-22', '2026-09-30')

    def test_missing_data_is_not_zero_measurement(self):
        self.assertEqual(summarize_points([])['record_count'], 0)
        summary = summarize_points([{'steps': {'interval': {'startTime': '2026-09-29T00:01:00Z',
                                                         'endTime': '2026-09-29T00:02:00Z'}, 'count': 0}}])
        self.assertEqual(summary['record_count'], 1)
        self.assertIn('steps.count', summary['numeric_fields'])

    def test_int64_step_strings_are_numeric_but_identifiers_are_not(self):
        summary = summarize_points([{'name': '12345', 'steps': {'count': '0'}},
                                    {'name': '67890', 'steps': {'count': '12'}}])
        self.assertEqual(summary['numeric_fields']['steps.count'], {'count': 2, 'min': 0, 'max': 12})
        self.assertNotIn('name', summary['numeric_fields'])


if __name__ == '__main__':
    unittest.main()

"""Bounded GET-only Health API access and structural coverage summaries."""
from collections import Counter
from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
import statistics
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener

from .oauth import NoRedirect, access_token, PRIVATE, private_json

# (filter prefix, record kind). No nutrition, GPS, or write endpoints.
METRICS = {
    'sleep': ('sleep', 'sleep'),
    'exercise': ('exercise', 'civil_session'),
    'steps': ('steps', 'interval'),
    'heart-rate': ('heart_rate', 'sample'),
    'daily-heart-rate-variability': ('daily_heart_rate_variability', 'daily'),
    'daily-resting-heart-rate': ('daily_resting_heart_rate', 'daily'),
    'heart-rate-variability': ('heart_rate_variability', 'sample'),
    'vo2-max': ('vo2_max', 'sample'),
    'daily-vo2-max': ('daily_vo2_max', 'daily'),
    'run-vo2-max': ('run_vo2_max', 'sample'),
    'daily-heart-rate-zones': ('daily_heart_rate_zones', 'daily'),
    'active-zone-minutes': ('active_zone_minutes', 'interval'),
    'daily-respiratory-rate': ('daily_respiratory_rate', 'daily'),
    'respiratory-rate-sleep-summary': ('respiratory_rate_sleep_summary', 'sample'),
    'daily-oxygen-saturation': ('daily_oxygen_saturation', 'daily'),
    'daily-sleep-temperature-derivations': ('daily_sleep_temperature_derivations', 'daily'),
}


class APIError(ValueError):
    def __init__(self, code, status):
        self.code, self.status = code, status
        super().__init__(f'Health API HTTP {code}: {status}')


def time_filter(metric, start, end):
    if metric not in METRICS:
        raise ValueError('Metric is outside this audit scope.')
    start_dt, end_dt = datetime.fromisoformat(start), datetime.fromisoformat(end)
    if end_dt <= start_dt:
        raise ValueError('The date interval must be positive.')
    prefix, kind = METRICS[metric]
    suffix = {'daily': 'date', 'sample': 'sample_time.physical_time',
              'interval': 'interval.start_time', 'sleep': 'interval.end_time',
              'civil_session': 'interval.civil_start_time'}[kind]
    if kind not in ('daily', 'civil_session'):
        start, end = start_dt.strftime('%Y-%m-%dT00:00:00Z'), end_dt.strftime('%Y-%m-%dT00:00:00Z')
    return f'{prefix}.{suffix} >= "{start}" AND {prefix}.{suffix} < "{end}"'


def fetch_pages(request, path, query, max_pages=200):
    points, seen = [], set()
    query = dict(query)
    for _ in range(max_pages):
        page = request(path, query)
        items = page.get('dataPoints', [])
        if not isinstance(items, list) or any(not isinstance(p, dict) for p in items):
            raise ValueError('API returned an unexpected record collection.')
        points.extend(items)
        token = page.get('nextPageToken')
        if not token:
            return points
        if not isinstance(token, str) or token in seen:
            raise ValueError('API pagination repeated a token; import is incomplete.')
        seen.add(token)
        query['pageToken'] = token
    raise ValueError('API pagination exceeded the bounded audit limit; import is incomplete.')


class HealthClient:
    def __init__(self):
        self.token = access_token()
        self.opener = build_opener(NoRedirect)

    def get(self, path, query=None):
        allowed_paths = {'users/me/profile'} | {
            f'users/me/dataTypes/{metric}/dataPoints{suffix}'
            for metric in METRICS for suffix in ('', ':reconcile')}
        if path not in allowed_paths:
            raise ValueError('Path is outside the read-only audit scope.')
        url = 'https://health.googleapis.com/v4/' + path
        if query:
            url += '?' + urlencode(query)
        refreshed = False
        for attempt in range(4):
            request = Request(url, method='GET', headers={'Authorization': 'Bearer ' + self.token,
                                                         'Accept': 'application/json'})
            try:
                with self.opener.open(request, timeout=45) as response:
                    data = json.load(response)
                if not isinstance(data, dict):
                    raise ValueError('Unexpected API response shape.')
                return data
            except HTTPError as exc:
                try:
                    payload = json.loads(exc.read(65536))
                except (ValueError, OSError):
                    payload = {}
                status = payload.get('error', {}).get('status', 'REQUEST_FAILED')
                if not isinstance(status, str) or not re.fullmatch(r'[A-Z_]{1,80}', status):
                    status = 'REQUEST_FAILED'
                # Diagnostic details may contain account identifiers; retain only privately.
                private_json(PRIVATE / 'last-api-error.json', {'path': path, 'http_code': exc.code,
                                                              'response': payload})
                if exc.code == 401 and not refreshed:
                    self.token = access_token(force_refresh=True)
                    refreshed = True
                    continue
                if exc.code in (429, 500, 502, 503, 504) and attempt < 3:
                    retry_after = exc.headers.get('Retry-After', '')
                    delay = min(30, int(retry_after)) if retry_after.isdigit() else 2 ** attempt
                    time.sleep(max(1, delay))
                    continue
                raise APIError(exc.code, status) from None
            except (URLError, TimeoutError):
                raise ValueError('Could not reach the Google Health API.') from None
        raise ValueError('Request retry limit reached.')


def record_event(point):
    """Return native daily date or UTC event time; no implied local-day normalization."""
    for metric, data in point.items():
        if metric in ('dataSource', 'originDataSource', 'metadata') or not isinstance(data, dict):
            continue
        if 'date' in data:
            date = data['date']
            if isinstance(date, dict) and all(k in date for k in ('year', 'month', 'day')):
                return f"{date['year']:04}-{date['month']:02}-{date['day']:02}"
            if isinstance(date, str):
                return date
        sample = data.get('sampleTime', {})
        if isinstance(sample, dict) and isinstance(sample.get('physicalTime'), str):
            return sample['physicalTime']
        interval = data.get('interval', {})
        if isinstance(interval, dict):
            event = interval.get('endTime' if metric == 'sleep' else 'startTime')
            if isinstance(event, str):
                return event
    return None


def summarize_points(points):
    fields, numbers, sources, dates, events = Counter(), {}, Counter(), Counter(), []
    fingerprints = set()
    def walk(value, prefix=''):
        if isinstance(value, dict):
            for key, item in value.items():
                walk(item, prefix + '.' + key if prefix else key)
        elif isinstance(value, list):
            for item in value:
                walk(item, prefix + '[]')
        else:
            fields[prefix] += 1
            # Protobuf int64 fields are JSON strings. Do not coerce identifiers.
            if prefix in ('steps.count', 'dailyHeartRateVariability.nonRemHeartRateBeatsPerMinute'):
                if isinstance(value, str) and re.fullmatch(r'-?\d{1,19}', value):
                    value = int(value)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                numbers.setdefault(prefix, []).append(value)
    for point in points:
        walk(point)
        fingerprints.add(hashlib.sha256(json.dumps(point, sort_keys=True).encode()).hexdigest())
        source = point.get('dataSource', {})
        if isinstance(source, dict):
            sources[str(source.get('platform', 'unspecified')) + '/' +
                    str(source.get('recordingMethod', 'unspecified'))] += 1
        event = record_event(point)
        if event:
            dates[event[:10]] += 1
            if 'T' in event:
                try:
                    timestamp = datetime.fromisoformat(event.replace('Z', '+00:00'))
                    if timestamp.tzinfo:
                        events.append(timestamp.timestamp())
                except ValueError:
                    pass
    distinct = sorted(set(events))
    gaps = [b - a for a, b in zip(distinct, distinct[1:]) if b > a]
    return {'record_count': len(points), 'exact_duplicate_count': len(points) - len(fingerprints),
            'days_with_records': len(dates), 'records_by_date': dict(sorted(dates.items())),
            'date_grouping': 'UTC event date or native daily-summary date; not normalized local days',
            'median_event_gap_seconds': statistics.median(gaps) if gaps else None,
            'max_event_gap_seconds': max(gaps) if gaps else None,
            'source_categories': dict(sources), 'field_presence_counts': dict(fields),
            'numeric_fields': {k: {'count': len(v), 'min': min(v), 'max': max(v)} for k, v in numbers.items()}}


def inspect(days=7):
    if not 1 <= days <= 90:
        raise ValueError('Choose between 1 and 90 days for the audit.')
    end = datetime.now(timezone.utc).date() + timedelta(days=1)
    start = end - timedelta(days=days)
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    directory = PRIVATE / 'imports' / run_id
    directory.mkdir(parents=True, mode=0o700)
    os_parent = directory.parent
    os_parent.chmod(0o700)
    client = HealthClient()
    report = {'start_date': str(start), 'end_date_exclusive': str(end), 'metrics': {},
              'note': 'Availability audit only; no health score or clinical interpretation.'}
    try:
        profile = client.get('users/me/profile')
        private_json(directory / 'profile.json', profile)
        report['profile'] = {'status': 'available', 'field_names': sorted(profile.keys())}
    except ValueError as exc:
        report['profile'] = {'status': 'error', 'error': str(exc)}
    print('Metric | status | records | days represented', flush=True)
    for metric in METRICS:
        try:
            # Seven-day chunks also keep wider audits modest in size.
            points, cursor = [], start
            while cursor < end:
                stop = min(cursor + timedelta(days=7), end)
                query = {'filter': time_filter(metric, str(cursor), str(stop)),
                         'pageSize': 25 if metric in ('sleep', 'exercise') else 10000}
                points.extend(fetch_pages(client.get, f'users/me/dataTypes/{metric}/dataPoints', query))
                cursor = stop
            private_json(directory / (metric + '.json'), {'dataPoints': points})
            summary = summarize_points(points)
            summary['status'] = 'available' if points else 'empty'
            report['metrics'][metric] = summary
            print(f"{metric} | {summary['status']} | {len(points)} | {summary['days_with_records']}", flush=True)
        except ValueError as exc:
            report['metrics'][metric] = {'status': 'error', 'error': str(exc)}
            print(f'{metric} | error | {exc}', flush=True)
        private_json(directory / 'report.json', report)
        private_json(PRIVATE / 'latest-audit.json', {'directory': str(directory), 'report': report})
    print(f'Private report saved: {directory / "report.json"}', flush=True)
    return report

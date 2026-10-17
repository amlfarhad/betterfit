"""Private, transactional replacement of fully fetched Google Health windows."""
from datetime import datetime, timezone
from contextlib import contextmanager
import hashlib
import json
import math
import re
from pathlib import Path
import sqlite3

from .api import METRICS


def payload_key(metric):
    head, *tail = metric.split('-')
    return head + ''.join(part.title() for part in tail)


def instant(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Observation timestamp is missing its UTC offset.')
    return result


def boundary(value):
    return datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp()


def coverage_union(windows):
    merged = []
    for start, end in sorted(windows):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def event_position(metric, point):
    data = point.get(payload_key(metric))
    if not isinstance(data, dict):
        raise ValueError('Data point does not match the requested metric.')
    kind = METRICS[metric][1]
    try:
        if kind == 'daily':
            d = data['date']
            return datetime(d['year'], d['month'], d['day'], tzinfo=timezone.utc).timestamp()
        if kind == 'sample':
            return instant(data['sampleTime']['physicalTime']).timestamp()
        interval = data['interval']
        stamp = instant(interval['endTime' if kind == 'sleep' else 'startTime']).timestamp()
        if kind == 'civil_session':
            stamp += float(interval['startUtcOffset'].removesuffix('s'))
        if metric == 'steps':
            value = data['count']
            if isinstance(value, bool) or str(value) != str(int(value)) or not 0 <= int(value) <= 1_000_000:
                raise ValueError('Step count must be a nonnegative integer.')
        return stamp
    except (KeyError, TypeError, OverflowError) as exc:
        raise ValueError('Malformed measurement time or value.') from exc


def record_identity(metric, point):
    named = point.get('dataPointName') or point.get('name')
    if named:
        return 'named:' + str(named)
    data = point[payload_key(metric)]
    # Payload values are not identity: a changed measurement must replace its old value.
    parts = {'source': point.get('dataSource'), 'event': event_position(metric, point),
             'intervalEnd': data.get('interval', {}).get('endTime')}
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()


def validate_point(metric, point):
    """Validate required scoring fields before a response can replace healthy cache data."""
    data = point[payload_key(metric)]
    def numeric(value, low=0, high=1_000_000):
        if isinstance(value, bool):raise ValueError('Boolean measurement.')
        value=float(value)
        if not math.isfinite(value) or not low<=value<=high:raise ValueError('Invalid measurement.')
        return value
    def offset(value):
        if not isinstance(value,str) or not re.fullmatch(r'-?\d+(?:\.\d+)?s',value):
            raise ValueError('Invalid observation offset.')
        numeric(value[:-1],-86400,86400)
    kind=METRICS[metric][1]
    try:
        if kind=='sample':offset(data['sampleTime']['utcOffset'])
        elif kind in ('interval','sleep','civil_session'):
            iv=data['interval'];a=instant(iv['startTime']);b=instant(iv['endTime'])
            if b<=a:raise ValueError('Nonpositive observation interval.')
            offset(iv['startUtcOffset']);offset(iv['endUtcOffset'])
        if metric=='heart-rate':numeric(data['beatsPerMinute'],1,400)
        elif metric=='daily-resting-heart-rate':
            numeric(data['beatsPerMinute'],1,400)
            metadata=data.get('dailyRestingHeartRateMetadata',{})
            if not isinstance(metadata,dict) or not isinstance(metadata.get('calculationMethod','UNSPECIFIED'),str):
                raise ValueError('Malformed resting-HR calculation metadata.')
        elif metric=='daily-heart-rate-variability':
            fields=('averageHeartRateVariabilityMilliseconds','nonRemHeartRateBeatsPerMinute','entropy','deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds')
            if not any(k in data for k in fields):raise ValueError('Missing daily HRV fields.')
            for key in fields:
                if key in data:numeric(data[key])
        elif metric=='sleep' and data.get('metadata',{}).get('processed'):
            s=data['summary'];a=numeric(s['minutesAsleep'],0,1440);w=numeric(s['minutesAwake'],0,1440);p=numeric(s['minutesInSleepPeriod'],1,1440)
            if a>p or abs(a+w-p)>1:raise ValueError('Inconsistent sleep summary.')
    except (KeyError,TypeError,OverflowError,AttributeError) as exc:
        raise ValueError('Malformed required measurement fields.') from exc


class SnapshotStore:
    def __init__(self, path):
        self.path = Path(path)
        if self.path.is_symlink() or self.path.parent.is_symlink():
            raise ValueError('Private store cannot use a symlink.')
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path.parent.chmod(0o700)
        self.db = sqlite3.connect(self.path)
        self.path.chmod(0o600)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS records (
                metric TEXT, identity TEXT, event REAL, payload TEXT,
                PRIMARY KEY(metric, identity));
            CREATE INDEX IF NOT EXISTS metric_event ON records(metric,event);
            CREATE TABLE IF NOT EXISTS windows (
                metric TEXT, start TEXT, end TEXT, checked_at TEXT,
                PRIMARY KEY(metric,start,end));
            CREATE TABLE IF NOT EXISTS freshness (
                metric TEXT PRIMARY KEY, last_attempt TEXT, last_success TEXT, last_error TEXT);
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS record_generations (
                metric TEXT, identity TEXT, generation TEXT, PRIMARY KEY(metric,identity));
            CREATE TABLE IF NOT EXISTS window_status (
                metric TEXT, start TEXT, end TEXT, last_attempt TEXT, last_success TEXT, last_error TEXT,
                PRIMARY KEY(metric,start,end));
            INSERT OR IGNORE INTO settings VALUES ('revision','0');
            INSERT OR IGNORE INTO record_generations
                SELECT metric,identity,COALESCE((SELECT MAX(checked_at) FROM windows WHERE windows.metric=records.metric),'1970-01-01T00:00:00Z') FROM records;
        ''')
        for suffix in ('-wal', '-shm'):
            sidecar = Path(str(self.path) + suffix)
            if sidecar.exists():
                sidecar.chmod(0o600)

    def close(self):
        self.db.close()

    @contextmanager
    def read_snapshot(self):
        """Bind records, coverage, profile and provenance to one committed revision."""
        if self.db.in_transaction:
            raise ValueError('A read snapshot cannot nest inside another transaction.')
        self.db.execute('BEGIN')
        try:
            self.revision()  # Pin the WAL read snapshot before yielding.
            yield self
        finally:
            self.db.rollback()

    def revision(self):
        return int(self.db.execute("SELECT value FROM settings WHERE key='revision'").fetchone()[0])

    def setting(self, key):
        row = self.db.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
        return row[0] if row else None

    def set_setting(self, key, value, affects_scores=False):
        with self.db:
            changed=self.setting(key)!=value
            self.db.execute('INSERT OR REPLACE INTO settings VALUES (?,?)', (key, value))
            if changed and affects_scores:
                self.db.execute("UPDATE settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")

    def record_failure(self, metric, at, reason, start=None, end=None):
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            if start is not None and end is not None:
                later=self.db.execute('SELECT last_attempt FROM window_status WHERE metric=? AND start<=? AND end>=?',(metric,start,end)).fetchall()
                if any(instant(row[0])>instant(at) for row in later):return
            prior=self.db.execute('SELECT last_attempt FROM freshness WHERE metric=?',(metric,)).fetchone()
            if not prior or instant(prior[0])<=instant(at):
                self.db.execute('''INSERT INTO freshness VALUES (?,?,NULL,?)
                    ON CONFLICT(metric) DO UPDATE SET last_attempt=excluded.last_attempt,
                    last_error=excluded.last_error''', (metric, at, reason))
            if start is not None and end is not None:
                self.db.execute('''INSERT INTO window_status VALUES (?,?,?,?,NULL,?)
                    ON CONFLICT(metric,start,end) DO UPDATE SET last_attempt=excluded.last_attempt,last_error=excluded.last_error''',
                                (metric,start,end,at,reason))

    def replace_window(self, metric, start, end, points, fetched_at, completed_at=None):
        if metric not in METRICS or boundary(end) <= boundary(start):
            raise ValueError('Invalid metric or query window.')
        instant(fetched_at)
        completed_at=completed_at or fetched_at
        instant(completed_at)
        staged = {}
        for point in points:
            event = event_position(metric, point)
            validate_point(metric,point)
            if not math.isfinite(event) or not boundary(start) <= event < boundary(end):
                raise ValueError('Data point falls outside the completed query window.')
            encoded = json.dumps(point, sort_keys=True, separators=(',', ':'), allow_nan=False)
            key = record_identity(metric, point)
            if key in staged and staged[key][1] != encoded:
                raise ValueError('Conflicting records in the same completed response.')
            staged[key] = (event, encoded)
        with self.db:
            self.db.execute('BEGIN IMMEDIATE')
            newer = self.db.execute('SELECT checked_at FROM windows WHERE metric=? AND start<? AND end>?',
                                    (metric, end, start)).fetchall()
            newer += self.db.execute('SELECT last_attempt FROM window_status WHERE metric=? AND start<? AND end>?',
                                     (metric,end,start)).fetchall()
            if any(instant(row[0]) > instant(fetched_at) for row in newer):
                raise ValueError('An older request cannot overwrite newer committed data.')
            for key in staged:
                prior=self.db.execute('SELECT generation FROM record_generations WHERE metric=? AND identity=?',(metric,key)).fetchone()
                if prior and instant(prior[0])>instant(fetched_at):
                    raise ValueError('An older named-record placement cannot replace its newer revision.')
            old = dict(self.db.execute('SELECT identity,payload FROM records WHERE metric=? AND event>=? AND event<?',
                                      (metric, boundary(start), boundary(end))))
            windows = self.db.execute('SELECT start,end FROM windows WHERE metric=?', (metric,)).fetchall()
            changed = (old != {key: value[1] for key, value in staged.items()}
                       or coverage_union(windows) != coverage_union(windows + [(start, end)]))
            self.db.execute('DELETE FROM records WHERE metric=? AND event>=? AND event<?',
                            (metric, boundary(start), boundary(end)))
            self.db.executemany('INSERT OR REPLACE INTO records VALUES (?,?,?,?)',
                                [(metric, key, value[0], value[1]) for key, value in staged.items()])
            self.db.executemany('INSERT OR REPLACE INTO record_generations VALUES (?,?,?)',
                                [(metric,key,fetched_at) for key in set(old)|set(staged)])
            self.db.execute('INSERT OR REPLACE INTO windows VALUES (?,?,?,?)', (metric, start, end, fetched_at))
            prior=self.db.execute('SELECT last_attempt,last_success FROM freshness WHERE metric=?',(metric,)).fetchone()
            last_attempt=max((prior[0],fetched_at),key=instant) if prior else fetched_at
            last_success=max((prior[1],completed_at),key=instant) if prior and prior[1] else completed_at
            self.db.execute('''INSERT INTO freshness VALUES (?,?,?,NULL)
                ON CONFLICT(metric) DO UPDATE SET last_attempt=excluded.last_attempt,
                last_success=excluded.last_success,last_error=NULL''', (metric, last_attempt, last_success))
            self.db.execute('''INSERT INTO window_status VALUES (?,?,?,?,?,NULL)
                ON CONFLICT(metric,start,end) DO UPDATE SET last_attempt=excluded.last_attempt,
                last_success=excluded.last_success,last_error=NULL''',(metric,start,end,fetched_at,completed_at))
            for a,b,failed_at in self.db.execute('SELECT start,end,last_attempt FROM window_status WHERE metric=? AND last_error IS NOT NULL',(metric,)).fetchall():
                reached=a
                for x,y,checked in self.db.execute('SELECT start,end,checked_at FROM windows WHERE metric=? ORDER BY start',(metric,)):
                    if instant(checked)>=instant(failed_at) and x<=reached<y:reached=y
                if reached>=b:self.db.execute('UPDATE window_status SET last_error=NULL WHERE metric=? AND start=? AND end=?',(metric,a,b))
            if changed:
                self.db.execute("UPDATE settings SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")
        return changed

    def records(self, metric):
        return [json.loads(row[0]) for row in self.db.execute(
            'SELECT payload FROM records WHERE metric=? ORDER BY event,identity', (metric,))]

    def complete_windows(self):
        result = {}
        for metric, start, end in self.db.execute('SELECT metric,start,end FROM windows'):
            result.setdefault(metric, []).append((start, end))
        return result

    def freshness(self):
        result={row[0]: {'lastAttemptAt': row[1], 'lastSuccessAt': row[2], 'lastError': row[3], 'windows':[]}
                for row in self.db.execute('SELECT * FROM freshness')}
        for metric,start,end,attempt,success,error in self.db.execute('SELECT * FROM window_status ORDER BY start'):
            result[metric]['windows'].append({'start':start,'end':end,'lastAttemptAt':attempt,'lastSuccessAt':success,'lastError':error})
            if error:result[metric]['lastError']=error
        for metric in result:
            row=self.db.execute('SELECT MAX(event) FROM records WHERE metric=?',(metric,)).fetchone()
            latest=datetime.fromtimestamp(row[0],timezone.utc) if row and row[0] is not None else None
            kind=METRICS[metric][1]
            result[metric]['latestMeasurementAt']=(latest.isoformat().replace('+00:00','Z') if latest and kind not in ('daily','civil_session') else None)
            result[metric]['latestNativeDate']=(latest.date().isoformat() if latest and kind in ('daily','civil_session') else None)
        return result

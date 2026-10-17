"""Strict canonical export for the shared Swift engine; no health scores here."""
from collections import defaultdict
from datetime import date, datetime, time, timedelta, timezone
import json
import math
from zoneinfo import ZoneInfo

from .store import instant, payload_key, boundary


def number(value, minimum, maximum):
    if isinstance(value, bool):
        raise ValueError('Boolean is not a measurement.')
    try:
        result = float(value)
    except (TypeError,OverflowError) as exc:
        raise ValueError('Measurement must be numeric.') from exc
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise ValueError('Measurement outside accepted numeric range.')
    return result


def normalize(records, profile, timezone_name, asof, complete_windows=None, sleep_target=480,
              source_policy='google-wearables:reconcile:v1'):
    zone = ZoneInfo(timezone_name)
    if asof.tzinfo is None:
        raise ValueError('Capture time must have a timezone.')
    age = number(profile.get('age'), 18, 120)
    target = number(sleep_target, 360, 720)
    today = asof.astimezone(zone).date()
    days, bins = {}, defaultdict(lambda: defaultdict(float))
    complete_windows = complete_windows or {}

    def bounds(d):
        return (datetime.combine(d, time.min, zone).timestamp(),
                datetime.combine(d + timedelta(days=1), time.min, zone).timestamp())

    def day(d):
        key = d.isoformat()
        if key not in days:
            begin, finish = bounds(d)
            days[key] = {'date': key, 'sourceKey': source_policy, 'dayDurationSeconds': finish-begin,
                         'elapsedSeconds': max(0, min(finish, asof.timestamp())-begin), 'isClosed': d < today,
                         'steps': None, 'stepsComplete': False, 'heartRateBins': [],
                         'rmssdMs': None, 'restingHeartRate': None, 'sleep': None, 'issues': []}
        return days[key]

    def flag(d, code):
        out = day(d)
        if code not in out['issues']:
            out['issues'].append(code)

    def timestamp(value, offset=None):
        stamp = instant(value)
        local = stamp.astimezone(zone)
        d = local.date()
        if offset is None or float(offset.removesuffix('s')) != local.utcoffset().total_seconds():
            flag(d, 'timezone_offset_mismatch')
        if stamp > asof:
            flag(d, 'future_observation')
        return stamp.timestamp(), d

    def unique(metric):
        seen = set()
        for point in records.get(metric, []):
            encoded = json.dumps(point, sort_keys=True, allow_nan=False)
            if encoded in seen:
                continue
            seen.add(encoded)
            source = point.get('dataSource', {})
            if source:
                raise ValueError('Raw source records cannot enter the reconciled scoring stream.')
            yield point[payload_key(metric)]

    hr = {}
    conflicts = set()
    for sample in unique('heart-rate'):
        t = sample['sampleTime']; stamp, d = timestamp(t['physicalTime'], t.get('utcOffset')); day(d)
        if stamp > asof.timestamp():
            continue
        try:
            value = number(sample['beatsPerMinute'], 25, 250)
        except (ValueError, TypeError):
            flag(d, 'invalid_heart_rate'); conflicts.add(stamp);hr[stamp]=None;continue
        if stamp in hr and hr[stamp] != value:
            flag(d, 'conflicting_heart_rate'); conflicts.add(stamp)
        hr[stamp] = value
    ordered = sorted(hr)
    for left, right in zip(ordered, ordered[1:]):
        if left in conflicts or right in conflicts or not 0 < right-left <= 60:
            continue
        cursor = left
        while cursor < right:
            d = datetime.fromtimestamp(cursor, zone).date(); stop = min(right, bounds(d)[1])
            bins[d.isoformat()][hr[left]] += stop-cursor; day(d);cursor=stop

    intervals = defaultdict(list)
    for sample in unique('steps'):
        interval = sample['interval']; start, d = timestamp(interval['startTime'], interval.get('startUtcOffset'))
        end, _ = timestamp(interval['endTime'], interval.get('endUtcOffset')); out=day(d)
        try:
            count = number(sample['count'], 0, 1_000_000)
            if count != int(count) or not 0 < end-start <= 86400 or end > asof.timestamp():
                raise ValueError('Invalid step interval.')
            if end > bounds(d)[1]:
                raise ValueError('Cannot divide interval step counts across midnight without inventing timing.')
        except (ValueError, TypeError):
            flag(d, 'invalid_steps');continue
        intervals[d].append((start,end,count))
        out['steps'] = (out['steps'] or 0) + count
    for d, entries in intervals.items():
        last_end = None
        for start,end,_ in sorted(entries):
            if last_end is not None and start < last_end:
                flag(d,'overlapping_steps')
            last_end = max(last_end or end,end)
        begin,finish = bounds(d)
        windows=sorted((boundary(a),boundary(b)) for a,b in complete_windows.get('steps',[]))
        reached=begin
        for a,b in windows:
            if a <= reached < b:reached=b
        out=day(d);out['stepsComplete']=reached>=finish and not any(x in out['issues'] for x in ('invalid_steps','overlapping_steps','timezone_offset_mismatch'))

    for metric, field, dest, minimum, maximum in (
        ('daily-heart-rate-variability','averageHeartRateVariabilityMilliseconds','rmssdMs',1,200),
        ('daily-resting-heart-rate','beatsPerMinute','restingHeartRate',25,250)):
        for sample in unique(metric):
            dt=sample['date'];d=date(dt['year'],dt['month'],dt['day']);out=day(d)
            try:value=number(sample[field],minimum,maximum)
            except (ValueError,TypeError,KeyError):flag(d,'invalid_'+dest);continue
            if out[dest] is not None and out[dest]!=value:
                flag(d,'conflicting_'+dest);out[dest]=None
            else:out[dest]=value
            if metric=='daily-resting-heart-rate':
                method=sample.get('dailyRestingHeartRateMetadata',{}).get('calculationMethod','UNSPECIFIED')
                out['sourceKey']=source_policy+'|rhr:'+method

    for sample in unique('sleep'):
        meta=sample.get('metadata',{})
        if meta.get('processed') is not True or meta.get('mainSleep') is not True:
            continue
        iv=sample['interval'];start,_=timestamp(iv['startTime'],iv.get('startUtcOffset'));end,d=timestamp(iv['endTime'],iv.get('endUtcOffset'));out=day(d)
        try:
            s=sample['summary'];asleep=number(s['minutesAsleep'],0,1440);period=number(s['minutesInSleepPeriod'],1,1440)
            awake=number(s['minutesAwake'],0,1440)
            if asleep>period or abs(asleep+awake-period)>1 or end<=start or end-start>86400:
                raise ValueError('Inconsistent sleep summary.')
            midpoint=datetime.fromtimestamp((start+end)/2,zone)
            normalized={'asleepMinutes':asleep,'periodMinutes':period,'midpointMinute':midpoint.hour*60+midpoint.minute+midpoint.second/60}
            if out['sleep'] is not None and out['sleep']!=normalized:
                flag(d,'multiple_main_sleeps');out['sleep']=None
            else:out['sleep']=normalized
        except (ValueError,TypeError,KeyError):flag(d,'invalid_sleep')

    for key,out in days.items():
        out['heartRateBins']=[{'bpm':bpm,'seconds':seconds} for bpm,seconds in sorted(bins[key].items())]
        out['issues'].sort()
    return {'schemaVersion':1,'generatedAt':asof.astimezone(timezone.utc).isoformat().replace('+00:00','Z'),
            'asOfDate':today.isoformat(),'ageYears':age,'sleepTargetMinutes':target,
            'measuredMaxHeartRate':None,'days':[days[k] for k in sorted(days) if k<=today.isoformat()]}

"""On-demand sync harness; no scheduling or background service is installed."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from zoneinfo import ZoneInfo

from .api import HealthClient, fetch_pages, time_filter
from .oauth import PRIVATE, private_json
from .store import SnapshotStore, instant
from .normalize import normalize

SCORING_METRICS=('steps','heart-rate','sleep','daily-heart-rate-variability','daily-resting-heart-rate')
SOURCE_FAMILY='users/me/dataSourceFamilies/google-wearables'


def refresh_due(now, last_attempt, visible, manual=False):
    return manual or (visible and (last_attempt is None or (now-last_attempt).total_seconds()>=60))


def plan_windows(now, last_success, last_repair, timezone_name='UTC', requested_days=None):
    zone=ZoneInfo(timezone_name)
    local_end=now.astimezone(zone).date()+timedelta(days=1)
    days=32 if last_success is None or last_repair is None or now-last_repair>=timedelta(days=7) else 3
    days=requested_days if requested_days is not None else days
    if not 1<=days<=90:raise ValueError('Sync window must be 1–90 days.')
    # Broaden date-only API predicates to contain complete local dates in either hemisphere.
    first=datetime.combine(local_end-timedelta(days=days),datetime.min.time(),zone).astimezone(timezone.utc)
    last=datetime.combine(local_end,datetime.min.time(),zone).astimezone(timezone.utc)
    start=first.date();end=last.date()+(timedelta(days=1) if last.time()!=datetime.min.time() else timedelta())
    result=[]
    while start<end:
        stop=min(start+timedelta(days=7),end);result.append((str(start),str(stop)));start=stop
    return result


def sync_metric(store, request, metric, start, end, fetched_at):
    query={'filter':time_filter(metric,start,end),'pageSize':25 if metric in ('sleep','exercise') else 10000,
           'dataSourceFamily':SOURCE_FAMILY}
    try:
        points=fetch_pages(request,f'users/me/dataTypes/{metric}/dataPoints:reconcile',query)
        return store.replace_window(metric,start,end,points,fetched_at,
                                    datetime.now(timezone.utc).isoformat().replace('+00:00','Z'))
    except (ValueError,OSError):
        store.record_failure(metric,fetched_at,'refresh_failed',start,end)
        raise


def sync(days=None):
    now=datetime.now(timezone.utc);stamp=now.isoformat().replace('+00:00','Z')
    store=SnapshotStore(PRIVATE/'cache.sqlite3');client=HealthClient()
    try:
        if store.setting('source_family') not in (None,SOURCE_FAMILY):
            raise ValueError('Source policy changed; a separate reconciled cache is required.')
        store.set_setting('source_family',SOURCE_FAMILY)
        old=store.setting('last_full_success');repair=store.setting('last_repair')
        windows=plan_windows(now,instant(old) if old else None,instant(repair) if repair else None,
                             'America/Los_Angeles',days)
        profile=client.get('users/me/profile');private_json(PRIVATE/'profile.json',profile)
        store.set_setting('profile_age',json.dumps(profile.get('age')),affects_scores=True)
        errors=[]
        for metric in SCORING_METRICS:
            for start,end in windows:
                try:
                    changed=sync_metric(store,client.get,metric,start,end,stamp)
                    print(f'{metric} {start}..{end}: '+('updated' if changed else 'unchanged'),flush=True)
                except ValueError as exc:
                    errors.append(metric);print(f'{metric}: {exc}',flush=True)
        if not errors:
            store.set_setting('last_full_success',stamp)
            span=(datetime.fromisoformat(windows[-1][1])-datetime.fromisoformat(windows[0][0])).days
            if days is None or days>=32:
                if span>=32:store.set_setting('last_repair',stamp)
        report={'capturedAt':stamp,'revision':store.revision(),'sourceFamily':SOURCE_FAMILY,
                'deviceLastSyncAt':None,'deviceSyncStatus':'requires_settings_readonly_scope_not_granted',
                'metrics':store.freshness(),'errors':sorted(set(errors)),
                'note':'On-demand Mac harness; no iPhone background behavior is claimed.'}
        private_json(PRIVATE/'sync-status.json',report)
        return report
    finally:store.close()


def export(timezone_name='America/Los_Angeles'):
    store=SnapshotStore(PRIVATE/'cache.sqlite3')
    try:
        with store.read_snapshot():
            age=store.setting('profile_age')
            if age is None:raise ValueError('Run sync before exporting canonical input.')
            profile={'age':json.loads(age)}
            data={metric:store.records(metric) for metric in SCORING_METRICS}
            complete_windows=store.complete_windows()
            revision=store.revision()
            freshness=store.freshness()
            asof=datetime.now(timezone.utc)
        bundle=normalize(data,profile,timezone_name,asof,complete_windows)
        manifest={'revision':revision,'timezone':timezone_name,'sourceFamily':SOURCE_FAMILY,
                  'generatedAt':bundle['generatedAt'],'freshness':freshness,
                  'ageProvenance':'current Google profile age in whole years; birth date unavailable',
                  'deviceLastSyncAt':None,'deviceSyncStatus':'settings_readonly_scope_not_granted'}
        # Authoritative provenance travels in the same atomic file as its measurements.
        bundle['provenance']=manifest
        private_json(PRIVATE/'engine-input.json',bundle)
        private_json(PRIVATE/'engine-input-provenance.json',manifest)
        print(f'Canonical engine input saved privately: {len(bundle["days"])} local dates.',flush=True)
        return bundle
    finally:store.close()

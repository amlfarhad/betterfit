import copy
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest

from fitbit_audit.store import SnapshotStore
from fitbit_audit.normalize import normalize
from fitbit_audit.sync import plan_windows, refresh_due, sync_metric


def step(start, count=10, end=None):
    return {'steps': {'interval': {'startTime': start, 'endTime': end or start.replace(':00Z', ':01Z'),
                                  'startUtcOffset': '0s', 'endUtcOffset': '0s'}, 'count': str(count)}}


def hr(stamp, bpm=100, offset='0s'):
    return {'heartRate': {'sampleTime': {'physicalTime': stamp, 'utcOffset': offset}, 'beatsPerMinute': bpm}}


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = SnapshotStore(Path(self.temp.name) / 'cache.sqlite3')

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def put(self, points, stamp='2026-09-29T12:00:00Z'):
        return self.store.replace_window('steps', '2026-09-28', '2026-09-29', points, stamp)

    def test_repeat_import_and_exact_duplicates_are_idempotent(self):
        p=step('2026-09-28T12:00:00Z')
        self.put([p,p]); first=self.store.revision()
        self.put([p], '2026-09-29T12:01:00Z')
        self.assertEqual(self.store.records('steps'), [p])
        self.assertEqual(self.store.revision(), first)
        self.assertEqual(self.store.freshness()['steps']['lastSuccessAt'], '2026-09-29T12:01:00Z')

    def test_correction_and_successful_empty_result_replace(self):
        self.put([step('2026-09-28T12:00:00Z', 10)])
        self.put([step('2026-09-28T12:00:00Z', 20)])
        self.assertEqual(self.store.records('steps')[0]['steps']['count'], '20')
        self.put([])
        self.assertEqual(self.store.records('steps'), [])

    def test_conflicting_payload_rejected_atomically(self):
        p=step('2026-09-28T12:00:00Z', 10);self.put([p]); before=self.store.revision()
        with self.assertRaises(ValueError):self.put([p,step('2026-09-28T12:00:00Z',20)])
        self.assertEqual(self.store.records('steps'),[p]);self.assertEqual(self.store.revision(),before)

    def test_older_fetch_cannot_replace_newer_snapshot(self):
        self.put([step('2026-09-28T12:00:00Z',20)],'2026-09-29T13:00:00Z')
        with self.assertRaises(ValueError):self.put([], '2026-09-29T12:00:00Z')
        self.assertEqual(len(self.store.records('steps')),1)

    def test_failed_refresh_keeps_records_and_success_timestamp(self):
        p=step('2026-09-28T12:00:00Z');self.put([p])
        def fail(*args):raise ValueError('Network unavailable')
        with self.assertRaises(ValueError):sync_metric(self.store,fail,'steps','2026-09-28','2026-09-29','2026-09-29T14:00:00Z')
        self.assertEqual(self.store.records('steps'),[p])
        self.assertEqual(self.store.freshness()['steps']['lastSuccessAt'],'2026-09-29T12:00:00Z')
        self.assertIsNotNone(self.store.freshness()['steps']['lastError'])

    def test_last_page_failure_does_not_commit_first_page(self):
        p=step('2026-09-28T12:00:00Z');self.put([p])
        def request(path,q):
            if q.get('pageToken'):raise ValueError('Page failed')
            return {'dataPoints':[step('2026-09-28T13:00:00Z')], 'nextPageToken':'next'}
        with self.assertRaises(ValueError):sync_metric(self.store,request,'steps','2026-09-28','2026-09-29','2026-09-29T14:00:00Z')
        self.assertEqual(self.store.records('steps'),[p])

    def test_moved_named_record_removes_old_placement(self):
        p=step('2026-09-28T12:00:00Z');p['dataPointName']='users/example/points/synthetic'
        self.put([p]);m=copy.deepcopy(p);m['steps']['interval'].update(startTime='2026-09-29T12:00:00Z',endTime='2026-09-29T12:01:00Z')
        self.store.replace_window('steps','2026-09-29','2026-09-30',[m],'2026-09-29T14:00:00Z')
        self.assertEqual(self.store.records('steps'),[m])

    def test_out_of_window_record_and_nan_rejected(self):
        for p in (step('2026-09-27T12:00:00Z'), step('2026-09-28T12:00:00Z',float('nan'))):
            with self.assertRaises(ValueError):self.put([p])
        self.assertEqual(self.store.records('steps'),[])

    def test_stale_disjoint_response_cannot_move_named_record_back(self):
        p=step('2026-09-28T12:00:00Z');p['dataPointName']='named-synthetic'
        self.put([p]);m=copy.deepcopy(p);m['steps']['interval'].update(startTime='2026-09-29T12:00:00Z',endTime='2026-09-29T12:01:00Z')
        self.store.replace_window('steps','2026-09-29','2026-09-30',[m],'2026-09-29T14:00:00Z')
        with self.assertRaises(ValueError):self.put([p],'2026-09-29T13:00:00Z')
        self.assertEqual(self.store.records('steps'),[m])

    def test_malformed_measurement_cannot_destroy_prior_valid_record(self):
        p=hr('2026-09-28T12:00:00Z'); self.store.replace_window('heart-rate','2026-09-28','2026-09-29',[p],'2026-09-29T12:00:00Z')
        bad=copy.deepcopy(p); del bad['heartRate']['beatsPerMinute']
        with self.assertRaises(ValueError):self.store.replace_window('heart-rate','2026-09-28','2026-09-29',[bad],'2026-09-29T13:00:00Z')
        self.assertEqual(self.store.records('heart-rate'),[p])

    def test_success_elsewhere_does_not_hide_failed_partition(self):
        self.put([step('2026-09-28T12:00:00Z')])
        self.store.record_failure('steps','2026-09-29T13:00:00Z','refresh_failed','2026-09-28','2026-09-29')
        self.store.replace_window('steps','2026-09-29','2026-09-30',[],'2026-09-29T14:00:00Z')
        self.assertEqual(self.store.freshness()['steps']['lastError'],'refresh_failed')
        self.put([],'2026-09-29T15:00:00Z')
        self.assertIsNone(self.store.freshness()['steps']['lastError'])

    def test_freshness_keeps_observation_separate_from_download_time(self):
        self.put([step('2026-09-28T12:00:00Z')])
        info=self.store.freshness()['steps']
        self.assertEqual(info['latestMeasurementAt'],'2026-09-28T12:00:00Z')
        self.assertEqual(info['lastSuccessAt'],'2026-09-29T12:00:00Z')

    def test_age_configuration_changes_invalidate_score_revision(self):
        before=self.store.revision();self.store.set_setting('profile_age','40',affects_scores=True)
        self.assertEqual(self.store.revision(),before+1)
        self.store.set_setting('profile_age','40',affects_scores=True)
        self.assertEqual(self.store.revision(),before+1)
        self.store.set_setting('profile_age','41',affects_scores=True)
        self.assertEqual(self.store.revision(),before+2)

    def test_late_failed_request_cannot_poison_newer_success(self):
        self.put([step('2026-09-28T12:00:00Z')],'2026-09-29T14:00:00Z')
        self.store.record_failure('steps','2026-09-29T13:00:00Z','refresh_failed','2026-09-28','2026-09-29')
        status=self.store.freshness()['steps']
        self.assertIsNone(status['lastError']);self.assertEqual(status['lastAttemptAt'],'2026-09-29T14:00:00Z')

    def test_stale_success_cannot_clear_newer_failure(self):
        p=step('2026-09-28T12:00:00Z');self.put([p])
        self.store.record_failure('steps','2026-09-29T16:00:00Z','refresh_failed','2026-09-28','2026-09-29')
        with self.assertRaises(ValueError):self.put([],'2026-09-29T15:00:00Z')
        self.assertEqual(self.store.records('steps'),[p])
        self.assertEqual(self.store.freshness()['steps']['lastAttemptAt'],'2026-09-29T16:00:00Z')

    def test_malformed_rhr_metadata_cannot_replace_good_data(self):
        p={'dailyRestingHeartRate':{'date':{'year':2026,'month':9,'day':28},'beatsPerMinute':60,
                                   'dailyRestingHeartRateMetadata':{'calculationMethod':'WITH_SLEEP'}}}
        self.store.replace_window('daily-resting-heart-rate','2026-09-28','2026-09-29',[p],'2026-09-29T12:00:00Z')
        bad=copy.deepcopy(p);bad['dailyRestingHeartRate']['dailyRestingHeartRateMetadata']='invalid'
        with self.assertRaises(ValueError):self.store.replace_window('daily-resting-heart-rate','2026-09-28','2026-09-29',[bad],'2026-09-29T13:00:00Z')
        self.assertEqual(self.store.records('daily-resting-heart-rate'),[p])

    def test_new_complete_coverage_changes_revision_even_with_same_records(self):
        p=step('2026-09-28T12:00:00Z');self.put([p]);before=self.store.revision()
        self.store.replace_window('steps','2026-09-27','2026-09-29',[p],'2026-09-29T14:00:00Z')
        self.assertEqual(self.store.revision(),before+1)
        self.store.replace_window('steps','2026-09-28','2026-09-29',[p],'2026-09-29T15:00:00Z')
        self.assertEqual(self.store.revision(),before+1)

    def test_read_snapshot_binds_measurements_to_revision_during_sync(self):
        p=step('2026-09-28T12:00:00Z',10);self.put([p])
        writer=SnapshotStore(self.store.path)
        try:
            with self.store.read_snapshot():
                before=self.store.revision()
                writer.replace_window('steps','2026-09-28','2026-09-29',[step('2026-09-28T12:00:00Z',20)],'2026-09-29T14:00:00Z')
                self.assertEqual(self.store.records('steps'),[p]);self.assertEqual(self.store.revision(),before)
            self.assertEqual(self.store.records('steps')[0]['steps']['count'],'20')
        finally:writer.close()


class NormalizeTests(unittest.TestCase):
    def bundle(self,data,zone='UTC',asof='2026-09-29T12:00:00Z'):
        return normalize(data,{'age':40},zone,datetime.fromisoformat(asof), complete_windows={'steps':[('2026-09-25','2026-10-01')]})

    def test_hr_time_weighting_gap_and_duplicate(self):
        p=[hr('2026-09-28T12:00:00Z'),hr('2026-09-28T12:00:02Z'),hr('2026-09-28T12:00:04Z'),hr('2026-09-28T12:05:00Z')]
        p.append(p[0]);d=self.bundle({'heart-rate':p})['days'][0]
        self.assertEqual(d['heartRateBins'],[{'bpm':100.0,'seconds':4.0}])

    def test_steps_strings_missing_and_overlap(self):
        d=self.bundle({'steps':[step('2026-09-28T12:00:00Z',10,'2026-09-28T12:01:00Z')]})['days'][0]
        self.assertEqual(d['steps'],10);self.assertTrue(d['stepsComplete'])
        h=self.bundle({'heart-rate':[hr('2026-09-28T12:00:00Z')]})['days'][0]
        self.assertIsNone(h['steps']);self.assertFalse(h['stepsComplete'])
        d=self.bundle({'steps':[step('2026-09-28T12:00:00Z',10,'2026-09-28T12:01:00Z'),step('2026-09-28T12:00:30Z',10,'2026-09-28T12:01:30Z')]})['days'][0]
        self.assertFalse(d['stepsComplete']);self.assertIn('overlapping_steps',d['issues'])

    def test_current_day_is_not_closed(self):
        d=self.bundle({'steps':[step('2026-09-29T10:00:00Z',0,'2026-09-29T10:01:00Z')]})['days'][0]
        self.assertFalse(d['isClosed']);self.assertEqual(d['elapsedSeconds'],43200)
        self.assertEqual(d['steps'],0)

    def test_spring_dst_and_midnight_split(self):
        data={'heart-rate':[hr('2026-03-08T07:59:50Z',100,'-28800s'),hr('2026-03-08T08:00:10Z',100,'-28800s')]}
        b=self.bundle(data,'America/Los_Angeles','2026-03-09T12:00:00Z')
        self.assertEqual([x['heartRateBins'][0]['seconds'] for x in b['days']], [10,10])
        self.assertEqual(b['days'][1]['dayDurationSeconds'],82800)

    def test_fall_dst_day_has_25_hours(self):
        b=self.bundle({'heart-rate':[hr('2026-11-01T12:00:00Z',100,'-28800s')]},'America/Los_Angeles','2026-11-02T12:00:00Z')
        self.assertEqual(b['days'][0]['dayDurationSeconds'],90000)

    def test_offset_mismatch_and_conflicting_hr_flagged(self):
        b=self.bundle({'heart-rate':[hr('2026-09-28T12:00:00Z',100,'-25200s'),hr('2026-09-28T12:00:00Z',110,'-25200s')]})
        self.assertIn('timezone_offset_mismatch',b['days'][0]['issues'])
        self.assertIn('conflicting_heart_rate',b['days'][0]['issues'])

    def test_raw_records_cannot_be_labeled_as_reconciled(self):
        p=hr('2026-09-28T12:00:00Z');p['dataSource']={'platform':'FITBIT','device':{'displayName':'Google Fitbit Air'}}
        with self.assertRaises(ValueError):self.bundle({'heart-rate':[p]})

    def test_sleep_uses_wake_date_and_summary_not_overlaid_awakenings(self):
        p={'sleep':{'interval':{'startTime':'2026-09-27T23:00:00Z','endTime':'2026-09-28T07:00:00Z','startUtcOffset':'0s','endUtcOffset':'0s'},'metadata':{'processed':True,'mainSleep':True},'summary':{'minutesAsleep':420,'minutesAwake':60,'minutesInSleepPeriod':480},'shortAwakenings':[{'type':'AWAKE'}]}}
        d=self.bundle({'sleep':[p]})['days'][0]
        self.assertEqual(d['date'],'2026-09-28');self.assertEqual(d['sleep']['asleepMinutes'],420)
        self.assertEqual(d['sleep']['midpointMinute'],180)


class SyncPolicyTests(unittest.TestCase):
    def test_initial_backfill_bounded_and_incremental_three_days(self):
        now=datetime(2026,9,29,tzinfo=timezone.utc)
        windows=plan_windows(now,None,None)
        self.assertEqual(windows[0][0],'2026-08-29');self.assertEqual(windows[-1][1],'2026-09-30')
        self.assertTrue(all((datetime.fromisoformat(b)-datetime.fromisoformat(a)).days<=7 for a,b in windows))
        self.assertEqual(plan_windows(now,now,now),[('2026-09-27','2026-09-30')])

    def test_poll_throttles_and_manual_refresh_is_explicit(self):
        now=datetime(2026,9,29,12,tzinfo=timezone.utc)
        self.assertFalse(refresh_due(now,now,visible=True))
        self.assertFalse(refresh_due(now,None,visible=False))
        self.assertTrue(refresh_due(now,now,visible=True,manual=True))

    def test_evening_pacific_refresh_contains_all_three_local_dates(self):
        now=datetime(2026,9,30,2,tzinfo=timezone.utc)  # Sep29 19:00 PDT
        windows=plan_windows(now,now,now,'America/Los_Angeles')
        self.assertEqual(windows,[('2026-09-27','2026-10-01')])

    def test_eastern_hemisphere_refresh_includes_previous_utc_date(self):
        now=datetime(2026,9,29,12,tzinfo=timezone.utc)
        windows=plan_windows(now,now,now,'Asia/Tokyo')
        self.assertEqual(windows,[('2026-09-26','2026-09-30')])


if __name__=='__main__':unittest.main()

"""Independent Python/Decimal checks of the compiled Swift engine on synthetic data."""
import argparse
from datetime import date, timedelta
from decimal import Decimal, localcontext
import json
import math
from pathlib import Path
import random
import subprocess
import tempfile


def bundle(age, totals, *, hrv=40, rhr=60, sleep=480, bpm=120):
    start=date(2026,8,25)
    days=[]
    for i,steps in enumerate(totals):
        days.append({'date':(start+timedelta(days=i)).isoformat(),'sourceKey':'synthetic',
                     'dayDurationSeconds':86400,'elapsedSeconds':86400,'isClosed':True,
                     'steps':steps,'stepsComplete':True,
                     'heartRateBins':[{'bpm':bpm,'seconds':86400}],
                     'rmssdMs':hrv,'restingHeartRate':rhr,
                     'sleep':{'asleepMinutes':sleep,'periodMinutes':max(sleep,480),'midpointMinute':180},
                     'issues':[]})
    as_of=(start+timedelta(days=len(totals))).isoformat()
    return {'schemaVersion':1,'generatedAt':as_of+'T12:00:00Z',
            'asOfDate':as_of,'ageYears':age,
            'sleepTargetMinutes':480,'measuredMaxHeartRate':200,'days':days}


def decimal_age(age, totals):
    with localcontext() as context:
        context.prec=50
        steps=list(map(Decimal,totals));mean=sum(steps)/7
        sd=(sum((x-mean)**2 for x in steps)/6).sqrt()
        return float(Decimal('4.2390852')+Decimal('1.0824163')*Decimal(age)
                     -Decimal('0.0012294')*max(steps)+Decimal('0.0015739')*sd)


def run(binary):
    rng=random.Random(20260929)
    cases=[(40,[8000]*7),(40,[2000,4000,6000,8000,10000,12000,14000]),(30,[0]*7)]
    cases += [(rng.randint(20,85),[rng.randint(0,22000) for _ in range(7)]) for _ in range(100)]
    checks=0;max_error=0.0
    with tempfile.TemporaryDirectory(prefix='fibit-reference-') as temp:
        path=Path(temp)/'input.json'
        def evaluate(data):
            path.write_text(json.dumps(data,allow_nan=False))
            result=subprocess.run([str(binary),str(path)],capture_output=True,text=True,check=True)
            return json.loads(result.stdout)
        for age,steps in cases:
            output=evaluate(bundle(age,steps));expected=decimal_age(age,steps)
            result=output['biologicalAge']['score']
            if not 0<=expected<=120:
                assert result['value'] is None and result['status']=='outOfDomain'
            else:
                error=abs(result['value']-expected);max_error=max(max_error,error)
                assert error<1e-9,(result['value'],expected)
            checks+=1
        # Independently assert the stated custom sleep function across durations.
        for minutes in (0,120,240,360,420,480,540,600):
            output=evaluate(bundle(40,[8000]*7,sleep=minutes))
            expected=80*min(minutes/480,1)+20*min(minutes/max(minutes,480)/.9,1)
            assert abs(output['days'][-1]['sleep']['value']-expected)<1e-9
            checks+=1
        # Constant baseline has zero MAD; floors should produce exactly 70.
        data=bundle(40,[8000]*29)
        output=evaluate(data)
        assert output['days'][6]['recovery']['value'] is None
        assert output['days'][7]['recovery']['status']=='provisional'
        assert abs(output['days'][7]['recovery']['value']-70)<1e-9
        assert output['days'][21]['recovery']['status']=='available'
        checks+=4
        # Hold duration fixed across zone boundaries: raw weighted load is known.
        for bpm,weight in ((99,0),(100,1),(119,1),(120,2),(140,3),(160,4),(180,5),(210,5)):
            output=evaluate(bundle(40,[8000]*7,bpm=bpm))
            strain=output['days'][-1]['strain'];load=1440*weight
            assert abs(strain['components']['rawLoad']-load)<1e-9
            expected=min(21,21*math.log1p(load/20)/math.log(31))
            assert abs(strain['value']-expected)<1e-9
            checks+=2
    return {'syntheticAgeCases':len(cases),'assertionGroups':checks,
            'maximumAgeAbsoluteErrorYears':max_error,'ageToleranceYears':1e-9,
            'seed':20260929,'status':'passed',
            'scope':'Software arithmetic and stated gates only; not clinical/device validation.'}


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('binary',type=Path)
    parser.add_argument('--output',type=Path);args=parser.parse_args()
    result=run(args.binary.resolve());text=json.dumps(result,indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(text+'\n')
    print(text)

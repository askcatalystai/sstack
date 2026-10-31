"""jobs.py upsert <id> <plan> <role> <provider> <model> <effort> <status> <log>: record one agent job for the board."""
import json,sys,time,fcntl,os
from pathlib import Path
STATE = Path(os.environ.get('COUNCIL_STATE') or (Path.home()/'.local/state/council/current')).resolve()
P = STATE/'dashboard'/'jobs.json'
def main():
    _,cmd,id,plan,role,provider,model,effort,status,log=sys.argv
    P.parent.mkdir(parents=True, exist_ok=True)
    with open(P,'a+') as f:
        fcntl.flock(f,fcntl.LOCK_EX); f.seek(0); raw=f.read()
        data=json.loads(raw) if raw.strip() else {'jobs':[]}
        now=time.strftime('%Y-%m-%dT%H:%M:%S%z')
        job=next((j for j in data['jobs'] if j['id']==id),None)
        if not job:
            job={'id':id,'startedAt':now}; data['jobs'].append(job)
        if status=='running' and job.get('status')!='running': job['startedAt']=now
        job.update({'plan':int(plan),'role':role,'provider':provider,'model':model,'effort':effort,'status':status,'log':log,'updatedAt':now})
        if status!='running': job['finishedAt']=now
        f.seek(0); f.truncate(); json.dump(data,f,indent=1)
main()

"""Fit the supplied knife to both real hand meshes; run sample_knife_hands.gd first.
python3 tools/solve_knife_grip.py /workspace/knife_work
Runtime pose verification: run tests/knife_logic.gd with an output JSON path, then
python3 tools/solve_knife_grip.py /workspace/knife_work --verify /path/to/runtime_grip.json
"""
import itertools,json,sys,pathlib
import numpy as np
from scipy import ndimage
from scipy.spatial.transform import Rotation
from make_torch_sdf import read_glb,accessor

ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path(sys.argv[1]);VOX=.0015;ORIGIN=np.array([-.10,-.10,-.30]);MAX=np.array([.10,.10,.09]);TOL=.0004
D,B=read_glb(ROOT/'assets/props/knife/kitchen_knife.glb');pr=D['meshes'][0]['primitives'][0];v=accessor(D,B,pr['attributes']['POSITION']);tri=accessor(D,B,pr['indices']).reshape(-1,3)
size=np.ceil((MAX-ORIGIN)/VOX).astype(int);surface=np.zeros(size[::-1],bool)
for ids in tri:
 a,b,c=v[ids].astype(float);n=max(1,int(np.ceil(max(np.linalg.norm(a-b),np.linalg.norm(a-c),np.linalg.norm(b-c))/(VOX*.5))));ii,jj=np.meshgrid(np.arange(n+1),np.arange(n+1),indexing='ij');keep=ii+jj<=n;p=a+np.outer(ii[keep]/n,b-a)+np.outer(jj[keep]/n,c-a);ix=np.floor((p-ORIGIN)/VOX).astype(int);good=np.all((ix>=0)&(ix<size),axis=1);ix=ix[good];surface[ix[:,2],ix[:,1],ix[:,0]]=True
solid=ndimage.binary_fill_holes(ndimage.binary_dilation(surface));sdf=(ndimage.distance_transform_edt(~solid)-ndimage.distance_transform_edt(solid))*VOX

def distance(p):
 coords=((p-ORIGIN)/VOX-.5)[...,::-1];return ndimage.map_coordinates(sdf,coords.reshape(-1,3).T,order=1,mode='constant',cval=1).reshape(p.shape[:-1])
def basis(a):
 yaw,pitch,roll=a;return Rotation.from_euler('y',yaw,degrees=True).as_matrix()@Rotation.from_euler('x',pitch,degrees=True).as_matrix()@Rotation.from_euler('z',roll,degrees=True).as_matrix()
if len(sys.argv)>3 and sys.argv[2]=='--verify':
 for side,data in json.loads(pathlib.Path(sys.argv[3]).read_text()).items():
  points=np.array(data['vertices']);triangles=np.array(data['triangles']).reshape(-1,3);faces=points[triangles]
  samples=np.concatenate([points,faces.mean(1),(faces[:,0]+faces[:,1])/2,(faces[:,1]+faces[:,2])/2,(faces[:,2]+faces[:,0])/2])
  worst=float(distance(samples).min());print(side,'actual posed hand clearance mm',round(worst*1000,3),flush=True)
  assert worst >= -TOL-.0001,(side,worst)
 sys.exit(0)
FINGERS=['thumb','index','middle','ring','pinky']
result={'scale':1.0,'model':'kitchen_knife.glb','forward':'-Z','up':'+Y','method':'Real skinned hand vertex/edge/face samples against 1.5 mm knife SDF; full closure path checked. Trigger does not change knife grip.'}
for side in ['left','right']:
 meta=json.loads((WORK/(side+'.json')).read_text());blob=(WORK/(side+'.bin')).read_bytes();full={k:np.ndarray((41,q['count'],3),dtype='<f4',buffer=blob,offset=q['offset']).astype(float) for k,q in meta['parts'].items()}
 def evaluate(angles,offset,quality=0):
  rot=basis(angles);blade=Rotation.from_euler('x',-45,degrees=True).as_matrix()@rot@np.array([0,0,-1.])
  if blade[2]>-.5:return None
  palm=full['palm'][0]
  pd=distance((palm-offset)@rot);pg=pd.min()
  if pg < -TOL:return None
  amounts={};gaps={};contact_z={}
  for finger in FINGERS:
   if distance((full[finger][0]-offset)@rot).min() < -TOL:return None
   pts=full[finger];steps=np.arange(0,41,4) if quality==0 else np.arange(41)
   if quality<2:pts=pts[:,::max(1,pts.shape[1]//(96 if quality==0 else 256))]
   p=(pts[steps]-offset)@rot;ds=distance(p);mins=ds.min(axis=1);bad=np.flatnonzero(mins < -TOL)
   if len(bad) and bad[0]==0:return None
   j=(bad[0]-1) if len(bad) else len(steps)-1;a=steps[j]/40;amounts[finger]=float(a);gaps[finger]=float(mins[j]);contact_z[finger]=float(p[j,ds[j].argmin(),2])
  # Every finger should meet the handle, rather than curl through air or onto the blade.
  touches=sum(.02<amounts[f]<.999 and gaps[f]<.012 and contact_z[f]>-.065 for f in FINGERS)
  score=touches*3+sum(amounts.values())*.4-130*max(0,pg-.002)-.008*abs(angles[0])-.002*abs(angles[1]-90)-.004*abs(angles[2])-5*np.linalg.norm(offset)
  return {'score':score,'angles':list(angles),'offset':list(offset),'amounts':amounts,'palm':float(pg),'gaps':gaps,'contact_z':contact_z,'touches':int(touches)}
 sign=1 if side=='left' else -1;best=None
 for pitch,yaw,roll,dx,dy,dz in itertools.product([45,70,90],[-15,0,15],[-10,0,10],[.015,.025,.035,.045],[-.012,0,.012],[-.02,0,.02]):
  r=evaluate([yaw,pitch,roll],np.array([sign*dx,dy,dz]))
  if r is not None and (best is None or r['score']>best['score']):best=r
 print('Coarse',side,best,flush=True)
 assert best is not None
 best=evaluate(best['angles'],np.array(best['offset']),1)
 for step,astep in [(.004,6),(.002,3),(.001,1.5)]:
  for _ in range(6):
   previous=best['score'];candidates=[]
   for axis in range(3):
    for direction in [-1,1]:
     off=np.array(best['offset']);off[axis]+=direction*step;candidates.append(evaluate(best['angles'],off,1))
     angles=np.array(best['angles']);angles[axis]+=direction*astep
     if abs(angles[0])<=30 and 30<=angles[1]<=105 and abs(angles[2])<=25:candidates.append(evaluate(angles,np.array(best['offset']),1))
   for r in candidates:
    if r is not None and r['score']>best['score']+.0001:best=r
   if best['score']<=previous+.0001:break
 final=evaluate(best['angles'],np.array(best['offset']),2)
 assert final is not None and final['touches']>=4,(side,final)
 a=final['amounts'];out={'yaw':float(best['angles'][0]),'pitch':float(best['angles'][1]),'roll':float(best['angles'][2]),'offset':[round(float(x),6) for x in best['offset']],'fingers':{'thumb':a['thumb'],'index_released':a['index'],'index_pressed':a['index'],'middle':a['middle'],'ring':a['ring'],'pinky':a['pinky']},'clearance_mm':{k:round(x*1000,3) for k,x in final['gaps'].items()},'palm_clearance_mm':round(final['palm']*1000,3),'handle_contacts':final['touches']}
 result[side]=out;print('Solved',side,json.dumps(out),flush=True)
p=ROOT/'assets/props/knife/grip_solution.json';p.write_text(json.dumps(result,indent=2)+'\n');print('Wrote',p,flush=True)

"""Restore the exact validated project layout; import licensed IP locally."""
from pathlib import Path
import argparse,hashlib,json,shutil
a=argparse.ArgumentParser();a.add_argument('--vendor-project',type=Path);a.add_argument('--out',type=Path,default=Path('build_workspace/candidate/project'));o=a.parse_args()
r=Path(__file__).resolve().parents[1];items=json.loads((r/'project_manifest.json').read_text())['files'];target=o.out.resolve()
sources=[]
for item in items:
 src=(o.vendor_project/item['project_path']) if item['external'] and o.vendor_project else (r/item['public_path'] if item['public_path'] else None)
 if src is None or not src.is_file():raise SystemExit('Missing dependency: '+item['project_path']+'; supply --vendor-project with your legally obtained matching project')
 if hashlib.sha256(src.read_bytes()).hexdigest()!=item['sha256']:raise SystemExit('Hash mismatch: '+str(src))
 dst=target/item['project_path']
 if dst.exists() and dst.read_bytes()!=src.read_bytes():raise SystemExit('Refusing to overwrite modified file: '+str(dst))
 sources.append((src,dst))
for src,dst in sources:
 dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
print('PASS exact project assembly:',len(sources),'files at',target)

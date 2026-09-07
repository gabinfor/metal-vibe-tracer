#!/usr/bin/env python3
"""Fetch the CC-BY-4.0 ASWF Standard Shader Ball, pinned for reproducible imports."""
import pathlib,json,urllib.request,hashlib,concurrent.futures
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMIT='3b75c2dad6a494897557dcca0098257bcf42a8c6'
DEST=ROOT/'build/reference-scenes/StandardShaderBall'
def fetch(item):
    path=item['path'];relative=path.split('full_assets/StandardShaderBall/',1)[1]
    target=DEST/relative;target.parent.mkdir(parents=True,exist_ok=True)
    if target.exists() and hashlib.sha1(b'blob '+str(target.stat().st_size).encode()+b'\0'+target.read_bytes()).hexdigest()==item['sha']:data=target.read_bytes()
    else:
        with urllib.request.urlopen('https://raw.githubusercontent.com/usd-wg/assets/'+COMMIT+'/'+path,timeout=90) as response:data=response.read()
        if hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()!=item['sha']:raise ValueError('Git object checksum mismatch: '+path)
        target.write_bytes(data)
    return {'path':relative,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}
with urllib.request.urlopen('https://api.github.com/repos/usd-wg/assets/git/trees/'+COMMIT+'?recursive=1',timeout=30) as response:tree=json.load(response)['tree']
files=[x for x in tree if x['type']=='blob' and x['path'].startswith('full_assets/StandardShaderBall/') and not any('/'+d+'/' in x['path'] for d in ('media','src','cards','thumbnails'))]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:manifest=list(pool.map(fetch,files))
(DEST/'DOWNLOAD.json').write_text(json.dumps({'repository':'https://github.com/usd-wg/assets','commit':COMMIT,'license':'CC-BY-4.0','files':manifest},indent=2))
(DEST.parent/'ShaderBall-triangulated.usda').write_bytes((ROOT/'Examples/OpenUSD/ShaderBall-triangulated.usda').read_bytes())
print('Downloaded reference to',DEST)
print('Open',DEST.parent/'ShaderBall-triangulated.usda')

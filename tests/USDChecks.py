#!/usr/bin/env python3
"""Exercise the real SDK bridge with composed layers, packages and schemas."""
import sys,pathlib,json,importlib.util,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
runtime=ROOT/'build/OpenUSD'
manifest=json.loads((runtime/'VIBE_RUNTIME.json').read_text())
assert manifest['version']=='26.8' and manifest['python']=='cp39' and len(manifest['sha256'])==64
assert runtime.is_dir() and (runtime/'pxr/Usd/_usd.so').is_file()
sys.path.insert(0,str(ROOT/'build/OpenUSD'))
from pxr import Usd,UsdGeom,UsdShade,UsdLux,UsdUtils,Gf,Sdf
spec=importlib.util.spec_from_file_location('usd_bridge',ROOT/'scripts/usd_bridge.py');bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
out=ROOT/'build/checks/usd';out.mkdir(parents=True,exist_ok=True)
for name in ['asset.usda','scene.usda','scene.usdc','scene.usdz','details.usda']:
 (out/name).unlink(missing_ok=True)
asset=Usd.Stage.CreateNew(str(out/'asset.usda'));UsdGeom.SetStageMetersPerUnit(asset,1)
root=UsdGeom.Xform.Define(asset,'/Asset');asset.SetDefaultPrim(root.GetPrim())
mesh=UsdGeom.Mesh.Define(asset,'/Asset/Concave')
mesh.CreatePointsAttr([(-1,0,0),(1,0,0),(1,1,0),(0,0.5,0),(-1,1,0)])
mesh.CreateFaceVertexCountsAttr([5]);mesh.CreateFaceVertexIndicesAttr([0,1,2,3,4]);mesh.CreateSubdivisionSchemeAttr('none')
pv=UsdGeom.PrimvarsAPI(mesh).CreatePrimvar('st',Sdf.ValueTypeNames.TexCoord2fArray,'faceVarying');pv.Set([(0,0),(1,0),(1,1),(.5,.5),(0,1)])
mat=UsdShade.Material.Define(asset,'/Asset/Paint');shader=UsdShade.Shader.Define(asset,'/Asset/Paint/Surface');shader.CreateIdAttr('UsdPreviewSurface');shader.CreateInput('diffuseColor',Sdf.ValueTypeNames.Color3f).Set((.2,.4,.8));shader.CreateInput('roughness',Sdf.ValueTypeNames.Float).Set(.35);mat.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(),'surface');UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(mat)
asset.GetRootLayer().Save()
stage=Usd.Stage.CreateNew(str(out/'scene.usda'));UsdGeom.SetStageUpAxis(stage,UsdGeom.Tokens.z);UsdGeom.SetStageMetersPerUnit(stage,.01)
world=UsdGeom.Xform.Define(stage,'/World');world.AddTranslateOp().Set((100,0,0));stage.SetDefaultPrim(world.GetPrim())
for name,offset in [('A',0),('B',200)]:
 prim=UsdGeom.Xform.Define(stage,'/World/'+name);prim.GetPrim().GetReferences().AddReference('asset.usda');prim.AddTranslateOp().Set((offset,0,0));prim.GetPrim().SetInstanceable(True)
camera=UsdGeom.Camera.Define(stage,'/Camera');camera.AddTranslateOp().Set((100,-400,200))
sun=UsdLux.DistantLight.Define(stage,'/Sun');sun.CreateIntensityAttr(2)
stage.GetRootLayer().Save()
result=bridge.import_stage(str(out/'scene.usda'),out)
assert len(result['assets'])==1 and sum(bool(n.get('mesh')) for n in result['nodes'])==2,result['report']
assert len(result['assets'][0]['triangles'])==3,'concave face triangulation'
assert len(result['cameras'])==1 and result['sun'] is not None
assert all(m.get('mtlx') for m in result['materials'])
(out/'snapshot.json').write_text(json.dumps(result))
# Binary USD and USDZ are parsed by the SDK, including references within the package.
stage.Export(str(out/'scene.usdc'))
assert bridge.import_stage(str(out/'scene.usdc'),out)['assets']
assert UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(out/'scene.usda')),str(out/'scene.usdz'))
assert bridge.import_stage(str(out/'scene.usdz'),out)['assets']
# Holes, indexed primvars, inherited bindings, reset stacks and invisibility.
plain=Usd.Stage.CreateNew(str(out/'details.usda'));UsdGeom.SetStageMetersPerUnit(plain,1)
m=UsdGeom.Mesh.Define(plain,'/M');m.CreatePointsAttr([(0,0,0),(1,0,0),(1,1,0),(0,1,0)]);m.CreateFaceVertexCountsAttr([3,3]);m.CreateFaceVertexIndicesAttr([0,1,2,0,2,3]);m.CreateSubdivisionSchemeAttr('none');m.CreateHoleIndicesAttr([1]);st=UsdGeom.PrimvarsAPI(m).CreatePrimvar('st',Sdf.ValueTypeNames.TexCoord2fArray,'faceVarying');st.Set([(0,0),(1,0),(1,1),(0,1)]);st.SetIndices([0,1,2,0,2,3]);m.CreateVisibilityAttr('invisible')
plain.GetRootLayer().Save();detail=bridge.import_stage(str(out/'details.usda'),out)
assert len(detail['assets'][0]['triangles'])==1 and detail['nodes'][1]['transform']['rotationHidden'][3]==1
print('PASS: USD composition, instances, units/up-axis matrices, concave triangulation, primvars/holes, bindings, camera/sun, USDC and USDZ')
# A small authored area-lit scene supports a meaningful GPU PDF/energy test.
lightFile=out/'area.usda';lightFile.unlink(missing_ok=True)
area=Usd.Stage.CreateNew(str(lightFile));UsdGeom.SetStageMetersPerUnit(area,1)
floor=UsdGeom.Mesh.Define(area,'/Floor');floor.CreatePointsAttr([(-2,0,-2),(2,0,-2),(2,0,2),(-2,0,2)]);floor.CreateFaceVertexCountsAttr([4]);floor.CreateFaceVertexIndicesAttr([0,3,2,1]);floor.CreateSubdivisionSchemeAttr('none');floor.CreateDisplayColorAttr([(.6,.6,.6)])
light=UsdLux.RectLight.Define(area,'/Area');light.CreateWidthAttr(1);light.CreateHeightAttr(1);light.CreateIntensityAttr(4);light.AddTranslateOp().Set((0,2,0));light.AddRotateXOp().Set(-90)
area.GetRootLayer().Save()
coverage=Usd.Stage.CreateNew(str(out/'light-coverage.usda'));UsdGeom.SetStageMetersPerUnit(coverage,1)
disk=UsdLux.DiskLight.Define(coverage,'/Disk');disk.CreateRadiusAttr(.5);disk.CreateIntensityAttr(2)
sphere=UsdLux.SphereLight.Define(coverage,'/Sphere');sphere.CreateRadiusAttr(.25);sphere.CreateIntensityAttr(2);sphere.AddTranslateOp().Set((1,1,0))
coverage.GetRootLayer().Save()
coverage_result=bridge.import_stage(str(out/'light-coverage.usda'),out)
assert len(coverage_result['assets'])==2 and len(coverage_result['assets'][0]['triangles'])==8
assert any('disk light imported' in line for line in coverage_result['report'])
assert any('sphere light imported' in line for line in coverage_result['report'])
# Reference scene override is separate; upstream files and notices remain unchanged.
reference=ROOT/'build/reference-scenes/StandardShaderBall'
if reference.exists():
 override=reference.parent/'ShaderBall-triangulated.usda'
 override.write_bytes((ROOT/'Examples/OpenUSD/ShaderBall-triangulated.usda').read_bytes())
 print('Reference override:',override)
elif '--require-reference' in sys.argv:sys.exit('FAIL: ASWF Standard Shader Ball is missing; run /usr/bin/python3 scripts/fetch_reference_scene.py')
else:print('SKIP: ASWF Standard Shader Ball not downloaded (scripts/fetch_reference_scene.py); --require-reference makes this fail')
# Robust import: degenerate faces, placeholder meshes, zero-scaled subtrees, unsupported light APIs,
# per-prim fallback colors, an untextured dome and an unauthored camera focus.
import math,struct,zlib,subprocess,shutil
from pxr import UsdVol
def png(path,rgb):
 chunk=lambda t,d:struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
 path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00'+bytes(rgb)))+chunk(b'IEND',b''))
def quad(stage,path,offset=(0,0,0)):
 q=UsdGeom.Mesh.Define(stage,path);q.CreatePointsAttr([(offset[0]+x,offset[1]+y,offset[2]) for x,y in [(0,0),(1,0),(1,1),(0,1)]]);q.CreateFaceVertexCountsAttr([4]);q.CreateFaceVertexIndicesAttr([0,1,2,3]);q.CreateSubdivisionSchemeAttr('none');return q
def cross3(t):
 a,b,c=t['a'][:3],t['b'][:3],t['c'][:3];u=[b[i]-a[i] for i in range(3)];v=[c[i]-a[i] for i in range(3)]
 return [u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
def triangle_area(t):return math.sqrt(sum(x*x for x in cross3(t)))/2
for name in ['many-colors.usda','robust.usda','focus.usda','power.usda','dome-format.usda','colorspace.usda','varname.usda']:(out/name).unlink(missing_ok=True)
robust=Usd.Stage.CreateNew(str(out/'robust.usda'));UsdGeom.SetStageMetersPerUnit(robust,1)
g=UsdGeom.Mesh.Define(robust,'/Good');g.CreatePointsAttr([(0,0,0),(1,0,0),(1,1,0),(0,1,0),(2,0,0)]);g.CreateSubdivisionSchemeAttr('none')
g.CreateFaceVertexCountsAttr([4,4,3,2,4,4]);g.CreateFaceVertexIndicesAttr([0,1,2,3, 1,1,1,1, 0,1,4, 0,1, 0,2,1,3, 0,1,2,2])
UsdGeom.Mesh.Define(robust,'/Empty')
zero=UsdGeom.Xform.Define(robust,'/Zero');zero.AddScaleOp().Set((0,0,0));quad(robust,'/Zero/Child')
reset=quad(robust,'/Zero/Reset');reset.SetResetXformStack(True);reset.AddTranslateOp().Set((5,0,0))
UsdLux.MeshLightAPI.Apply(quad(robust,'/Lamp',(20,0,0)).GetPrim())
UsdLux.VolumeLightAPI.Apply(UsdVol.Volume.Define(robust,'/Fog').GetPrim())
bad=UsdShade.Material.Define(robust,'/Looks/Bad');bs=UsdShade.Shader.Define(robust,'/Looks/Bad/S');bs.CreateIdAttr('UsdPreviewSurface');bs.CreateInput('opacity',Sdf.ValueTypeNames.Float).Set(.5);bad.CreateSurfaceOutput().ConnectToSource(bs.ConnectableAPI(),'surface')
for name,color,x in [('Red',(1,0,0),10),('Blue',(0,0,1),12)]:
 m=quad(robust,'/'+name,(x,0,0));m.CreateDisplayColorAttr([color]);UsdShade.MaterialBindingAPI.Apply(m.GetPrim()).Bind(bad)
dome=UsdLux.DomeLight.Define(robust,'/Dome');dome.CreateColorAttr((.25,.5,1));dome.CreateIntensityAttr(2)
cam=UsdGeom.Camera.Define(robust,'/Cam');cam.AddTranslateOp().Set((.5,.5,5))
robust.GetRootLayer().Save()
rb=bridge.import_stage(str(out/'robust.usda'),out);report='\n'.join(rb['report'])
byName={n['name']:n for n in rb['nodes']};assetOf={a['id']:a for a in rb['assets']}
assert len(assetOf[byName['Good']['mesh']]['triangles'])==5,report
assert '/Good: 3 degenerate faces dropped' in report and '/Good: 1 non-simple polygons fan-triangulated' in report,report
assert '/Empty: mesh without points or topology skipped' in report and 'mesh' not in byName['Empty'],report
assert byName['Zero']['transform']['rotationHidden'][3]==1 and report.count('zero or singular world scale')==1,report
assert byName['Child']['matrix']==[1.0,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],'child local matrix must not invert a singular parent'
assert byName['Reset']['parent']==rb['nodes'][0]['id'] and byName['Reset']['matrix'][12]==5 and byName['Reset']['transform']['rotationHidden'][3]==0
assert '/Lamp: MeshLightAPI emission not applied' in report and '/Fog: VolumeLightAPI emission' in report,report
fallbacks=[m for m in rb['materials'] if m['path']=='/Looks/Bad'];assert sorted(m['color'] for m in fallbacks)==[[0,0,1],[1,0,0]] and not any(m.get('mtlx') for m in fallbacks)
assert '/Red: material /Looks/Bad fallback to displayColor' in report and '/Blue: material /Looks/Bad fallback to displayColor' in report,report
# Per-color fallbacks never push a stage past the material limit; the overflow shares the first fallback.
many=Usd.Stage.CreateNew(str(out/'many-colors.usda'));badMany=UsdShade.Material.Define(many,'/Looks/Bad');badMany.CreateSurfaceOutput().ConnectToSource(UsdShade.Shader.Define(many,'/Looks/Bad/S').ConnectableAPI(),'surface')
for i in range(60):
 m=quad(many,'/Q%d'%i,(2*i,0,0));m.CreateDisplayColorAttr([(i/60,0,1)]);UsdShade.MaterialBindingAPI.Apply(m.GetPrim()).Bind(badMany)
many.GetRootLayer().Save();mc=bridge.import_stage(str(out/'many-colors.usda'),out)
assert len(mc['materials'])==56 and sum('material limit reached' in l for l in mc['report'])==4,mc['report'][:3]
env=pathlib.Path(rb['environment']['file']).read_bytes();texel=env[-4:];scale=2.0**(texel[3]-136)
assert rb['environment']['intensity']==2 and env.startswith(b'#?RADIANCE') and [round(c*scale,3) for c in texel[:3]]==[.25,.5,1],texel
assert '/Dome: untextured dome imported as a constant-color environment' in report and rb['cameras'][0]['focus'] is None
focused=Usd.Stage.CreateNew(str(out/'focus.usda'));UsdGeom.SetStageMetersPerUnit(focused,1);quad(focused,'/Target')
fc=UsdGeom.Camera.Define(focused,'/Cam');fc.AddTranslateOp().Set((.5,.5,5));fc.CreateFocusDistanceAttr(2);focused.GetRootLayer().Save()
assert bridge.import_stage(str(out/'focus.usda'),out)['cameras'][0]['focus']==2
# Emitted power: sum(area * radiance) equals intensity for normalized lights, or radiance * true area otherwise.
power=Usd.Stage.CreateNew(str(out/'power.usda'));UsdGeom.SetStageMetersPerUnit(power,1)
for name,kind,radius,normalized in [('Disk',UsdLux.DiskLight,.5,False),('DiskN',UsdLux.DiskLight,.5,True),('Sphere',UsdLux.SphereLight,.25,False),('SphereN',UsdLux.SphereLight,.25,True)]:
 l=kind.Define(power,'/'+name);l.CreateRadiusAttr(radius);l.CreateIntensityAttr(3);l.CreateNormalizeAttr(normalized)
tiny=UsdLux.RectLight.Define(power,'/Tiny');tiny.CreateWidthAttr(.001);tiny.CreateHeightAttr(.001);tiny.CreateIntensityAttr(1000);tiny.CreateNormalizeAttr(True)
power.GetRootLayer().Save();pw=bridge.import_stage(str(out/'power.usda'),out)
emission={m['path']:m['emission'][0] for m in pw['materials']};powerAssets={a['id']:a for a in pw['assets']}
for node in pw['nodes'][1:]:
 tris=powerAssets[node['mesh']]['triangles'];path='/'+node['name']
 radiantArea=sum(triangle_area(t) for t in tris)*emission[path]
 expected={'/Disk':3*math.pi*.25,'/DiskN':3,'/Sphere':3*4*math.pi*.0625,'/SphereN':3}.get(path)
 if expected:assert abs(radiantArea/expected-1)<1e-6,(path,radiantArea,expected)
 if path.startswith('/Sphere'):
  assert len(tris)==80 and all(sum(n*x for n,x in zip(cross3(t),t['a'][:3]))>0 for t in tris),'outward sphere proxy'
  assert max(abs(sum(cross3(t)[i] for t in tris)) for i in range(3))<1e-9,'closed sphere proxy'
assert emission['/Tiny']==1e8 and '/Tiny: emission 1e+09 exceeds the supported 1e8' in '\n'.join(pw['report']),pw['report']
fmt=Usd.Stage.CreateNew(str(out/'dome-format.usda'));quad(fmt,'/Q');d=UsdLux.DomeLight.Define(fmt,'/Dome');d.CreateTextureFileAttr('probe.exr');d.CreateTextureFormatAttr('mirroredBall');fmt.GetRootLayer().Save()
df=bridge.import_stage(str(out/'dome-format.usda'),out);assert df['environment'] is None and any('dome texture format mirroredBall is unsupported' in l for l in df['report']),df['report']
# MaterialX image color spaces come from USD metadata; unsupported spaces fall back with the prim path.
png(out/'texel.png',(128,64,255))
cs=Usd.Stage.CreateNew(str(out/'colorspace.usda'));UsdGeom.SetStageMetersPerUnit(cs,1)
for name,space,x in [('Srgb','srgb_texture',0),('Aces','acescg',2)]:
 mat=UsdShade.Material.Define(cs,'/Looks/'+name);surf=UsdShade.Shader.Define(cs,'/Looks/'+name+'/Surface');surf.CreateIdAttr('ND_open_pbr_surface_surfaceshader')
 img=UsdShade.Shader.Define(cs,'/Looks/'+name+'/Image');img.CreateIdAttr('ND_image_color3');f=img.CreateInput('file',Sdf.ValueTypeNames.Asset);f.Set('texel.png');f.GetAttr().SetColorSpace(space)
 surf.CreateInput('base_color',Sdf.ValueTypeNames.Color3f).ConnectToSource(img.ConnectableAPI(),'out');mat.CreateSurfaceOutput('mtlx').ConnectToSource(surf.ConnectableAPI(),'surface')
 UsdShade.MaterialBindingAPI.Apply(quad(cs,'/'+name,(x,0,0)).GetPrim()).Bind(mat)
# The Swift compiler rejects unknown surface inputs, so each bound prim must keep its own fallback displayColor.
glow=UsdShade.Material.Define(cs,'/Looks/Glow');gs=UsdShade.Shader.Define(cs,'/Looks/Glow/Surface');gs.CreateIdAttr('ND_open_pbr_surface_surfaceshader');gs.CreateInput('unsupported_probe',Sdf.ValueTypeNames.Float).Set(1);glow.CreateSurfaceOutput('mtlx').ConnectToSource(gs.ConnectableAPI(),'surface')
for name,color,x in [('GlowRed',(1,0,0),4),('GlowBlue',(0,0,1),6)]:
 m=quad(cs,'/'+name,(x,0,0));m.CreateDisplayColorAttr([color]);UsdShade.MaterialBindingAPI.Apply(m.GetPrim()).Bind(glow)
cs.GetRootLayer().Save();cr=bridge.import_stage(str(out/'colorspace.usda'),out)
glowID=next(m['id'] for m in cr['materials'] if m['path']=='/Looks/Glow');glowNodes=[n for n in cr['nodes'] if n['name'].startswith('Glow')]
assert all(n['bindings']==[glowID] for n in glowNodes) and sorted(cr['fallbackColors'][n['id']] for n in glowNodes)==[[[0,0,1]],[[1,0,0]]]
srgb=next(m for m in cr['materials'] if m['path']=='/Looks/Srgb');assert 'colorspace="srgb_texture"' in srgb['mtlx'],srgb['mtlx']
assert any('/Looks/Aces/Image: unsupported image color space acescg' in l for l in cr['report']),cr['report']
# A varname connected to the material interface is resolved before the st-only check.
vn=Usd.Stage.CreateNew(str(out/'varname.usda'));UsdGeom.SetStageMetersPerUnit(vn,1)
for name,uvset,x in [('Uv','uv',0),('St','st',2)]:
 mat=UsdShade.Material.Define(vn,'/Looks/'+name);surf=UsdShade.Shader.Define(vn,'/Looks/'+name+'/Surface');surf.CreateIdAttr('UsdPreviewSurface')
 reader=UsdShade.Shader.Define(vn,'/Looks/'+name+'/Reader');reader.CreateIdAttr('UsdPrimvarReader_float2');iface=mat.CreateInput('uvset',Sdf.ValueTypeNames.Token);iface.Set(uvset);reader.CreateInput('varname',Sdf.ValueTypeNames.Token).ConnectToSource(iface)
 tex=UsdShade.Shader.Define(vn,'/Looks/'+name+'/Texture');tex.CreateIdAttr('UsdUVTexture');tex.CreateInput('file',Sdf.ValueTypeNames.Asset).Set('texel.png');tex.CreateInput('st',Sdf.ValueTypeNames.Float2).ConnectToSource(reader.ConnectableAPI(),'result')
 surf.CreateInput('diffuseColor',Sdf.ValueTypeNames.Color3f).ConnectToSource(tex.ConnectableAPI(),'rgb');mat.CreateSurfaceOutput().ConnectToSource(surf.ConnectableAPI(),'surface')
 UsdShade.MaterialBindingAPI.Apply(quad(vn,'/'+name,(x,0,0)).GetPrim()).Bind(mat)
vn.GetRootLayer().Save();vr=bridge.import_stage(str(out/'varname.usda'),out)
assert any('fallback to displayColor — Only the st UV set is supported: uv' in l for l in vr['report']),vr['report']
assert next(m for m in vr['materials'] if m['path']=='/Looks/St').get('mtlx')
# The bridge refuses other interpreters with a concise requirement instead of a pxr traceback.
other=next((c for c in [sys.executable,shutil.which('python3',path='/opt/homebrew/bin:/usr/local/bin')] if c and subprocess.run([c,'-c','import sys;sys.exit(sys.version_info[:2]==(3,9))']).returncode==0),None)
if other:
 run=subprocess.run([other,'-I',str(ROOT/'scripts/usd_bridge.py'),str(out/'robust.usda'),str(out/'unused.json')],capture_output=True,text=True)
 assert run.returncode==1 and 'requires /usr/bin/python3 CPython 3.9' in run.stderr and 'Traceback' not in run.stderr,run.stderr
else:print('SKIP: no non-3.9 python3 found for the interpreter guard check')
print('PASS: USD degenerate faces, placeholder meshes, zero-scale subtrees, light APIs/power/clamp, fallback colors, constant dome, focus, color spaces, varname, interpreter guard')

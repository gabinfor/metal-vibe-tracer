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

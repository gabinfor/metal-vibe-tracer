#!/usr/bin/env python3
"""OPENUSD: read a composed stage with Pixar's SDK; emit a bounded renderer snapshot.
No input file is executed. This process only loads USD's installed core plugins.
"""
import sys, pathlib, os, json, math, uuid, hashlib, argparse, xml.etree.ElementTree as ET
HERE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(HERE/'OpenUSD' if (HERE/'OpenUSD').exists() else HERE.parent/'build/OpenUSD'))
from pxr import Usd, UsdGeom, UsdShade, UsdLux, Sdf, Gf, Ar

def vec(v): return [float(x) for x in v]
def identity_settings(): return {'positionScale':[0,0,0,1],'rotationHidden':[0,0,0,0],'uvTransform':[0,0,0,0],'channels':[0,0,0,0]}
def uid(): return str(uuid.uuid4())
def fail(msg): raise ValueError(msg)
def normalize(v):
    n=math.sqrt(sum(x*x for x in v))
    return [x/n for x in v] if n>1e-15 else [0,1,0]
def sub(a,b): return [x-y for x,y in zip(a,b)]
def cross(a,b): return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def get(obj,name,default,time):
    a=obj.GetInput(name) if hasattr(obj,'GetInput') else obj.GetAttribute(name)
    v=a.Get(time) if a else None
    return default if v is None else v

def triangulate(points,indices):
    # Ear clipping in the dominant projection handles concave planar polygons.
    if len(indices)<3: fail('Face has fewer than three vertices')
    n=[0.,0.,0.]
    for i,j in zip(indices,indices[1:]+indices[:1]):
        a,b=points[i],points[j]
        n[0]+=(a[1]-b[1])*(a[2]+b[2]);n[1]+=(a[2]-b[2])*(a[0]+b[0]);n[2]+=(a[0]-b[0])*(a[1]+b[1])
    drop=max(range(3),key=lambda i:abs(n[i]));axes=[i for i in range(3) if i!=drop]
    xy=[(points[i][axes[0]],points[i][axes[1]]) for i in indices]
    def area(a,b,c): return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
    orientation=1 if sum(xy[i][0]*xy[(i+1)%len(xy)][1]-xy[(i+1)%len(xy)][0]*xy[i][1] for i in range(len(xy)))>=0 else -1
    left=list(range(len(indices)));result=[]
    while len(left)>3:
        found=False
        for k,b in enumerate(left):
            a,c=left[k-1],left[(k+1)%len(left)]
            if area(xy[a],xy[b],xy[c])*orientation<=1e-12: continue
            if any(all(area(x,y,xy[p])*orientation>=-1e-12 for x,y in [(xy[a],xy[b]),(xy[b],xy[c]),(xy[c],xy[a])]) for p in left if p not in (a,b,c)): continue
            result.append((a,b,c));left.pop(k);found=True;break
        if not found: fail('Degenerate or self-intersecting polygon; triangulate upstream')
    result.append(tuple(left));return result

class MaterialTranslator:
    """UsdPreviewSurface or supported MaterialX UsdShade nodes -> existing MX compiler."""
    def __init__(self,stage,time,directory,report):
        self.stage,self.time,self.directory,self.report=stage,time,directory,report
        self.root=ET.Element('materialx',version='1.39');self.memo={};self.active=set();self.counter=0
    def asset(self,asset):
        path=asset.resolvedPath or str(Ar.GetResolver().Resolve(asset.path))
        if not path: fail('Unresolved image '+asset.path)
        source=Ar.GetResolver().OpenAsset(Ar.ResolvedPath(path))
        if not source: fail('Could not open image '+path)
        data=source.GetBuffer();suffix=path.rsplit('.',1)[-1].rstrip(']')
        dest=self.directory/(hashlib.sha256(bytes(data)).hexdigest()+'.'+suffix)
        if not dest.exists(): dest.write_bytes(bytes(data))
        return str(dest)
    def add(self,category,type,inputs):
        self.counter+=1;name='n'+str(self.counter);e=ET.SubElement(self.root,category,name=name,type=type)
        for key,t,value in inputs:
            a={'name':key,'type':t}
            if isinstance(value,dict):a.update(value)
            else:a['value']=','.join(str(float(v)) for v in value) if isinstance(value,(list,tuple,Gf.Vec2f,Gf.Vec3f,Gf.Vec4f)) else str(value)
            ET.SubElement(e,'input',a)
        return {'nodename':name}
    def expression(self,input,type,default):
        if not input:return default
        source=input.GetConnectedSource()
        if source:
            prim,output,kind=source
            if kind==UsdShade.AttributeType.Input:return self.expression(prim.GetInput(output),type,default)
            return self.node(UsdShade.Shader(prim.GetPrim()),str(output),type)
        v=input.Get(self.time)
        if v is None:return default
        if isinstance(v,bool):return 'true' if v else 'false'
        if isinstance(v,int):return v
        if isinstance(v,float):return v
        return vec(v)
    def node(self,shader,output,type):
        key=(str(shader.GetPath()),output,type)
        if key in self.memo:return self.memo[key]
        if key in self.active:fail('Cyclic shading graph')
        self.active.add(key)
        if shader.GetPrim().IsA(UsdShade.NodeGraph):
            result=self.expression(UsdShade.NodeGraph(shader.GetPrim()).GetOutput(output),type,0)
            self.active.remove(key);self.memo[key]=result;return result
        ident=shader.GetIdAttr().Get()
        if ident=='UsdPrimvarReader_float2':
            name=get(shader,'varname','st',self.time)
            if str(name)!='st':fail('Only the st UV set is supported: '+str(name))
            result=self.add('texcoord','vector2',[])
        elif ident=='UsdTransform2d':
            uv=self.expression(shader.GetInput('in'),'vector2',[0,0])
            uv=self.add('multiply','vector2',[('in1','vector2',uv),('in2','vector2',self.expression(shader.GetInput('scale'),'vector2',[1,1]))])
            if shader.GetInput('rotation') and shader.GetInput('rotation').GetConnectedSource():fail('Connected UV rotation is unsupported')
            angle=float(get(shader,'rotation',0,self.time))
            if angle:uv=self.add('rotate2d','vector2',[('in','vector2',uv),('amount','float',angle)])
            result=self.add('add','vector2',[('in1','vector2',uv),('in2','vector2',self.expression(shader.GetInput('translation'),'vector2',[0,0]))])
        elif ident=='UsdUVTexture':
            for axis in ['wrapS','wrapT']:
                if str(get(shader,axis,'repeat',self.time)) not in ('repeat','useMetadata'):fail('Only repeat texture wrapping is supported')
            raw=get(shader,'file',None,self.time)
            if not raw:fail('Texture file is missing')
            filename=self.asset(raw)
            color=str(get(shader,'sourceColorSpace','auto',self.time))
            if color=='auto':color='sRGB' if type in ('color3','color4') else 'raw'
            if color not in ('raw','sRGB'):fail('Unsupported USD texture color space '+color)
            sampleType='color4' if output in ('r','g','b','a') else type
            values=[('file','filename',filename)]
            values.append(('texcoord','vector2',self.expression(shader.GetInput('st'),'vector2',[0,0])))
            image=self.add('image',sampleType,values)
            self.root[-1].set('colorspace','srgb_texture' if color=='sRGB' else 'raw')
            width=4 if sampleType.endswith('4') else 3
            scale=vec(get(shader,'scale',Gf.Vec4f(1),self.time))[:width];bias=vec(get(shader,'bias',Gf.Vec4f(0),self.time))[:width]
            result=self.add('multiply',sampleType,[('in1',sampleType,image),('in2',sampleType,scale)])
            result=self.add('add',sampleType,[('in1',sampleType,result),('in2',sampleType,bias)])
            if output in ('r','g','b','a'):result=self.add('extract','float',[('in',sampleType,result),('index','integer','rgba'.index(output))])
            elif output not in ('rgb','rgba'):fail('Unsupported texture output '+output)
        elif ident and str(ident).startswith('ND_'):
            category=str(ident)[3:].split('_')[0]
            if category not in ('constant','image','texcoord','multiply','add','subtract','mix','clamp','extract','normalmap','convert','rotate2d'):fail('Unsupported MaterialX node '+str(ident))
            types={'float':'float','int':'integer','float2':'vector2','float3':'vector3','normal3f':'vector3','vector3f':'vector3','color3f':'color3','color4f':'color4','float4':'vector4','asset':'filename','string':'string'}
            inputs=[]
            for i in shader.GetInputs():
                if i.Get(self.time) is None and not i.GetConnectedSource():continue
                t=types.get(str(i.GetTypeName()))
                if not t:fail('Unsupported MaterialX USD type '+str(i.GetTypeName()))
                value=self.asset(i.Get(self.time)) if t=='filename' else i.Get(self.time) if t=='string' else self.expression(i,t,0)
                inputs.append((str(i.GetBaseName()),t,value))
            result=self.add(category,type,inputs)
        else:fail('Unsupported shader node '+str(ident))
        self.active.remove(key);self.memo[key]=result;return result
    def material(self,material):
        shader,_,_=material.ComputeSurfaceSource('mtlx')
        if not shader:shader,_,_=material.ComputeSurfaceSource()
        if not shader:fail('No supported surface output')
        ident=str(shader.GetIdAttr().Get())
        inputs=[]
        if ident=='UsdPreviewSurface':
            for key,default in [('useSpecularWorkflow',0),('opacity',1),('opacityThreshold',0),('displacement',0),('emissiveColor',Gf.Vec3f(0))]:
                i=shader.GetInput(key)
                if i and (i.GetConnectedSource() or get(shader,key,default,self.time)!=default):fail('Unsupported PreviewSurface input '+key)
            mapping=[('diffuseColor','base_color','color3',[.18]*3),('roughness','specular_roughness','float',.5),('metallic','base_metalness','float',0),('ior','specular_ior','float',1.5),('clearcoat','coat_weight','float',0),('clearcoatRoughness','coat_roughness','float',.01)]
            for src,dst,t,default in mapping:inputs.append((dst,t,self.expression(shader.GetInput(src),t,default)))
            normal=shader.GetInput('normal')
            if normal and (normal.GetConnectedSource() or normal.Get(self.time) is not None):
                n=self.expression(normal,'vector3',[0,0,1])
                n=self.add('multiply','vector3',[('in1','vector3',n),('in2','float',.5)])
                n=self.add('add','vector3',[('in1','vector3',n),('in2','float',.5)])
                n=self.add('normalmap','vector3',[('in','vector3',n)])
                inputs.append(('geometry_normal','vector3',n))
        elif ident.startswith('ND_open_pbr_surface'):
            for i in shader.GetInputs():
                if i.Get(self.time) is None and not i.GetConnectedSource():continue
                t='color3' if str(i.GetTypeName())=='color3f' else 'vector3' if str(i.GetTypeName()) in ('vector3f','normal3f','float3') else 'boolean' if str(i.GetTypeName())=='bool' else 'float'
                inputs.append((str(i.GetBaseName()),t,self.expression(i,t,0)))
        else:fail('Unsupported surface '+ident)
        self.add('open_pbr_surface','surfaceshader',inputs)
        return ET.tostring(self.root,encoding='unicode')

def import_stage(filename,directory,frame=None):
    stage=Usd.Stage.Open(filename,load=Usd.Stage.LoadAll)
    if not stage:fail('Could not open USD stage')
    time=Usd.TimeCode(frame if frame is not None else stage.GetStartTimeCode())
    report=['OpenUSD '+'.'.join(map(str,Usd.GetVersion()))+'; snapshot at time '+str(time.GetValue()),
            'Snapshot uses the existing OpenPBR renderer: PreviewSurface shading is approximated; linear/sRGB textures only, without OCIO/ACES transforms. External MaterialX Sdf composition is unavailable in this SDK bundle.',
            'Meshes render two-sided. Subdivision, point instancers, skinning, volumes and curves are not evaluated. Perspective cameras use an orbit view without roll/lens shift.']
    # A resolver context handles references, payloads, selected variants and package assets.
    conversion=Gf.Matrix4d(1)
    if UsdGeom.GetStageUpAxis(stage)==UsdGeom.Tokens.z:conversion=Gf.Matrix4d().SetRotate(Gf.Rotation(Gf.Vec3d(1,0,0),-90))
    conversion=Gf.Matrix4d().SetScale(UsdGeom.GetStageMetersPerUnit(stage))*conversion
    cache=UsdGeom.XformCache(time); nodes=[];assets=[];materials=[];materialIndex={};assetCache={};cameras=[];environment=None;sun=None
    rootID=uid();nodes.append({'id':rootID,'name':pathlib.Path(filename).name,'transform':identity_settings(),'bindings':[]})
    nodeIDs={};worlds={};rendered=0
    def get_material(prim):
        material,_=UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()
        path=str(material.GetPath()) if material else ''
        color=UsdGeom.Gprim(prim).GetDisplayColorPrimvar().ComputeFlattened(time) if prim.IsA(UsdGeom.Gprim) else None
        if color is not None and len(color)>1:report.append(str(prim.GetPath())+': varying displayColor reduced to its first value')
        color=vec(color[0]) if color is not None and len(color) else [.7]*3
        key=path or 'display:'+str(color)
        if key in materialIndex:return materialIndex[key]
        item={'id':uid(),'name':material.GetPrim().GetName() if material else 'Display color','color':color,'path':path}
        if material:
            try:item['mtlx']=MaterialTranslator(stage,time,directory,report).material(material)
            except Exception as e:report.append(path+': material fallback to displayColor — '+str(e))
        if len(materials)>=56:fail('Stage exceeds 56 imported materials')
        materials.append(item);materialIndex[key]=item['id'];return item['id']
    with Ar.ResolverContextBinder(stage.GetPathResolverContext()):
        for prim in Usd.PrimRange.Stage(stage,Usd.TraverseInstanceProxies()):
            if not prim.IsActive() or not prim.IsDefined():continue
            imageable=UsdGeom.Imageable(prim)
            if imageable and imageable.ComputePurpose() in ('guide','proxy'):continue
            path=str(prim.GetPath())
            if prim.HasAPI(UsdLux.LightAPI):
                api=UsdLux.LightAPI(prim)
                if api.GetLightLinkCollectionAPI().GetIncludesRel().GetTargets() or api.GetShadowLinkCollectionAPI().GetIncludesRel().GetTargets() or api.GetLightLinkCollectionAPI().GetExcludesRel().GetTargets() or api.GetShadowLinkCollectionAPI().GetExcludesRel().GetTargets():report.append(path+': light/shadow linking not applied')
            if prim.HasAPI(UsdLux.LightAPI) and imageable and imageable.ComputeVisibility(time)=='invisible':continue
            if prim.IsA(UsdGeom.Mesh) or prim.IsA(UsdGeom.Xform):
                world=cache.GetLocalToWorldTransform(prim)*conversion
                parent=prim.GetParent()
                while parent and str(parent.GetPath()) not in nodeIDs:parent=parent.GetParent()
                pp=str(parent.GetPath()) if parent else None
                local=world*(worlds[pp].GetInverse() if pp in worlds else Gf.Matrix4d(1))
                node={'id':uid(),'name':str(prim.GetName()),'parent':nodeIDs.get(pp,rootID),'transform':identity_settings(),'bindings':[],'matrix':[float(local[r][c]) for r in range(4) for c in range(4)]}
                # Gf uses row vectors; its row-major array is a column-major matrix for Swift.
                if imageable and imageable.ComputeVisibility(time)=='invisible':node['transform']['rotationHidden'][3]=1
                nodes.append(node);nodeIDs[path]=node['id'];worlds[path]=world
                if len(nodes)>256:fail('Stage exceeds 256 imported hierarchy nodes')
                if not prim.IsA(UsdGeom.Mesh):continue
                mesh=UsdGeom.Mesh(prim);points=mesh.GetPointsAttr().Get(time);counts=mesh.GetFaceVertexCountsAttr().Get(time);indices=mesh.GetFaceVertexIndicesAttr().Get(time)
                valid,reason=UsdGeom.Mesh.ValidateTopology(indices,counts,len(points))
                if not valid:fail(path+': '+reason)
                if str(mesh.GetSubdivisionSchemeAttr().Get())!='none':report.append(path+': subdivision represented by its polygon control cage')
                if len(counts) and max(counts)>4096:fail('Polygon exceeds 4096 corners')
                default=get_material(prim);bindings=[default];subsetNames=['Default'];faceSlots=[0]*len(counts)
                assigned=set()
                for subset in UsdShade.MaterialBindingAPI(prim).GetMaterialBindSubsets():
                    materialID=get_material(subset.GetPrim());slot=len(bindings);bindings.append(materialID);subsetNames.append(str(subset.GetPrim().GetName()))
                    for face in subset.GetIndicesAttr().Get(time) or []:
                        if face<0 or face>=len(counts) or face in assigned:fail(path+': invalid or overlapping material subsets')
                        assigned.add(face);faceSlots[face]=slot
                st=UsdGeom.PrimvarsAPI(prim).FindPrimvarWithInheritance('st');uv=st.ComputeFlattened(time) if st else None;uvInterp=st.GetInterpolation() if st else ''
                normalVar=UsdGeom.PrimvarsAPI(prim).GetPrimvar('normals');normals=normalVar.ComputeFlattened(time) if normalVar else mesh.GetNormalsAttr().Get(time);normalInterp=normalVar.GetInterpolation() if normalVar else mesh.GetNormalsInterpolation()
                def sample(values,interp,face,corner,vertex,default):
                    if values is None or not len(values):return default
                    index={'constant':0,'uniform':face,'vertex':vertex,'varying':vertex,'faceVarying':corner}.get(str(interp))
                    if index is None or index>=len(values):fail(path+': invalid primvar interpolation/count')
                    return vec(values[index])
                holes=set(mesh.GetHoleIndicesAttr().Get(time) or []);offset=0;triangles=[];left=str(mesh.GetOrientationAttr().Get(time))=='leftHanded'
                for face,count in enumerate(counts):
                    faceIndices=list(indices[offset:offset+count]);base=offset;offset+=count
                    if face in holes:continue
                    for corners in triangulate(points,faceIndices):
                        if left:corners=(corners[0],corners[2],corners[1])
                        ps=[vec(points[faceIndices[i]]) for i in corners];ng=normalize(cross(sub(ps[1],ps[0]),sub(ps[2],ps[0])))
                        ns=[normalize(sample(normals,normalInterp,face,base+i,faceIndices[i],ng)) for i in corners]
                        uvs=[sample(uv,uvInterp,face,base+i,faceIndices[i],[0,0]) for i in corners]
                        triangles.append(dict(a=ps[0]+[1],b=ps[1]+[1],c=ps[2]+[1],na=ns[0]+[0],nb=ns[1]+[0],nc=ns[2]+[0],uvab=[uvs[0][0],1-uvs[0][1],uvs[1][0],1-uvs[1][1]],uvc=[uvs[2][0],1-uvs[2][1],faceSlots[face],0]))
                rendered+=len(triangles)
                if rendered>500000:fail('Stage exceeds 500,000 rendered triangles')
                key=hashlib.sha256(json.dumps({'triangles':triangles,'subsets':subsetNames},separators=(',',':')).encode()).hexdigest()
                if key not in assetCache:
                    asset={'id':uid(),'name':str(prim.GetName()),'triangles':triangles,'subsets':subsetNames};assets.append(asset);assetCache[key]=asset['id']
                node['mesh']=assetCache[key];node['bindings']=bindings
            elif prim.IsA(UsdGeom.Camera):
                camera=UsdGeom.Camera(prim).GetCamera(time)
                if camera.projection!=Gf.Camera.Perspective:report.append(path+': orthographic camera skipped');continue
                world=cache.GetLocalToWorldTransform(prim)*conversion;eye=world.Transform(Gf.Vec3d(0));forward=normalize(vec(world.TransformDir(Gf.Vec3d(0,0,-1))));up=normalize(vec(world.TransformDir(Gf.Vec3d(0,1,0))))
                cameras.append({'name':str(prim.GetName()),'eye':vec(eye),'direction':forward,'up':up,'fov':float(camera.GetFieldOfView(Gf.Camera.FOVVertical)),'focus':float(UsdGeom.Camera(prim).GetFocusDistanceAttr().Get(time))*UsdGeom.GetStageMetersPerUnit(stage)})
            elif prim.IsA(UsdLux.RectLight) or prim.IsA(UsdLux.DiskLight) or prim.IsA(UsdLux.SphereLight):
                if imageable and imageable.ComputeVisibility(time)=='invisible':continue
                is_rect=prim.IsA(UsdLux.RectLight);is_disk=prim.IsA(UsdLux.DiskLight)
                light=UsdLux.RectLight(prim) if is_rect else (UsdLux.DiskLight(prim) if is_disk else UsdLux.SphereLight(prim))
                if is_rect: width=float(light.GetWidthAttr().Get(time));height=float(light.GetHeightAttr().Get(time))
                else:
                    radius=float(light.GetRadiusAttr().Get(time))
                    if radius<=0: report.append(path+': degenerate light skipped');continue
                    width=height=2*radius
                world=cache.GetLocalToWorldTransform(prim)*conversion
                strength=float(light.GetIntensityAttr().Get(time))*2**float(light.GetExposureAttr().Get(time));color=vec(light.GetColorAttr().Get(time))
                if light.GetEnableColorTemperatureAttr().Get(time):report.append(path+': light color temperature is not applied')
                if is_rect and light.GetTextureFileAttr().Get(time):report.append(path+': textured area light imported with constant color')
                if prim.HasAPI(UsdLux.ShapingAPI) or light.GetFiltersRel().GetTargets() or light.GetDiffuseAttr().Get(time)!=1 or light.GetSpecularAttr().Get(time)!=1:report.append(path+': light shaping, filters and diffuse/specular weights are not applied')
                area=Gf.Cross(world.TransformDir(Gf.Vec3d(width,0,0)),world.TransformDir(Gf.Vec3d(0,height,0))).GetLength()
                if area<1e-12:report.append(path+': degenerate area light skipped');continue
                if light.GetNormalizeAttr().Get(time):strength/=area
                material={'id':uid(),'name':str(prim.GetName())+' emission','color':[0,0,0],'path':path,'emission':[max(0,x*strength) for x in color]}
                if len(materials)>=56:fail('Stage exceeds 56 materials including lights')
                materials.append(material)
                if is_disk:
                    ps=[[0,0,0]]+[[radius*math.cos(2*math.pi*i/8),radius*math.sin(2*math.pi*i/8),0] for i in range(8)]
                    triangles=[]
                    for i in range(8):
                        a,b=1+i,1+(i+1)%8
                        triangles.append(dict(a=ps[0]+[1],b=ps[b]+[1],c=ps[a]+[1],na=[0,0,-1,0],nb=[0,0,-1,0],nc=[0,0,-1,0],uvab=[.5,.5,.5,.5],uvc=[.5+.5*math.cos(2*math.pi*i/8),.5+.5*math.sin(2*math.pi*i/8),0,0]))
                else:
                    ps=[[-width/2,-height/2,0],[-width/2,height/2,0],[width/2,height/2,0],[width/2,-height/2,0]];triangles=[]
                    for a,b,c in [(0,1,2),(0,2,3)]:triangles.append(dict(a=ps[a]+[1],b=ps[b]+[1],c=ps[c]+[1],na=[0,0,-1,0],nb=[0,0,-1,0],nc=[0,0,-1,0],uvab=[0,0,0,1],uvc=[1,1,0,0]))
                asset={'id':uid(),'name':str(prim.GetName()),'triangles':triangles,'subsets':['Emission']};assets.append(asset)
                parent=prim.GetParent()
                while parent and str(parent.GetPath()) not in nodeIDs:parent=parent.GetParent()
                pp=str(parent.GetPath()) if parent else None
                local=world*(worlds[pp].GetInverse() if pp in worlds else Gf.Matrix4d(1))
                nodes.append({'id':uid(),'name':str(prim.GetName()),'parent':nodeIDs.get(pp,rootID),'mesh':asset['id'],'transform':identity_settings(),'bindings':[material['id']],'matrix':[float(local[r][c]) for r in range(4) for c in range(4)]})
                rendered+=len(triangles)
                if is_disk: report.append(path+': disk light imported as an eight-sided emissive polygon')
                elif not is_rect: report.append(path+': sphere light imported as a rectangular emitter approximation')
            elif prim.IsA(UsdLux.DomeLight):
                light=UsdLux.DomeLight(prim);asset=light.GetTextureFileAttr().Get(time)
                if asset and asset.path:
                    if environment:report.append(path+': additional dome light skipped');continue
                    environment={'file':MaterialTranslator(stage,time,directory,report).asset(asset),'intensity':float(light.GetIntensityAttr().Get(time))*2**float(light.GetExposureAttr().Get(time))}
                    report.append(path+': dome texture imported; dome transform/color not applied')
            elif prim.IsA(UsdLux.DistantLight):
                light=UsdLux.DistantLight(prim)
                if sun:report.append(path+': additional distant light skipped');continue
                direction=normalize(vec((cache.GetLocalToWorldTransform(prim)*conversion).TransformDir(Gf.Vec3d(0,0,1))))
                sun={'direction':direction,'intensity':float(light.GetIntensityAttr().Get(time))*2**float(light.GetExposureAttr().Get(time))}
                report.append(path+': distant light mapped to existing sun; source angle and tint not applied')
            elif prim.HasAPI(UsdLux.LightAPI):report.append(path+': unsupported light type '+prim.GetTypeName())
            elif prim.IsA(UsdGeom.Gprim) or prim.GetTypeName() in ('PointInstancer','Volume'):report.append(path+': unsupported geometry '+prim.GetTypeName())
    if len(nodes)>256 or rendered>500000:fail('Stage exceeds renderer capacity including lights')
    if not assets:fail('No supported meshes were found')
    report.insert(1,f'{len(assets)} mesh assets, {len(nodes)} nodes, {len(materials)} materials, {rendered} triangles')
    return {'nodes':nodes,'assets':assets,'materials':materials,'cameras':cameras,'environment':environment,'sun':sun,'report':report}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('input');parser.add_argument('output');parser.add_argument('--frame',type=float);args=parser.parse_args()
    try:
        directory=pathlib.Path(args.output).parent
        result=import_stage(args.input,directory,args.frame)
        pathlib.Path(args.output).write_text(json.dumps(result,allow_nan=False,separators=(',',':')))
    except Exception as e:
        print('USD import failed: '+str(e),file=sys.stderr);sys.exit(1)

#!/usr/bin/env python3
"""OPENUSD: read a composed stage with Pixar's SDK; emit a bounded renderer snapshot.
No input file is executed. This process only loads USD's installed core plugins.
"""
import sys, pathlib, os, json, math, uuid, hashlib, argparse, xml.etree.ElementTree as ET
HERE=pathlib.Path(__file__).resolve().parent
# The bundled SDK is a CPython 3.9 wheel; any other interpreter gets a concise requirement message.
if sys.version_info[:2]!=(3,9):sys.exit('USD import failed: the bundled OpenUSD SDK requires /usr/bin/python3 CPython 3.9 (Xcode Command Line Tools); found Python '+sys.version.split()[0]+'.')
sys.path.insert(0,str(HERE/'OpenUSD' if (HERE/'OpenUSD').exists() else HERE.parent/'build/OpenUSD'))
try:from pxr import Usd, UsdGeom, UsdShade, UsdLux, Sdf, Gf, Ar
except ImportError as e:sys.exit('USD import failed: the bundled OpenUSD SDK could not be loaded ('+str(e)+'); rebuild the app or run scripts/prepare_usd.py.')

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
    if a and hasattr(a,'GetValueProducingAttributes'):
        # Interface connections resolve to the material or node-graph input that holds the value.
        sources=a.GetValueProducingAttributes()
        if sources and UsdShade.Output.IsOutput(sources[0]):fail('Connected '+name+' is unsupported')
        a=sources[0] if sources else None
    v=a.Get(time) if a else None
    return default if v is None else v

# Authored USD color spaces that the MaterialX compiler decodes without OCIO.
IMAGE_SPACES={'srgb_texture':'srgb_texture','srgb_rec709_scene':'srgb_texture','sRGB':'srgb_texture','lin_rec709':'lin_rec709','lin_rec709_scene':'lin_rec709','raw':'raw','data':'raw','identity':'raw'}

def triangulate(points,indices):
    # Ear clipping in the dominant projection handles concave planar polygons. Tolerances scale with the
    # polygon extent; repeated corners and zero-area faces are dropped, and non-simple remainders use a fan.
    # Returns (corner triangles, 'ok' | 'fan' | 'degenerate').
    ps=[vec(points[i]) for i in indices]
    corners=[k for k in range(len(ps)) if ps[k]!=ps[k-1]]
    span=max([max(p[a] for p in ps)-min(p[a] for p in ps) for a in range(3)]) if ps else 0
    eps=span*span*1e-10
    def twice(a,b,c): return math.sqrt(sum(x*x for x in cross(sub(ps[b],ps[a]),sub(ps[c],ps[a]))))
    if len(corners)<3 or not span>0: return [],'degenerate'
    n=[0.,0.,0.]
    for i,j in zip(corners,corners[1:]+corners[:1]):
        a,b=ps[i],ps[j]
        n[0]+=(a[1]-b[1])*(a[2]+b[2]);n[1]+=(a[2]-b[2])*(a[0]+b[0]);n[2]+=(a[0]-b[0])*(a[1]+b[1])
    drop=max(range(3),key=lambda i:abs(n[i]));axes=[i for i in range(3) if i!=drop]
    xy={k:(ps[k][axes[0]],ps[k][axes[1]]) for k in corners}
    def area(a,b,c): return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
    signed=sum(xy[i][0]*xy[j][1]-xy[j][0]*xy[i][1] for i,j in zip(corners,corners[1:]+corners[:1]))
    orientation=1 if signed>=0 else -1
    left=list(corners);result=[]
    while len(left)>3 and abs(signed)>eps:
        found=False
        for k,b in enumerate(left):
            a,c=left[k-1],left[(k+1)%len(left)]
            if area(xy[a],xy[b],xy[c])*orientation<=eps: continue
            if any(all(area(x,y,xy[p])*orientation>=-eps for x,y in [(xy[a],xy[b]),(xy[b],xy[c]),(xy[c],xy[a])]) for p in left if p not in (a,b,c)): continue
            result.append((a,b,c));left.pop(k);found=True;break
        if found: continue
        # A collinear corner adds no area; otherwise the polygon is not simple.
        flat=[k for k,b in enumerate(left) if abs(area(xy[left[k-1]],xy[b],xy[left[(k+1)%len(left)]]))<=eps]
        if not flat: break
        left.pop(flat[0])
    status='fan' if len(left)>3 else 'ok'
    result+=[(left[0],left[i],left[i+1]) for i in range(1,len(left)-1)]
    result=[t for t in result if twice(*t)>eps]
    return (result,status) if result else ([],'degenerate')

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
            # USD rotation is counter-clockwise; MaterialX rotate2d turns the other way (IMP_UsdTransform2d negates).
            if angle:uv=self.add('rotate2d','vector2',[('in','vector2',uv),('amount','float',-angle)])
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
                if t=='filename':
                    raw=get(shader,str(i.GetBaseName()),None,self.time)
                    if not raw or not raw.path:fail(str(shader.GetPath())+': image file is missing')
                    value={'value':self.asset(raw)}
                    # Attribute metadata, then ColorSpaceAPI on the prim and its ancestors.
                    space=str(Usd.ColorSpaceAPI.ComputeColorSpaceName(i.GetAttr(),Usd.ColorSpaceHashCache()) or '')
                    if space and space not in IMAGE_SPACES:fail(str(shader.GetPath())+': unsupported image color space '+space)
                    if space:value['colorspace']=IMAGE_SPACES[space]
                else:value=i.Get(self.time) if t=='string' else self.expression(i,t,0)
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
            for key,default in [('useSpecularWorkflow',0),('opacity',1),('opacityThreshold',0),('displacement',0)]:
                i=shader.GetInput(key)
                if i and (i.GetConnectedSource() or get(shader,key,default,self.time)!=default):fail('Unsupported PreviewSurface input '+key)
            mapping=[('diffuseColor','base_color','color3',[.18]*3),('roughness','specular_roughness','float',.5),('metallic','base_metalness','float',0),('ior','specular_ior','float',1.5),('clearcoat','coat_weight','float',0),('clearcoatRoughness','coat_roughness','float',.01)]
            for src,dst,t,default in mapping:inputs.append((dst,t,self.expression(shader.GetInput(src),t,default)))
            # emissiveColor is the emitted radiance (MaterialX IMP_UsdPreviewSurface: uniform_edf
            # color); OpenPBR expresses it as emission_color at unit luminance.
            emissive=shader.GetInput('emissiveColor')
            if emissive and (emissive.GetConnectedSource() or any(vec(get(shader,'emissiveColor',Gf.Vec3f(0),self.time)))):
                inputs.append(('emission_color','color3',self.expression(emissive,'color3',[0,0,0])))
                inputs.append(('emission_luminance','float',1.0))
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

def sphere_proxy(radius):
    # A once-subdivided icosahedron with outward, one-sided faces, scaled to the sphere's area 4*pi*r^2.
    t=(1+math.sqrt(5))/2
    v=[normalize(p) for p in [(-1,t,0),(1,t,0),(-1,-t,0),(1,-t,0),(0,-1,t),(0,1,t),(0,-1,-t),(0,1,-t),(t,0,-1),(t,0,1),(-t,0,-1),(-t,0,1)]]
    faces=[]
    for a,b,c in [(0,11,5),(0,5,1),(0,1,7),(0,7,10),(0,10,11),(1,5,9),(5,11,4),(11,10,2),(10,7,6),(7,1,8),(3,9,4),(3,4,2),(3,2,6),(3,6,8),(3,8,9),(4,9,5),(2,4,11),(6,2,10),(8,6,7),(9,8,1)]:
        ab,bc,ca=[normalize([(x+y)/2 for x,y in zip(v[i],v[j])]) for i,j in ((a,b),(b,c),(c,a))]
        faces+=[(v[a],ab,ca),(ab,v[b],bc),(ca,bc,v[c]),(ab,bc,ca)]
    unit=sum(math.sqrt(sum(x*x for x in cross(sub(b,a),sub(c,a))))/2 for a,b,c in faces)
    scale=radius*math.sqrt(4*math.pi/unit);triangles=[]
    for a,b,c in faces:
        a,b,c=[[scale*x for x in p] for p in (a,b,c)]
        n=normalize(cross(sub(b,a),sub(c,a)))
        if sum(x*y for x,y in zip(n,a))<0:b,c,n=c,b,[-x for x in n]
        triangles.append(dict(a=a+[1],b=b+[1],c=c+[1],na=n+[0],nb=n+[0],nc=n+[0],uvab=[.5,.5,.5,.5],uvc=[.5,.5,0,0]))
    return triangles

def constant_environment(directory,color):
    # A uniform latlong Radiance HDR (RGBE) image carries an untextured dome's linear color.
    def rgbe(rgb):
        m=max(rgb)
        if not m>1e-32:return bytes(4)
        f,e=math.frexp(m);s=f*256/m
        return bytes([min(255,int(x*s)) for x in rgb]+[e+128])
    color=[max(0.,float(x)) for x in color]
    if not all(math.isfinite(x) for x in color):fail('Non-finite dome color')
    data=b'#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 4 +X 8\n'+rgbe(color)*32
    dest=directory/('dome-'+hashlib.sha256(data).hexdigest()[:16]+'.hdr')
    dest.write_bytes(data);return str(dest)

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
    nodeIDs={};worlds={};rendered=0;translations={};collapsed=set();fallbackColors={}
    def get_material(prim):
        material,_=UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()
        path=str(material.GetPath()) if material else ''
        color=UsdGeom.Gprim(prim).GetDisplayColorPrimvar().ComputeFlattened(time) if prim.IsA(UsdGeom.Gprim) else None
        if color is not None and len(color)>1:report.append(str(prim.GetPath())+': varying displayColor reduced to its first value')
        color=vec(color[0]) if color is not None and len(color) else [.7]*3
        if material and path not in translations:
            try:translations[path]=(MaterialTranslator(stage,time,directory,report).material(material),None)
            except Exception as e:translations[path]=(None,str(e))
        mtlx,error=translations.get(path,(None,None))
        if error:report.append(str(prim.GetPath())+': material '+path+' fallback to displayColor — '+error)
        # A failed translation falls back per displayColor, so prims sharing it keep their own colors.
        key=path if mtlx else path+'|display:'+str(color)
        if key in materialIndex:return materialIndex[key],color
        if len(materials)>=56 and path in materialIndex:
            report.append(str(prim.GetPath())+': material limit reached; shares the first displayColor fallback of '+path)
            return materialIndex[path],color
        item={'id':uid(),'name':material.GetPrim().GetName() if material else 'Display color','color':color,'path':path}
        if mtlx:item['mtlx']=mtlx
        if len(materials)>=56:fail('Stage exceeds 56 imported materials')
        materials.append(item);materialIndex[key]=item['id']
        if path:materialIndex.setdefault(path,item['id'])
        return item['id'],color
    def singular(m):
        # Mirrors the Swift flattening limits: a collapsed basis cannot be rendered or inverted.
        return abs(m.GetDeterminant3())<1e-18 or Gf.Vec3d(m[0][0],m[0][1],m[0][2]).GetLength()<1e-6
    def attach(prim,world):
        # Local matrices come from the XformCache, so a singular ancestor is never inverted.
        parent=prim.GetParent()
        while parent and str(parent.GetPath()) not in nodeIDs:parent=parent.GetParent()
        pp=str(parent.GetPath()) if parent else None
        if pp not in worlds:return pp,rootID,world
        local,reset=cache.ComputeRelativeTransform(prim,parent)
        if not reset:return pp,nodeIDs[pp],local
        if singular(worlds[pp]):return pp,rootID,world
        return pp,nodeIDs[pp],world*worlds[pp].GetInverse()
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
                pp,parentID,local=attach(prim,world)
                node={'id':uid(),'name':str(prim.GetName()),'parent':parentID,'transform':identity_settings(),'bindings':[],'matrix':[float(local[r][c]) for r in range(4) for c in range(4)]}
                # Gf uses row vectors; its row-major array is a column-major matrix for Swift.
                if imageable and imageable.ComputeVisibility(time)=='invisible':node['transform']['rotationHidden'][3]=1
                if singular(world):
                    node['transform']['rotationHidden'][3]=1
                    if pp not in collapsed:report.append(path+': zero or singular world scale; subtree hidden')
                    collapsed.add(path)
                nodes.append(node);nodeIDs[path]=node['id'];worlds[path]=world
                if len(nodes)>256:fail('Stage exceeds 256 imported hierarchy nodes')
                if not prim.IsA(UsdGeom.Mesh):continue
                if prim.HasAPI(UsdLux.MeshLightAPI):report.append(path+': MeshLightAPI emission not applied; mesh imported as a surface')
                mesh=UsdGeom.Mesh(prim);points=mesh.GetPointsAttr().Get(time);counts=mesh.GetFaceVertexCountsAttr().Get(time);indices=mesh.GetFaceVertexIndicesAttr().Get(time)
                if any(v is None or not len(v) for v in (points,counts,indices)):report.append(path+': mesh without points or topology skipped');continue
                valid,reason=UsdGeom.Mesh.ValidateTopology(indices,counts,len(points))
                if not valid:fail(path+': '+reason)
                if str(mesh.GetSubdivisionSchemeAttr().Get())!='none':report.append(path+': subdivision represented by its polygon control cage')
                if len(counts) and max(counts)>4096:fail('Polygon exceeds 4096 corners')
                default,color=get_material(prim);bindings=[default];colors=[color];subsetNames=['Default'];faceSlots=[0]*len(counts)
                assigned=set()
                for subset in UsdShade.MaterialBindingAPI(prim).GetMaterialBindSubsets():
                    materialID,color=get_material(subset.GetPrim());slot=len(bindings);bindings.append(materialID);colors.append(color);subsetNames.append(str(subset.GetPrim().GetName()))
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
                holes=set(mesh.GetHoleIndicesAttr().Get(time) or []);offset=0;triangles=[];left=str(mesh.GetOrientationAttr().Get(time))=='leftHanded';dropped=fanned=0
                for face,count in enumerate(counts):
                    faceIndices=list(indices[offset:offset+count]);base=offset;offset+=count
                    if face in holes:continue
                    faceTriangles,status=triangulate(points,faceIndices);dropped+=status=='degenerate';fanned+=status=='fan'
                    for corners in faceTriangles:
                        if left:corners=(corners[0],corners[2],corners[1])
                        ps=[vec(points[faceIndices[i]]) for i in corners];ng=normalize(cross(sub(ps[1],ps[0]),sub(ps[2],ps[0])))
                        ns=[normalize(sample(normals,normalInterp,face,base+i,faceIndices[i],ng)) for i in corners]
                        uvs=[sample(uv,uvInterp,face,base+i,faceIndices[i],[0,0]) for i in corners]
                        triangles.append(dict(a=ps[0]+[1],b=ps[1]+[1],c=ps[2]+[1],na=ns[0]+[0],nb=ns[1]+[0],nc=ns[2]+[0],uvab=[uvs[0][0],1-uvs[0][1],uvs[1][0],1-uvs[1][1]],uvc=[uvs[2][0],1-uvs[2][1],faceSlots[face],0]))
                if dropped:report.append(path+': '+str(dropped)+' degenerate faces dropped')
                if fanned:report.append(path+': '+str(fanned)+' non-simple polygons fan-triangulated')
                if not triangles:report.append(path+': mesh has no renderable faces; skipped');continue
                rendered+=len(triangles)
                if rendered>500000:fail('Stage exceeds 500,000 rendered triangles')
                key=hashlib.sha256(json.dumps({'triangles':triangles,'subsets':subsetNames},separators=(',',':')).encode()).hexdigest()
                if key not in assetCache:
                    asset={'id':uid(),'name':str(prim.GetName()),'triangles':triangles,'subsets':subsetNames};assets.append(asset);assetCache[key]=asset['id']
                node['mesh']=assetCache[key];node['bindings']=bindings
                # Per-binding displayColors let Swift split a material its compiler rejects.
                fallbackColors[node['id']]=colors
            elif prim.IsA(UsdGeom.Camera):
                camera=UsdGeom.Camera(prim).GetCamera(time)
                if camera.projection!=Gf.Camera.Perspective:report.append(path+': orthographic camera skipped');continue
                world=cache.GetLocalToWorldTransform(prim)*conversion;eye=world.Transform(Gf.Vec3d(0));forward=normalize(vec(world.TransformDir(Gf.Vec3d(0,0,-1))));up=normalize(vec(world.TransformDir(Gf.Vec3d(0,1,0))))
                # The schema fallback 0 means an unauthored focus; Swift then focuses where the view meets the scene.
                focus=UsdGeom.Camera(prim).GetFocusDistanceAttr().Get(time)
                cameras.append({'name':str(prim.GetName()),'eye':vec(eye),'direction':forward,'up':up,'fov':float(camera.GetFieldOfView(Gf.Camera.FOVVertical)),'focus':float(focus)*UsdGeom.GetStageMetersPerUnit(stage) if focus and math.isfinite(focus) and focus>0 else None})
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
                if is_disk:
                    # An equal-area octagon keeps the disk's area pi*r^2, and with it the emitted power.
                    r=radius*math.sqrt(math.pi/(2*math.sqrt(2)))
                    ps=[[0,0,0]]+[[r*math.cos(2*math.pi*i/8),r*math.sin(2*math.pi*i/8),0] for i in range(8)]
                    triangles=[]
                    for i in range(8):
                        a,b=1+i,1+(i+1)%8
                        triangles.append(dict(a=ps[0]+[1],b=ps[b]+[1],c=ps[a]+[1],na=[0,0,-1,0],nb=[0,0,-1,0],nc=[0,0,-1,0],uvab=[.5,.5,.5,.5],uvc=[.5+.5*math.cos(2*math.pi*i/8),.5+.5*math.sin(2*math.pi*i/8),0,0]))
                elif is_rect:
                    ps=[[-width/2,-height/2,0],[-width/2,height/2,0],[width/2,height/2,0],[width/2,-height/2,0]];triangles=[]
                    for a,b,c in [(0,1,2),(0,2,3)]:triangles.append(dict(a=ps[a]+[1],b=ps[b]+[1],c=ps[c]+[1],na=[0,0,-1,0],nb=[0,0,-1,0],nc=[0,0,-1,0],uvab=[0,0,0,1],uvc=[1,1,0,0]))
                else:triangles=sphere_proxy(radius)
                # USD normalization divides by the world-space area of the emitter actually built.
                area=sum(0.5*Gf.Cross(world.TransformDir(Gf.Vec3d(*sub(t['b'][:3],t['a'][:3]))),world.TransformDir(Gf.Vec3d(*sub(t['c'][:3],t['a'][:3])))).GetLength() for t in triangles)
                if area<1e-12:report.append(path+': degenerate area light skipped');continue
                if light.GetNormalizeAttr().Get(time):strength/=area
                emission=[max(0,x*strength) for x in color]
                if not all(math.isfinite(x) for x in emission):fail(path+': non-finite light intensity')
                if max(emission)>1e8:
                    report.append(path+': emission %.3g exceeds the supported 1e8 and was scaled down'%max(emission))
                    emission=[x*(1e8/max(emission)) for x in emission]
                material={'id':uid(),'name':str(prim.GetName())+' emission','color':[0,0,0],'path':path,'emission':emission}
                if len(materials)>=56:fail('Stage exceeds 56 materials including lights')
                materials.append(material)
                asset={'id':uid(),'name':str(prim.GetName()),'triangles':triangles,'subsets':['Emission']};assets.append(asset)
                pp,parentID,local=attach(prim,world)
                nodes.append({'id':uid(),'name':str(prim.GetName()),'parent':parentID,'mesh':asset['id'],'transform':identity_settings(),'bindings':[material['id']],'matrix':[float(local[r][c]) for r in range(4) for c in range(4)]})
                rendered+=len(triangles)
                if is_disk: report.append(path+': disk light imported as an equal-area eight-sided emissive polygon')
                elif not is_rect: report.append(path+': sphere light imported as an equal-area 80-face emissive polyhedron approximation')
            elif prim.IsA(UsdLux.DomeLight):
                light=UsdLux.DomeLight(prim);asset=light.GetTextureFileAttr().Get(time)
                if environment:report.append(path+': additional dome light skipped');continue
                intensity=float(light.GetIntensityAttr().Get(time))*2**float(light.GetExposureAttr().Get(time))
                layout=str(light.GetTextureFormatAttr().Get(time) or 'automatic')
                if asset and asset.path:
                    if layout not in ('automatic','latlong'):report.append(path+': dome texture format '+layout+' is unsupported (latlong only); dome skipped');continue
                    environment={'file':MaterialTranslator(stage,time,directory,report).asset(asset),'intensity':intensity}
                    report.append(path+': dome texture imported; dome transform/color not applied')
                else:
                    environment={'file':constant_environment(directory,vec(light.GetColorAttr().Get(time))),'intensity':intensity}
                    report.append(path+': untextured dome imported as a constant-color environment')
            elif prim.IsA(UsdLux.DistantLight):
                light=UsdLux.DistantLight(prim)
                if sun:report.append(path+': additional distant light skipped');continue
                direction=normalize(vec((cache.GetLocalToWorldTransform(prim)*conversion).TransformDir(Gf.Vec3d(0,0,1))))
                sun={'direction':direction,'intensity':float(light.GetIntensityAttr().Get(time))*2**float(light.GetExposureAttr().Get(time)),'angle':float(light.GetAngleAttr().Get(time)),'normalize':bool(light.GetNormalizeAttr().Get(time))}
                report.append(path+': distant light imported as directional sun with its angle; tint not applied')
            elif prim.HasAPI(UsdLux.VolumeLightAPI):report.append(path+': VolumeLightAPI emission and volume geometry '+prim.GetTypeName()+' are not imported')
            elif prim.HasAPI(UsdLux.LightAPI):report.append(path+': unsupported light type '+prim.GetTypeName())
            elif prim.IsA(UsdGeom.Gprim) or prim.GetTypeName() in ('PointInstancer','Volume'):report.append(path+': unsupported geometry '+prim.GetTypeName())
    if len(nodes)>256 or rendered>500000:fail('Stage exceeds renderer capacity including lights')
    if not assets:fail('No supported meshes were found')
    report.insert(1,f'{len(assets)} mesh assets, {len(nodes)} nodes, {len(materials)} materials, {rendered} triangles')
    return {'nodes':nodes,'assets':assets,'materials':materials,'cameras':cameras,'environment':environment,'sun':sun,'report':report,'fallbackColors':fallbackColors}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('input');parser.add_argument('output');parser.add_argument('--frame',type=float);args=parser.parse_args()
    try:
        directory=pathlib.Path(args.output).parent
        result=import_stage(args.input,directory,args.frame)
        pathlib.Path(args.output).write_text(json.dumps(result,allow_nan=False,separators=(',',':')))
    except Exception as e:
        print('USD import failed: '+str(e),file=sys.stderr);sys.exit(1)

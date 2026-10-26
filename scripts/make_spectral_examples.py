#!/usr/bin/env python3
"""Writes the bundled spectral example stages, Examples/Spectral/*.usda (SpectralExamples in
Sources/ExampleScenes.swift; REFERENCES.md SCHOTTGLASS, DIAMANTI2014, OPENPBR, BUCHOLTZ1995, PLANCK, CIEDATA;
docs/VOLUME_DESIGN.md for the media, light spectra and spot cones).

Usage: python3 scripts/make_spectral_examples.py [OUTPUT_DIR]   (default Examples/Spectral)

The stages are committed; rerun this after changing a scene here, never edit only one side. The Abbe row's
prism rotations and slit positions come from a 2D trace of the camera ray through each prism (trace2d).
"""
import math,pathlib,sys
OUT=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else pathlib.Path(__file__).resolve().parents[1]/'Examples/Spectral'
def mat(name,inputs,comment='',extra=()):
    lines=[f'def Material "{name}"','{',f'    token outputs:mtlx:surface.connect = </Scene/Looks/{name}/Surface.outputs:out>',
           '    def Shader "Surface"','    {','        uniform token info:id = "ND_open_pbr_surface_surfaceshader"']
    if comment:lines.insert(0,'# '+comment)
    for key,(t,v) in inputs.items():
        val=f'({", ".join(f"{x:g}" for x in v)})' if isinstance(v,tuple) else (('true' if v else 'false') if isinstance(v,bool) else f'{v:g}')
        lines.append(f'        {t} inputs:{key} = {val}')
    lines+=['        token outputs:out','    }']+['    '+e for e in extra]+['}']
    return '\n'.join('        '+l for l in lines)
def bind(name):return f'        rel material:binding = </Scene/Looks/{name}>'
def xf(t=None,r=None,s=None):
    ops=[];out=[]
    if t:out.append(f'        double3 xformOp:translate = ({t[0]:g}, {t[1]:g}, {t[2]:g})');ops.append('"xformOp:translate"')
    if r:out.append(f'        float3 xformOp:rotateXYZ = ({r[0]:g}, {r[1]:g}, {r[2]:g})');ops.append('"xformOp:rotateXYZ"')
    if s:out.append(f'        float3 xformOp:scale = ({s[0]:g}, {s[1]:g}, {s[2]:g})');ops.append('"xformOp:scale"')
    out.append(f'        uniform token[] xformOpOrder = [{", ".join(ops)}]');return out
def prim(kind,name,body,metadata=''):
    if any('material:binding' in line for line in body):metadata='prepend apiSchemas = ["MaterialBindingAPI"]'
    return '\n'.join([f'    def {kind} "{name}"'+(f' (\n        {metadata}\n    )' if metadata else ''),'    {']+body+['    }'])
def camera(eye,target,focal,name='Camera'):
    d=[t-e for t,e in zip(target,eye)];yaw=math.degrees(math.atan2(-d[0],-d[2]));pitch=math.degrees(math.atan2(d[1],math.hypot(d[0],d[2])))
    # USD rotateXYZ applies X first, then Y: pitch about X, then yaw about Y.
    return prim('Camera',name,xf(eye,(pitch,yaw,0))+[f'        float focalLength = {focal:g}','        float horizontalAperture = 36','        float verticalAperture = 20.25',
        '        float2 clippingRange = (0.01, 100)'])
def stage(doc,body,root=()):
    # root: attributes of the default prim (the scene medium's vibe:medium attributes).
    head=''.join('    '+a+'\n' for a in root)+('\n' if root else '')
    return '#usda 1.0\n(\n    doc = """'+doc+'"""\n    defaultPrim = "Scene"\n    metersPerUnit = 1\n    upAxis = "Y"\n)\n\ndef Xform "Scene"\n{\n'+head+'\n\n'.join(body)+'\n}\n'
def cyclorama(look,back,radius=1.5,height=8,half=100,arc=16):
    # A photo-studio infinity cove: floor from z = half to z = back, a quarter circle of the given radius,
    # then a wall up to `height`; smooth normals, so no horizon line or edge shows behind the subject.
    profile=[(0,half,(0,1,0)),(0,back,(0,1,0))]
    for k in range(1,arc+1):
        t=math.pi/2*k/arc;profile.append((radius-radius*math.cos(t),back-radius*math.sin(t),(0,math.cos(t),math.sin(t))))
    profile.append((height,back-radius,(0,0,1)))
    points=[(x,y,z) for y,z,_ in profile for x in (-half,half)];normals=[n for _,_,n in profile for _ in (0,1)]
    quads=[(2*i,2*i+1,2*i+3,2*i+2) for i in range(len(profile)-1)]
    fmt=lambda v:'('+', '.join(f'{c:.5g}' for c in v)+')'
    return prim('Mesh','Cyclorama',[f'        int[] faceVertexCounts = [{", ".join("4" for _ in quads)}]',
        f'        int[] faceVertexIndices = [{", ".join(str(i) for q in quads for i in q)}]',
        f'        point3f[] points = [{", ".join(map(fmt,points))}]',
        f'        normal3f[] normals = [{", ".join(map(fmt,normals))}] (\n            interpolation = "vertex"\n        )',
        '        uniform token subdivisionScheme = "none"',bind(look)])

# ---- Newton's colour series -------------------------------------------------------------------
looks=[mat('Floor',{'base_color':('color3f',(0.15,0.15,0.16)),'specular_roughness':('float',0.35)})]
spheres=[]
soap=[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8]
oxide=[0.03,0.045,0.06,0.075,0.09,0.11,0.13,0.15]
for i,t in enumerate(soap):
    n=f'Soap_{int(round(t*1000))}nm'
    looks.append(mat(n,{'base_color':('color3f',(0,0,0)),'specular_ior':('float',1.0),'specular_roughness':('float',0.03),
        'thin_film_weight':('float',1.0),'thin_film_thickness':('float',t),'thin_film_ior':('float',1.33)},
        f'Soap film (n = 1.33) {t*1000:g} nm thick over an index-matched black base: the film alone reflects.' if i==0 else ''))
    spheres.append(prim('Sphere',n,['        double radius = 0.17']+xf((-1.4+0.4*i,0.17,-0.35))+[bind(n)]))
for i,t in enumerate(oxide):
    n=f'Titanium_{int(round(t*1000))}nm'
    looks.append(mat(n,{'base_color':('color3f',(0.55,0.52,0.48)),'base_metalness':('float',1.0),'specular_roughness':('float',0.08),
        'thin_film_weight':('float',1.0),'thin_film_thickness':('float',t),'thin_film_ior':('float',2.4)},
        f'Anodized titanium: an oxide film (n = 2.4) {t*1000:g} nm thick over the metal.' if i==0 else ''))
    spheres.append(prim('Sphere',n,['        double radius = 0.17']+xf((-1.4+0.4*i,0.17,0.25))+[bind(n)]))
lights=[prim('DomeLight','Tent',['        color3f inputs:color = (1, 1, 1)','        float inputs:intensity = 0.6']),
        prim('RectLight','Softbox',xf((0,3.0,1.2),(-70,0,0))+['        float inputs:width = 5','        float inputs:height = 2.5','        float inputs:intensity = 2.5'])]
doc="Newton's colour series. Back row: soap films (n 1.33) 100-800 nm thick, first- to fourth-order interference colours. Front row: anodized titanium, oxide films (n 2.4) 30-150 nm. Thin film renders in spectral light transport only."
(OUT/'NewtonSeries.usda').write_text(stage(doc,[prim('Scope','Looks',['\n\n'.join(looks)]),camera((0,1.0,3.5),(0,0.12,-0.05),36),cyclorama('Floor',-1.0)]+spheres+lights))

# ---- Abbe row ---------------------------------------------------------------------------------
glasses=[('N_SF11',1.78472,25.68),('F2',1.62004,36.37),('N_BK7',1.5168,64.17),('N_FK51A',1.48656,84.47)]
looks=[mat('Floor',{'base_color':('color3f',(0.2,0.2,0.2)),'specular_roughness':('float',0.3)}),
       mat('LightBar',{'base_color':('color3f',(0,0,0)),'emission_color':('color3f',(1,1,1)),'emission_luminance':('float',60)})]
prisms=[];bars=[]
side,height,eye,slit=0.36,0.55,(0,0.42,2.7),2.0;r=side/math.sqrt(3)
def cauchy(nd,vd,l):
    # OPENPBR dispersion: n = A + B / lambda^2 through n_d with V_d from the F and C lines (micrometres).
    lF,ld,lC=.4861327,.5875618,.6562725;B=(nd-1)/(vd*(lF**-2-lC**-2));return nd-B/ld**2+B/l**2
def trace2d(verts,o,d,n):
    # Camera ray (x, z) through a prism; the exit point and direction after exactly two refractions, else None.
    cen=(sum(v[0] for v in verts)/3,sum(v[1] for v in verts)/3);inside=False
    for event in range(2):
        best=None
        for i in range(3):
            a,b=verts[i],verts[(i+1)%3];e=(b[0]-a[0],b[1]-a[1]);den=d[1]*e[0]-d[0]*e[1]
            if abs(den)<1e-12:continue
            t=((a[1]-o[1])*e[0]-(a[0]-o[0])*e[1])/den;p=(o[0]+t*d[0],o[1]+t*d[1])
            s_=((p[0]-a[0])*e[0]+(p[1]-a[1])*e[1])/(e[0]**2+e[1]**2)
            if t>1e-7 and 0<=s_<=1 and (best is None or t<best[0]):best=(t,p,e)
        if not best:return None
        t,p,e=best;L=math.hypot(*e);nrm=(e[1]/L,-e[0]/L)
        if (p[0]-cen[0])*nrm[0]+(p[1]-cen[1])*nrm[1]<0:nrm=(-nrm[0],-nrm[1])
        if inside:nrm=(-nrm[0],-nrm[1])
        eta=n if inside else 1/n;c=-(d[0]*nrm[0]+d[1]*nrm[1]);k=1-eta*eta*(1-c*c)
        if k<0:return None
        q=eta*c-math.sqrt(k);d=(eta*d[0]+q*nrm[0],eta*d[1]+q*nrm[1]);o=p;inside=not inside
    return o,d
for i,(name,nd,vd) in enumerate(glasses):
    looks.append(mat(name,{'base_color':('color3f',(1,1,1)),'specular_ior':('float',nd),'specular_roughness':('float',0),'transmission_weight':('float',1.0),
        'transmission_dispersion_scale':('float',1.0),'transmission_dispersion_abbe_number':('float',vd)},
        f'SCHOTT {name.replace("_","-")}: n_d = {nd}, V_d = {vd} (REFERENCES.md SCHOTTGLASS).'))
    # Highest deviation on the left, so that its slit, far to the side, stays clear of the row.
    cx=-1.05+0.7*i;o=(eye[0],eye[2]);d=(cx-o[0],-o[1]);L=math.hypot(*d);d=(d[0]/L,d[1]/L)
    # Minimum deviation for the camera's ray at the d line: the classic spectroscope setting.
    best=None
    for step in range(3600):
        a0=math.radians(step/10)
        verts=[(cx+r*math.cos(a0+k*2*math.pi/3),-r*math.sin(a0+k*2*math.pi/3)) for k in range(3)]
        out=trace2d(verts,o,d,nd)
        if not out:continue
        dev=math.acos(max(-1,min(1,out[1][0]*d[0]+out[1][1]*d[1])))
        if out[1][0]*d[1]-out[1][1]*d[0]<0:continue  # deviate towards -x
        if best is None or dev<best[0]:best=(dev,a0,out)
    dev,a0,(exitp,exitd)=best
    pts=[(r*math.cos(a0+k*2*math.pi/3),y,-r*math.sin(a0+k*2*math.pi/3)) for y in (0,height) for k in range(3)]
    body=[f'        # Rotated to minimum deviation ({math.degrees(dev):.1f} degrees at the d line) for the camera ray through its centre.',
          '        int[] faceVertexCounts = [3, 3, 4, 4, 4]','        int[] faceVertexIndices = [0, 2, 1, 3, 4, 5, 0, 1, 4, 3, 1, 2, 5, 4, 2, 0, 3, 5]',
          '        point3f[] points = ['+', '.join(f'({x:.5f}, {y:g}, {z:.5f})' for x,y,z in pts)+']','        uniform token subdivisionScheme = "none"']
    prisms.append(prim('Mesh','Prism_'+name,body+xf((cx,0,0))+[bind(name)]))
    sx,sz=exitp[0]+slit*exitd[0],exitp[1]+slit*exitd[1]
    bars.append(prim('Cylinder','Slit_'+name,[f'        # Where the d-line ray leaving {name.replace("_","-")} meets a slit {slit:g} m away.','        uniform token axis = "Y"','        double radius = 0.004','        double height = 1.2']+xf((round(sx,4),0.6,round(sz,4)))+[bind('LightBar')]))

# A dim white dome shows the prisms, the floor and the slits' stands without washing out the spectra.
lights=[prim('DomeLight','Ambient',['        color3f inputs:color = (1, 1, 1)','        float inputs:intensity = 0.25'])]
doc="Abbe row: 60-degree prisms of SCHOTT N-SF11, F2, N-BK7 and N-FK51A (Abbe numbers 25.7 to 84.5) each turned to minimum deviation towards a thin white slit, as in a spectroscope. Through each prism its slit spreads into a spectrum, wider as the Abbe number falls. Dispersion renders in spectral light transport only."
(OUT/'AbbeRow.usda').write_text(stage(doc,[prim('Scope','Looks',['\n\n'.join(looks)]),camera(eye,(0,0.3,0),30),camera((1.2,4.0,3.2),(-0.9,0,-0.7),24,'Overview'),cyclorama('Floor',-2.6)]+prisms+bars+lights))

# A shaped disk light (UsdLux ShapingAPI cone) facing along its local -Z, with an optional spectrum.
def spot(name,position,rotation,radius,intensity,cone,softness,spectrum=()):
    return prim('DiskLight',name,xf(position,rotation)+[f'        float inputs:radius = {radius:g}',f'        float inputs:intensity = {intensity:g}',
        f'        float inputs:shaping:cone:angle = {cone:g}',f'        float inputs:shaping:cone:softness = {softness:g}']+['        '+a for a in spectrum],
        'prepend apiSchemas = ["ShapingAPI"]')

# ---- Tyndall tank ---------------------------------------------------------------------------------
looks=[mat('Floor',{'base_color':('color3f',(0.05,0.05,0.055)),'specular_roughness':('float',0.4)}),
       mat('Card',{'base_color':('color3f',(0.85,0.85,0.85)),'specular_roughness':('float',0.6)}),
       mat('Milk',{'specular_weight':('float',0),'transmission_weight':('float',1),'transmission_depth':('float',0.7),
                   'transmission_scatter':('color3f',(1,1,1))},
           'Index-matched boundary (specular_weight 0) around a Rayleigh-scattering medium (BUCHOLTZ1995): sigma_s = (550 nm / lambda)^4 / 0.7 per metre.',
           extra=('bool vibe:medium:rayleigh = true',))]
tank=[prim('Cube','Tank',['        double size = 1']+xf((0,0.36,0),None,(2.2,0.6,0.6))+[bind('Milk')]),
      prim('Cube','Card',['        double size = 1']+xf((2.0,0.6,0),(0,40,0),(0.02,1.2,1.2))+[bind('Card')]),
      spot('Beam',(-1.75,0.36,0),(0,-90,0),0.05,30000,2,0.5),
      prim('DomeLight','Ambient',['        color3f inputs:color = (1, 1, 1)','        float inputs:intensity = 0.04'])]
doc="Tyndall tank: a white beam crosses 2.2 m of a Rayleigh-scattering medium (scattering proportional to lambda^-4). Seen from the side the beam glows blue near its entry; the light that gets through is orange on the card. The medium needs spectral transport for its continuous lambda^-4 law (RGB evaluates it at three wavelengths)."
(OUT/'TyndallTank.usda').write_text(stage(doc,[prim('Scope','Looks',['\n\n'.join(looks)]),camera((0.15,1.0,3.4),(0.15,0.36,0),32),cyclorama('Floor',-1.5)]+tank))

# ---- Lamp spectra -----------------------------------------------------------------------------------
lamps=[('Incandescent',['token vibe:spectrum = "blackbody"','float vibe:spectrum:temperature = 2700'],'2700 K blackbody'),
       ('Daylight',['token vibe:spectrum = "D65"'],'CIE D65'),
       ('Fluorescent',['token vibe:spectrum = "FL11"'],'CIE FL11 narrow-band fluorescent'),
       ('Sodium',['token vibe:spectrum = "HP1"'],'CIE HP1 high-pressure sodium'),
       ('LED',['token vibe:spectrum = "LED-B3"'],'CIE LED-B3 phosphor white LED')]
looks=[mat('Floor',{'base_color':('color3f',(0.18,0.18,0.18)),'specular_roughness':('float',0.5)}),
       mat('Plinth',{'base_color':('color3f',(0.8,0.8,0.8)),'specular_roughness':('float',0.5)}),
       mat('Red',{'base_color':('color3f',(0.7,0.08,0.06)),'specular_roughness':('float',0.3)}),
       mat('Green',{'base_color':('color3f',(0.1,0.55,0.12)),'specular_roughness':('float',0.3)}),
       mat('Blue',{'base_color':('color3f',(0.08,0.15,0.65)),'specular_roughness':('float',0.3)})]
objects=[]
for i,(name,spectrum,label) in enumerate(lamps):
    x=-2.2+1.1*i
    objects.append(prim('Cylinder','Plinth_'+name,['        uniform token axis = "Y"','        double radius = 0.28','        double height = 0.3']+xf((x,0.15,0))+[bind('Plinth')]))
    for j,(colour,dx,dz) in enumerate([('Red',-0.12,0.07),('Green',0.12,0.07),('Blue',0,-0.13)]):
        objects.append(prim('Sphere',f'{colour}_{name}',['        double radius = 0.09']+xf((x+dx,0.39,dz))+[bind(colour)]))
    objects.append(spot('Lamp_'+name,(x,2.6,0),(-90,0,0),0.08,900,13,0.4,spectrum))
objects.append(prim('DomeLight','Ambient',['        color3f inputs:color = (1, 1, 1)','        float inputs:intensity = 0.02']))
doc="Lamp spectra: the same red, green and blue spheres under five spot lamps of equal luminance in light haze: a 2700 K blackbody, CIE D65, FL11 (fluorescent), HP1 (sodium) and LED-B3. Under sodium light the colours collapse to orange and black. The lamps' spectra render in spectral transport; RGB uses the blackbody's colour and keeps presets white."
haze=('float vibe:medium:density = 0.06','color3f vibe:medium:albedo = (0.95, 0.95, 0.95)','float vibe:medium:anisotropy = 0.5')
(OUT/'LampSpectra.usda').write_text(stage(doc,[prim('Scope','Looks',['\n\n'.join(looks)]),camera((0,1.6,5.2),(0,0.6,0),30),cyclorama('Floor',-1.8)]+objects,root=haze))

#!/usr/bin/env python3
"""Bake an original imperial-hall study into Google Three-Live authoring JS.

Standard library only. The upstream three-live-authoring skill and llm-guide
were followed: use injected THREE/scene, supported BufferGeometry/materials,
no host renderer, external assets, textures, loops or normal calculation in JS.
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCALE = 0.024
MATS = {
    'courtyard_basalt': ('#484d4c', 0, .91),
    'paving_sandstone': ('#8b8b7f', 0, .91),
    'terrace_warm_marble': ('#d5cbb4', 0, .8),
    'rail_carved_marble': ('#eee4ce', 0, .65),
    'plinth_shadow': ('#9e998c', 0, .88),
    'cinnabar_columns': ('#a53223', 0, .47),
    'vermilion_joinery': ('#c24329', 0, .53),
    'shadowed_rosewood': ('#391f19', 0, .72),
    'lattice_goldwood': ('#bf8750', .15, .57),
    'bracket_jade': ('#207c71', 0, .54),
    'bracket_lapis': ('#244757', 0, .59),
    'painted_cream': ('#ddcb91', 0, .65),
    'roof_honey_glaze': ('#b26c14', .12, .38),
    'roof_tile_light': ('#dc9828', .16, .33),
    'roof_tile_shadow': ('#875019', .08, .46),
    'ridge_imperial_gold': ('#eac05a', .5, .29),
    'lantern_silk': ('#d65a2c', 0, .65),
}
BUCKETS = {name: {'p': [], 'n': [], 'i': [], 'lookup': {}} for name in MATS}
PARTS = {}


def sub(a, b): return tuple(a[i] - b[i] for i in range(3))
def add(a, b): return tuple(a[i] + b[i] for i in range(3))
def mul(a, s): return tuple(v * s for v in a)
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def norm(a):
    length = math.sqrt(sum(v*v for v in a))
    return mul(a, 1 / length) if length > 1e-9 else (0, 1, 0)


def vertex(mat, p, n):
    bucket = BUCKETS[mat]
    key = tuple(round(v, 2) for v in p) + tuple(round(v, 6) for v in n)
    if key not in bucket['lookup']:
        bucket['lookup'][key] = len(bucket['p']) // 3
        bucket['p'].extend(key[:3])
        bucket['n'].extend(key[3:])
    return bucket['lookup'][key]


def quad(mat, a, b, c, d, flip=False):
    if flip: a, b, c, d = d, c, b, a
    raw=cross(sub(b,a),sub(c,a))
    if sum(v*v for v in raw)<1e-12: raw=cross(sub(c,a),sub(d,a))
    n = norm(raw)
    ids = [vertex(mat, p, n) for p in (a,b,c,d)]
    for tri in ((0,1,2),(0,2,3)):
        if len({ids[j] for j in tri})==3:
            BUCKETS[mat]['i'].extend(ids[j] for j in tri)


def box(mat, x, y, z, w, h, d):
    x0,x1 = x-w/2,x+w/2
    y0,y1 = y-h/2,y+h/2
    z0,z1 = z-d/2,z+d/2
    for face in [
        [(x0,y0,z1),(x1,y0,z1),(x1,y1,z1),(x0,y1,z1)],
        [(x1,y0,z0),(x0,y0,z0),(x0,y1,z0),(x1,y1,z0)],
        [(x1,y0,z1),(x1,y0,z0),(x1,y1,z0),(x1,y1,z1)],
        [(x0,y0,z0),(x0,y0,z1),(x0,y1,z1),(x0,y1,z0)],
        [(x0,y1,z1),(x1,y1,z1),(x1,y1,z0),(x0,y1,z0)],
        [(x0,y0,z0),(x1,y0,z0),(x1,y0,z1),(x0,y0,z1)],
    ]: quad(mat, *face)


def tube(mat, points, radius, sides=5, caps=False):
    """Smooth normals along a low-poly swept cylinder, baked before runtime."""
    rings=[]
    for j,p in enumerate(points):
        tangent=norm(sub(points[min(j+1,len(points)-1)],points[max(j-1,0)]))
        u=norm(cross(tangent, (0,0,1) if abs(tangent[2])<.85 else (0,1,0)))
        v=norm(cross(tangent,u))
        ring=[]
        for k in range(sides):
            angle=2*math.pi*k/sides
            normal=add(mul(u,math.cos(angle)),mul(v,math.sin(angle)))
            ring.append(vertex(mat,add(p,mul(normal,radius)),normal))
        rings.append(ring)
    for a,b in zip(rings,rings[1:]):
        for k in range(sides):
            q=(k+1)%sides
            BUCKETS[mat]['i'].extend((a[k],b[q],b[k],a[k],a[q],b[q]))
    if caps:
        for endpoint, ring, direction in [(points[0],rings[0],-1),(points[-1],rings[-1],1)]:
            n=mul(norm(sub(points[-1],points[0])),direction)
            center=vertex(mat,endpoint,n)
            ids=[vertex(mat,tuple(BUCKETS[mat]['p'][index*3:index*3+3]),n) for index in ring]
            for k in range(sides):
                pair=(ids[k],ids[(k+1)%sides])
                if direction<0: pair=pair[::-1]
                BUCKETS[mat]['i'].extend((center,*pair))


def cylinder(mat,x,y,z,r,h,sides=8):
    tube(mat,[(x,y-h/2,z),(x,y+h/2,z)],r,sides,True)


def roof_point(face,u,v,w,d,ridge,top,drop):
    # Concave sweep with a steep ridge and flattened lower apron, then upturned
    # eaves. Corner uplift is stronger than mid-eave uplift.
    yy=top-drop*(v**.72)+.68*(v**6)*(1+.65*abs(u)**4)
    if face in (0,1):
        return (u*(ridge+(w-ridge)*v),yy,(-1 if face==0 else 1)*d*v)
    return ((-1 if face==2 else 1)*(ridge+(w-ridge)*v),yy,u*d*v)


def make_roof(label,w,d,ridge,top,drop):
    def p(face,u,v,lift=0):
        x,y,z=roof_point(face,u,v,w,d,ridge,top,drop)
        return (x,y+lift,z)
    for face in range(4):
        nu=12 if face<2 else 6
        nv=6
        for j in range(nv):
            for i in range(nu):
                u0,u1=-1+2*i/nu,-1+2*(i+1)/nu
                v0,v1=j/nv,(j+1)/nv
                points=[p(face,u0,v0),p(face,u1,v0),p(face,u1,v1),p(face,u0,v1)]
                # Surface winding must point outward/up on every roof face.
                normal=cross(sub(points[1],points[0]),sub(points[2],points[0]))
                if sum(value*value for value in normal)<1e-12:
                    normal=cross(sub(points[2],points[0]),sub(points[3],points[0]))
                quad('roof_honey_glaze',*points,flip=normal[1]<0)
        ribs=28 if face<2 else 12
        for i in range(ribs+1):
            u=-1+2*i/ribs
            points=[p(face,u,.018+.982*j/5,.035) for j in range(6)]
            tube('roof_tile_light' if i%3 else 'roof_tile_shadow',points,.053,3)
        # Curving tile-course seams give the roof a recognizable tile field.
        for v in (.27,.45,.62,.77,.9):
            tube('roof_tile_shadow',[p(face,-1+2*j/6,v,.014) for j in range(7)],.023,3)
        eave=[p(face,-1+2*j/12,1,.03) for j in range(13)]
        tube('ridge_imperial_gold',eave,.115,5)
        tube('roof_tile_shadow',[(x,y-.18,z) for x,y,z in eave],.105,4)
        # Gilded hip ridges are shared by faces: create only on large faces.
        if face<2:
            for u in (-1,1):
                hip=[p(face,u,j/6,.1) for j in range(7)]
                tube('ridge_imperial_gold',hip,.13,5)
                for v in (.77,.94):
                    x,y,z=p(face,u,v,.2)
                    # Abstract procession of ridge beasts: body, head and crest.
                    cylinder('ridge_imperial_gold',x,y+.09,z,.13,.27,6)
                    tube('ridge_imperial_gold',[(x,y+.15,z),(x-.1*u,y+.32,z+.035)],.09,5,True)
                    tube('ridge_imperial_gold',[(x,y+.31,z),(x+.07*u,y+.48,z)],.035,4)
    tube('ridge_imperial_gold',[(-ridge-.12,top+.14,0),(0,top+.22,0),(ridge+.12,top+.14,0)],.17,8,True)
    for sign in (-1,1):
        x=sign*ridge
        tube('ridge_imperial_gold',[(x,top+.1,0),(x+sign*.16,top+.48,0),(x+sign*.34,top+.89,0),(x+sign*.23,top+1.24,0)],.16,6)
        tube('ridge_imperial_gold',[(x+sign*.22,top+.68,0),(x-sign*.18,top+.89,0),(x-sign*.38,top+.83,0)],.1,5)
        cylinder('ridge_imperial_gold',x+sign*.27,top+1.14,0,.11,.24,6)
    PARTS[label]={'type':'curved four-face hipped roof','half_width':w,'half_depth':d,'top':top,'tile_ribs':(29*2+13*2)}


def railing_run(a,b,y,spacing=3.0):
    length=math.dist(a,b)
    count=max(1,round(length/spacing))
    for i in range(count+1):
        t=i/count
        x,z=a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t
        box('rail_carved_marble',x,y+.51,z,.19,.98,.19)
        cylinder('rail_carved_marble',x,y+1.08,z,.19,.17,6)
        box('rail_carved_marble',x,y+.08,z,.36,.16,.36)
    for h in (.3,.8):
        tube('rail_carved_marble',[(a[0],y+h,a[1]),(b[0],y+h,b[1])],.075,4)
    # Center panels are low solid balusters, leaving light through the rails.
    for i in range(count):
        t=(i+.5)/count
        x,z=a[0]+(b[0]-a[0])*t,a[1]+(b[1]-a[1])*t
        box('terrace_warm_marble',x,y+.42,z,.18,.6,.18)


def main():
    # Dark plinth frames a compact courtyard without overwhelming the hall.
    box('courtyard_basalt',0,.14,1.1,42,.28,34)
    for row in range(4):
        for col in range(10):
            box('paving_sandstone',-18.3+col*4.05,.305,-11.9+row*8.4,3.95,.05,8.28)
    # Three successively inset, layered stone terraces.
    for w,d,y,h in [(36,26,.55,.5),(34,24,1.12,.64),(32,22,1.8,.72)]:
        box('plinth_shadow',0,y,0,w,h,d)
        box('terrace_warm_marble',0,y+h/2+.085,0,w+.16,.17,d+.16)
        box('terrace_warm_marble',0,y-h/2+.075,0,w+.1,.15,d+.1)
    floor=2.25
    # Pale stone balustrade, central stair openings at front and back.
    for x in (-15.7,15.7): railing_run((x,-10.8),(x,10.8),floor)
    for z in (-10.8,10.8):
        railing_run((-15.7,z),(-3.6,z),floor)
        railing_run((3.6,z),(15.7,z),floor)
    # Broad ritual approach stairs; raised central ramp bears a gold motif.
    for j in range(11):
        top=.42+(11-j)*.166
        z=10.1+j*.48
        box('terrace_warm_marble',0,top/2,z,7.0,top,.51)
    tube('rail_carved_marble',[(-3.35,2.72,10.0),(-3.35,.85,15.3)],.13,6)
    tube('rail_carved_marble',[(3.35,2.72,10.0),(3.35,.85,15.3)],.13,6)
    # Decorative central stair ribbon remains above the individual treads.
    for j in range(10):
        y=2.27-j*.166
        z=10.1+j*.48
        box('rail_carved_marble',0,y,z,1.35,.08,.52)
        tube('lattice_goldwood',[(-.43,y+.05,z-.17),(.1,y+.05,z),(.43,y+.05,z+.17)],.026,4)
    # Hall floor is raised slightly above the terrace, with an open colonnade.
    box('shadowed_rosewood',0,2.37,0,28,.22,17)
    box('terrace_warm_marble',0,2.31,0,28.7,.16,17.7)
    col_positions=[]
    for z in (-7.5,7.5):
        for x in (-12,-8,-4,0,4,8,12): col_positions.append((x,z))
    for x in (-12,12):
        for z in (-3.75,0,3.75): col_positions.append((x,z))
    for x,z in col_positions:
        cylinder('plinth_shadow',x,2.62,z,.39,.45,6)
        cylinder('rail_carved_marble',x,2.87,z,.33,.15,6)
        cylinder('cinnabar_columns',x,5.33,z,.255,4.85,8)
        cylinder('lattice_goldwood',x,3.05,z,.27,.08,8)
        cylinder('lattice_goldwood',x,7.45,z,.28,.12,8)
        # Two intersecting bracket arms and alternating stepped corbels.
        for k in range(2):
            yy=7.72+k*.23
            box('bracket_jade' if k%2==0 else 'bracket_lapis',x,yy,z,.56+k*.35,.18,.32)
            box('bracket_lapis' if k%2==0 else 'bracket_jade',x,yy+.09,z,.3,.16,.6+k*.31)
        for dx in (-.58,.58):
            box('vermilion_joinery',x+dx,7.95,z,.18,.56,.3)
    # Deep teal, cream and red horizontal painted beam courses.
    for z in (-7.5,7.5):
        for yy,hh,mat in [(7.6,.28,'vermilion_joinery'),(8.26,.3,'bracket_lapis'),(8.49,.15,'painted_cream'),(8.66,.2,'bracket_jade')]:
            box(mat,0,yy,z,25.3,hh,.43)
    for x in (-12,12):
        for yy,hh,mat in [(7.6,.28,'vermilion_joinery'),(8.26,.3,'bracket_lapis'),(8.49,.15,'painted_cream'),(8.66,.2,'bracket_jade')]:
            box(mat,x,yy,0,.43,hh,15.5)
    # Inner wall set back from columns; lattice leaves and thresholds.
    for sign in (-1,1):
        z=sign*5.0
        box('shadowed_rosewood',0,4.92,z,22,5.05,.23)
        for x in (-9.6,-6.4,-3.2,0,3.2,6.4,9.6):
            box('vermilion_joinery',x,4.94,z+sign*.15,.11,4.98,.17)
        for x in (-8,-4.8,-1.6,1.6,4.8,8):
            box('cinnabar_columns',x,3.44,z+sign*.16,2.83,1.65,.14)
            for dx in (-1.0,0,1.0):
                box('lattice_goldwood',x+dx,5.65,z+sign*.23,.055,2.75,.07)
            for yy in (4.4,5.3,6.2,7.0):
                box('lattice_goldwood',x,yy,z+sign*.24,2.8,.05,.075)
            for yy in (2.65,4.28,7.17):
                box('lattice_goldwood',x,yy,z+sign*.2,2.87,.075,.14)
    for x in (-10.9,10.9):
        box('shadowed_rosewood',x,4.92,0,.2,5.05,9.9)
        for z in (-3.5,0,3.5):
            box('vermilion_joinery',x,4.9,z,.3,5.0,.15)
        for z in (-4,-2.7,-1.35,0,1.35,2.7,4):
            box('lattice_goldwood',x,5.6,z,.25,2.6,.055)
        for yy in (4.4,5.3,6.2,7):
            box('lattice_goldwood',x,yy,0,.26,.055,9.6)
    make_roof('lower_eaves',14.9,9.5,6.2,11.12,2.84)
    # The exposed clerestory separates the two complete hipped roof tiers.
    box('shadowed_rosewood',0,10.9,0,21.6,2.1,10.4)
    for z in (-5.25,5.25):
        for x in (-10,-6,-2,2,6,10):
            box('cinnabar_columns',x,10.85,z,.22,2.18,.26)
            box('bracket_jade',x,11.75,z,1.05,.2,.52)
            box('painted_cream',x,11.93,z,1.35,.1,.45)
        for yy,mat in [(10.05,'vermilion_joinery'),(11.65,'bracket_lapis'),(12.1,'bracket_jade')]:
            box(mat,0,yy,z,21.5,.18,.24)
        for x in (-8,-4,0,4,8):
            for dx in (-1,0,1):
                box('lattice_goldwood',x+dx,10.9,z,.045,1.25,.27)
    make_roof('upper_eaves',13.6,8.15,5.4,16.3,4.05)
    # Four hanging lanterns articulate the front veranda without masking doors.
    for x in (-9,-3,3,9):
        z=6.9
        tube('shadowed_rosewood',[(x,7.47,z),(x,6.7,z)],.025,4)
        cylinder('ridge_imperial_gold',x,6.62,z,.31,.1,8)
        cylinder('lantern_silk',x,6.26,z,.36,.62,8)
        cylinder('ridge_imperial_gold',x,5.92,z,.3,.08,8)
        tube('ridge_imperial_gold',[(x,5.9,z),(x,5.57,z)],.045,4)
    # Shallow decorative beam panels above the front colonnade.
    for x in (-10,-6,-2,2,6,10):
        box('painted_cream',x,8.28,7.75,2.55,.08,.06)
        for dx in (-1,0,1):
            tube('ridge_imperial_gold',[(x+dx-.21,8.17,7.8),(x+dx,8.33,7.8),(x+dx+.21,8.17,7.8)],.035,4)
    PARTS.update({'columns':len(col_positions),'lattice_door_leaves':12,'terrace_levels':3,'roof_tiers':2,'stair_treads':11,'lanterns':4})
    emit()


def jsnum(x):
    if x==int(x): return str(int(x))
    return ('%.6f'%x).rstrip('0').rstrip('.')


def emit():
    # Validate the final rounded positions rather than unquantized design data.
    # Thin swept ribs may turn slightly at a quantized corner: choose each
    # triangle's winding to agree with its outward vertex normals.
    winding_repairs=0
    max_normal_error=0
    duplicate_triangles_removed=0
    for bucket in BUCKETS.values():
        # Adjacent railing runs share corner posts; roof seams can also share
        # one swept face. Keep one copy so USD renderers do not z-fight.
        unique=[]
        seen=set()
        for offset in range(0,len(bucket['i']),3):
            triangle=bucket['i'][offset:offset+3]
            key=tuple(sorted(triangle))
            if key in seen:
                duplicate_triangles_removed+=1
                continue
            seen.add(key)
            unique.extend(triangle)
        bucket['i']=unique
        positions=[bucket['p'][i:i+3] for i in range(0,len(bucket['p']),3)]
        normals=[bucket['n'][i:i+3] for i in range(0,len(bucket['n']),3)]
        for normal in normals:
            error=abs(math.sqrt(sum(value*value for value in normal))-1)
            max_normal_error=max(max_normal_error,error)
            assert error<.00001,normal
        for offset in range(0,len(bucket['i']),3):
            indices=bucket['i'][offset:offset+3]
            a,b,c=[positions[index] for index in indices]
            face=cross(sub(b,a),sub(c,a))
            assert sum(value*value for value in face)>1e-20,(a,b,c)
            mean=tuple(sum(normals[index][axis] for index in indices) for axis in range(3))
            if sum(face[axis]*mean[axis] for axis in range(3))<0:
                bucket['i'][offset+1],bucket['i'][offset+2]=bucket['i'][offset+2],bucket['i'][offset+1]
                winding_repairs+=1
    out=['// Original imperial-hall study. Google Three-Live injected THREE/scene.\n// Geometry and normals baked by scripts/generate_palace.py.\n']
    stats=[]
    for number,(name,(color,metal,rough)) in enumerate(MATS.items()):
        b=BUCKETS[name]
        if not b['p']: continue
        out.append('{\nconst g=new THREE.BufferGeometry();\n')
        for attr,key in [('position','p'),('normal','n')]:
            out.append("g.setAttribute('%s',new THREE.BufferAttribute(new Float32Array([%s]),3));\n"%(attr,','.join(map(jsnum,b[key]))))
        out.append('g.setIndex(new THREE.BufferAttribute(new Uint32Array([%s]),1));\n'%','.join(map(str,b['i'])))
        out.append("const m=new THREE.MeshStandardMaterial({color:'%s',metalness:%s,roughness:%s});\n"%(color,metal,rough))
        out.append("const mesh=new THREE.Mesh(g,m);mesh.name='%s';mesh.scale.set(%s,%s,%s);scene.add(mesh);\n}\n"%(name,SCALE,SCALE,SCALE))
        stats.append({'material':name,'vertices':len(b['p'])//3,'indices':len(b['i']),'triangles':len(b['i'])//3})
    text=''.join(out)
    scene_dir=ROOT/'scenes'
    scene_dir.mkdir(exist_ok=True)
    (scene_dir/'palace.js').write_text(text)
    metadata={
        'title':'琉金重檐殿 / Golden Eaves Hall',
        'description':'Original parametric imperial hall inspired by Chinese Ming/Qing monumental timber architecture; not a measured replica or historical restoration.',
        'source_generator':'scripts/generate_palace.py',
        'compiler':'Google Three-Live native authoring DSL',
        'scale_meters_per_design_unit':SCALE,
        'presentation':'Tabletop architectural model; front is +Z, up is +Y, ground minimum Y=0.',
        'bounds_meters':{
            name:(max(value for bucket in BUCKETS.values() for value in bucket['p'][axis::3])-min(value for bucket in BUCKETS.values() for value in bucket['p'][axis::3]))*SCALE
            for name,axis in [('width',0),('depth',2),('height',1)]
        },
        'parts':PARTS,
        'script_bytes':len(text.encode()),
        'meshes':len(stats),
        'vertices':sum(s['vertices'] for s in stats),
        'indices':sum(s['indices'] for s in stats),
        'triangles':sum(s['triangles'] for s in stats),
        'host_geometry_validation':{'max_normal_length_error':max_normal_error,'degenerate_triangles':0,'triangles_oriented_to_outward_normals':True,'quantized_corner_winding_repairs':winding_repairs,'duplicate_triangles_removed':duplicate_triangles_removed},
        'materials':stats,
        'authoring_instructions_read':['upstream/AGENTS.md','upstream/skills/three-live-authoring/SKILL.md','upstream/docs/llm-guide.md'],
        'notes':['Geometry and normals are precomputed in Python; runtime authoring only constructs supported BufferGeometry and MeshStandardMaterial.','No input model, textures, pretrained weights, cloud inference, downloaded geometry, or Three.js exporters.','Ridge ornaments are deliberately abstract, not historically complete zoomorphic sculptures.'],
    }
    assert metadata['script_bytes']<1048576,metadata
    assert metadata['vertices']<100000 and metadata['indices']<300000,metadata
    (scene_dir/'palace-source.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:metadata[k] for k in ('script_bytes','meshes','vertices','indices','triangles')},indent=2))


if __name__=='__main__': main()

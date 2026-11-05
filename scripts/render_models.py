"""Blender readback and matched-camera renders of exported files, never generation."""
import argparse
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index('--') + 1:]
parser = argparse.ArgumentParser()
parser.add_argument('model')
parser.add_argument('output')
options = parser.parse_args(args)
model_path, output = Path(options.model).resolve(), Path(options.output).resolve()
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
if model_path.suffix == '.glb':
    bpy.ops.import_scene.gltf(filepath=str(model_path))
else:
    bpy.ops.wm.usd_import(filepath=str(model_path))

meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
if not meshes:
    raise RuntimeError('No imported mesh geometry')
points = [o.matrix_world @ Vector(corner) for o in meshes for corner in o.bound_box]
lower = Vector([min(p[i] for p in points) for i in range(3)])
upper = Vector([max(p[i] for p in points) for i in range(3)])
center = (lower + upper) * 0.5
width = max(upper.x - lower.x, upper.y - lower.y)
geometry = {
    'file': model_path.name,
    'mesh_objects': len(meshes),
    'vertices': sum(len(o.data.vertices) for o in meshes),
    'triangles': sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in meshes),
    'bounds_blender_z_up': [list(lower), list(upper)],
    'materials': sorted({slot.material.name for o in meshes for slot in o.material_slots if slot.material}),
    'note': 'Imported artifact rendered in Blender; geometry originated in Google Three-Live native compiler.'
}
output.with_suffix('.json').write_text(json.dumps(geometry, indent=2) + '\n')
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 32
scene.cycles.use_denoising = True
scene.render.resolution_x = 1600
scene.render.resolution_y = 1200
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.film_transparent = False
scene.view_settings.view_transform = 'AgX'
scene.view_settings.exposure = -1.4
scene.world.use_nodes = True
background = next(n for n in scene.world.node_tree.nodes if n.type == 'BACKGROUND')
background.inputs[0].default_value = (0.26, 0.29, 0.32, 1)
background.inputs[1].default_value = 0.35

bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, lower.z - 0.001))
floor = bpy.context.object
floor.name = 'Render_only_studio_floor'
mat = bpy.data.materials.new('Render_only_neutral_background')
mat.diffuse_color = (0.075, 0.09, 0.085, 1)
mat.use_nodes = True
mat.node_tree.nodes.clear()
surface = mat.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
material_output = mat.node_tree.nodes.new('ShaderNodeOutputMaterial')
mat.node_tree.links.new(surface.outputs['BSDF'], material_output.inputs['Surface'])
surface.inputs['Base Color'].default_value = (0.075, 0.09, 0.085, 1)
surface.inputs['Roughness'].default_value = 0.9
floor.data.materials.append(mat)

def light(name, position, power, color, size):
    data = bpy.data.lights.new(name, 'AREA')
    data.energy = power
    data.color = color
    data.shape = 'DISK'
    data.size = size
    ob = bpy.data.objects.new(name, data)
    scene.collection.objects.link(ob)
    ob.location = position
    ob.rotation_euler = (center - ob.location).to_track_quat('-Z', 'Y').to_euler()

light('Render_only_key', (width * 0.2, -width, width * 1.8), 110 * width * width, (1, 0.86, 0.68), width * 1.3)
light('Render_only_fill', (-width, -width * 0.3, width), 60 * width * width, (0.65, 0.78, 1), width * 1.5)
light('Render_only_rim', (width * 0.7, width, width * 1.4), 150 * width * width, (1, 0.92, 0.77), width)
data = bpy.data.cameras.new('Render_only_camera')
camera = bpy.data.objects.new('Render_only_camera', data)
scene.collection.objects.link(camera)
camera.location = center + Vector((width * 1.15, -width * 1.5, width * 0.95))
camera.rotation_euler = (center - camera.location).to_track_quat('-Z', 'Y').to_euler()
data.type = 'ORTHO'
data.ortho_scale = width * 1.45
data.clip_start = 0.001
data.clip_end = 100
scene.camera = camera
scene.render.filepath = str(output)
bpy.ops.wm.save_as_mainfile(filepath=str(output.with_suffix('.blend')))
bpy.ops.render.render(write_still=True)
print('ARTIFACT_IMPORT ' + json.dumps(geometry))

import bpy, sys, math, numpy as np
from mathutils import Vector
args = sys.argv[sys.argv.index("--")+1:]
path, out = args[0], args[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
mesh = None
for o in list(bpy.data.objects):
    if o.type == "MESH" and o.name.startswith("tripo"): mesh = o
for o in list(bpy.data.objects):
    if o is not mesh: bpy.data.objects.remove(o, do_unlink=True)
mesh.parent = None
for m in list(mesh.modifiers): mesh.modifiers.remove(m)
mw = mesh.matrix_world
co = np.array([mw @ v.co for v in mesh.data.vertices])
print("BOUNDS", co.min(0).round(3), co.max(0).round(3))
# width profile by height
zs = np.linspace(co[:,2].min(), co[:,2].max(), 21)
for a,b in zip(zs[:-1], zs[1:]):
    s = co[(co[:,2]>=a)&(co[:,2]<b)]
    if len(s): print("Z %.2f-%.2f n=%5d x[%.2f,%.2f] y[%.2f,%.2f]" % (a,b,len(s),s[:,0].min(),s[:,0].max(),s[:,1].min(),s[:,1].max()))
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"; sc.display.shading.color_type = "TEXTURE"
sc.render.resolution_x = sc.render.resolution_y = 700
sc.render.film_transparent = False
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam); sc.camera = cam
cam.data.type = "ORTHO"; cam.data.ortho_scale = 1.3
c = (co.min(0)+co.max(0))/2
for name, d in [("front",(0,-3,0)),("side",(3,0,0)),("back",(0,3,0)),("top",(0,0,3))]:
    cam.location = Vector(c)+Vector(d)
    dirv = Vector(c)-cam.location
    cam.rotation_euler = dirv.to_track_quat("-Z","Y").to_euler()
    sc.render.filepath = f"{out}/look_{name}.png"; bpy.ops.render.render(write_still=True)

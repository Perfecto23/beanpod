import bpy, sys
path = sys.argv[sys.argv.index("--")+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
for o in bpy.data.objects:
    print("OBJ", o.type, o.name, [round(v,3) for v in o.dimensions], [round(v,3) for v in o.location])
    if o.type == "MESH":
        print("  verts", len(o.data.vertices), "polys", len(o.data.polygons), "vgroups", len(o.vertex_groups), "mats", [m.name for m in o.data.materials])
    if o.type == "ARMATURE":
        for b in o.data.bones:
            print("  BONE", b.name, "<-", b.parent.name if b.parent else None, [round(v,3) for v in b.head_local], [round(v,3) for v in b.tail_local])
print("ACTIONS", [a.name for a in bpy.data.actions])
print("IMAGES", [(i.name, tuple(i.size)) for i in bpy.data.images])

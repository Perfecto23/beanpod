# 把 Tripo 导出的静态道具（充电仓）减面后导出成和仓鼠同样的二进制格式（只有一块骨头）
# 用法：blender -b --python prop.py -- <模型.glb> <输出目录> <名字> [三角面数]
import bpy, bmesh, sys, json, struct
import numpy as np
args = sys.argv[sys.argv.index("--") + 1:]
src, out, name = args[0], args[1], args[2]
target = int(args[3]) if len(args) > 3 else 16000
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.data.objects if o.type == "MESH" and len(o.data.polygons) > 200]
for o in list(bpy.data.objects):
    if o not in meshes: bpy.data.objects.remove(o, do_unlink=True)
bpy.context.view_layer.objects.active = meshes[0]
for o in meshes: o.select_set(True)
if len(meshes) > 1: bpy.ops.object.join()
obj = bpy.context.view_layer.objects.active
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
me = obj.data
# 贴图颜色先存到顶点上：高模的贴图岛太碎，带着贴图坐标减不下面
img0 = next(i for i in bpy.data.images if "basecolor" in i.name.lower() or i.name.startswith("tripo_image"))
R = img0.size[0]
px = np.array(img0.pixels[:], dtype=np.float32).reshape(R, R, 4)
nl0 = len(me.loops)
uv0 = np.zeros(nl0 * 2, dtype=np.float32); me.uv_layers.active.data.foreach_get("uv", uv0); uv0 = uv0.reshape(-1, 2)
xi = np.clip((uv0[:, 0] % 1 * R).astype(int), 0, R - 1); yi = np.clip((uv0[:, 1] % 1 * R).astype(int), 0, R - 1)
lc = px[yi, xi].copy(); lc[:, 3] = 1
attr = me.color_attributes.new("col", "FLOAT_COLOR", "CORNER")
attr.data.foreach_set("color", lc.ravel())
while me.uv_layers: me.uv_layers.remove(me.uv_layers[0])
bm = bmesh.new(); bm.from_mesh(me)
bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
bmesh.ops.triangulate(bm, faces=bm.faces[:]); bm.to_mesh(me); bm.free()
n = len(me.polygons)
if n > target:
    mod = obj.modifiers.new("d", "DECIMATE"); mod.ratio = target / n
    bpy.ops.object.modifier_apply(modifier="d")
me = obj.data
for p in me.polygons: p.use_smooth = True
nl = len(me.loops)
vi = np.zeros(nl, dtype=np.int32); me.loops.foreach_get("vertex_index", vi)
co = np.zeros(len(me.vertices) * 3, dtype=np.float32); me.vertices.foreach_get("co", co); co = co.reshape(-1, 3)
nor = np.zeros(len(me.vertices) * 3, dtype=np.float32); me.vertices.foreach_get("normal", nor); nor = nor.reshape(-1, 3)
col = np.zeros(nl * 4, dtype=np.float32); me.color_attributes["col"].data.foreach_get("color", col); col = col.reshape(-1, 4)
C = np.zeros((len(co), 3), dtype=np.float32); cnt = np.zeros(len(co), dtype=np.float32)
np.add.at(C, vi, col[:, :3]); np.add.at(cnt, vi, 1); C /= np.maximum(cnt, 1)[:, None]
P, N = co, nor
T = np.zeros_like(P); S = np.ones(len(P), dtype=np.float32); UV = np.zeros((len(P), 2), dtype=np.float32)
tl = np.zeros(len(me.loop_triangles) * 3, dtype=np.int32); me.loop_triangles.foreach_get("loops", tl)
idx = vi[tl].astype(np.uint32)
print("VERTS", len(P), "TRIS", len(idx) // 3, "BOUNDS", P.min(0).round(3), P.max(0).round(3))
sk = lambda v: np.stack([v[..., 0], v[..., 2], -v[..., 1]], axis=-1)
bi = np.zeros((len(P), 4), dtype="<u2"); bw = np.zeros((len(P), 4), dtype="<f4"); bw[:, 0] = 1
with open(f"{out}/{name}.mesh", "wb") as f:
    f.write(struct.pack("<II", len(P), len(idx)))
    for a in (sk(P), sk(N), np.hstack([sk(T), S[:, None]]), np.stack([UV[:, 0], 1 - UV[:, 1]], axis=1)): f.write(a.astype("<f4").tobytes())
    f.write(bi.tobytes()); f.write(bw.tobytes()); f.write(idx.astype("<u4").tobytes())
    f.write(C.astype("<f4").tobytes())
json.dump({"colors": True, "bones": [{"name": "root", "parent": -1, "pivot": [0, 0, 0]}]}, open(f"{out}/{name}.json", "w"))
print("DONE")

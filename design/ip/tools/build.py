# 把 Tripo 导出的仓鼠模型做成 App 可用的资源：
#   重建一套适合圆滚滚体型的骨骼权重 → 导出二进制网格 + 表情贴图 + 耳机光圈遮罩
# 用法：blender -b --python build.py -- <模型.glb> <输出目录>
import bpy, bmesh, sys, json, struct
import numpy as np

args = sys.argv[sys.argv.index("--") + 1:]
src, out = args[0], args[1]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
mesh_obj = next(o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("tripo"))
for o in list(bpy.data.objects):
    if o is not mesh_obj:
        bpy.data.objects.remove(o, do_unlink=True)
mesh_obj.parent = None
for m in list(mesh_obj.modifiers):
    mesh_obj.modifiers.remove(m)
me = mesh_obj.data

bm = bmesh.new(); bm.from_mesh(me)
bmesh.ops.triangulate(bm, faces=bm.faces[:])
bm.to_mesh(me); bm.free()
me.calc_tangents()

mw = np.array(mesh_obj.matrix_world)


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


# ---------- 顶点（按 loop 展开，再合并相同的） ----------
nl = len(me.loops)
vi = np.zeros(nl, dtype=np.int32); me.loops.foreach_get("vertex_index", vi)
co = np.zeros(len(me.vertices) * 3, dtype=np.float32); me.vertices.foreach_get("co", co)
co = co.reshape(-1, 3)
co = (mw[:3, :3] @ co.T).T + mw[:3, 3]
nor = np.zeros(nl * 3, dtype=np.float32); me.loops.foreach_get("normal", nor); nor = nor.reshape(-1, 3)
tan = np.zeros(nl * 3, dtype=np.float32); me.loops.foreach_get("tangent", tan); tan = tan.reshape(-1, 3)
sign = np.zeros(nl, dtype=np.float32); me.loops.foreach_get("bitangent_sign", sign)
uv = np.zeros(nl * 2, dtype=np.float32); me.uv_layers.active.data.foreach_get("uv", uv); uv = uv.reshape(-1, 2)
pos = co[vi]

key = np.round(np.hstack([pos, nor, uv]) * 1e5).astype(np.int64)
_, first, inverse = np.unique(key, axis=0, return_index=True, return_inverse=True)
inverse = inverse.reshape(-1)
P, N, T, S, UV = pos[first], nor[first], tan[first], sign[first], uv[first]
tri_loops = np.zeros(len(me.loop_triangles) * 3, dtype=np.int32)
me.loop_triangles.foreach_get("loops", tri_loops)
indices = inverse[tri_loops].astype(np.uint32)
print("VERTS", len(P), "TRIS", len(indices) // 3)

# ---------- 骨骼与权重（Blender 坐标：Z 朝上，脸朝 -Y） ----------
x, y, z = P[:, 0], P[:, 1], P[:, 2]
ax = np.abs(x)
bones = [
    ("root", -1, (0, 0, 0)),
    ("body", 0, (0, 0, 0.06)),
    ("head", 1, (0, 0.0, 0.50)),
    ("earL", 2, (0.19, 0.02, 0.80)),
    ("earR", 2, (-0.19, 0.02, 0.80)),
    ("armL", 1, (0.30, -0.02, 0.36)),
    ("armR", 1, (-0.30, -0.02, 0.36)),
]
w_ear = smooth(0.75, 0.83, z) * smooth(0.09, 0.16, ax)
w_arm = smooth(0.305, 0.355, ax) * smooth(0.21, 0.25, z) * (1 - smooth(0.41, 0.45, z))
w_headraw = smooth(0.485, 0.56, z)
w_foot = 1 - smooth(0.02, 0.10, z)
left = x > 0
W = np.zeros((len(P), len(bones)), dtype=np.float32)
W[:, 3] = w_ear * left
W[:, 4] = w_ear * ~left
W[:, 5] = w_arm * left
W[:, 6] = w_arm * ~left
W[:, 2] = w_headraw * (1 - w_ear)
rest = 1 - W.sum(1)
W[:, 0] = rest * w_foot
W[:, 1] = rest * (1 - w_foot)
order = np.argsort(-W, axis=1)[:, :4]
bw = np.take_along_axis(W, order, axis=1)
bw /= bw.sum(1, keepdims=True)
bi = order.astype(np.uint16)


def sk(v):  # Blender → SceneKit（Y 朝上，脸朝 +Z）
    v = np.asarray(v, dtype=np.float32)
    return np.stack([v[..., 0], v[..., 2], -v[..., 1]], axis=-1)


with open(f"{out}/hamster.mesh", "wb") as f:
    f.write(struct.pack("<II", len(P), len(indices)))
    f.write(sk(P).astype("<f4").tobytes())
    f.write(sk(N).astype("<f4").tobytes())
    f.write(np.hstack([sk(T), S[:, None]]).astype("<f4").tobytes())
    f.write(np.stack([UV[:, 0], 1 - UV[:, 1]], axis=1).astype("<f4").tobytes())
    f.write(bi.astype("<u2").tobytes())
    f.write(bw.astype("<f4").tobytes())
    f.write(indices.astype("<u4").tobytes())
json.dump({"bones": [{"name": n, "parent": p, "pivot": [float(c) for c in sk(piv)]} for n, p, piv in bones]},
          open(f"{out}/hamster.json", "w"), indent=1)

# ---------- 贴图：位置图 → 按三维位置画表情 ----------
img = next(i for i in bpy.data.images if i.name.startswith("tripo_image"))
R = img.size[0]
px = np.array(img.pixels[:], dtype=np.float32).reshape(R, R, 4)
posmap = np.full((R, R, 3), np.nan, dtype=np.float32)
tris = inverse[tri_loops].reshape(-1, 3)
for a, b, c in tris:
    ua, ub, uc = UV[a] * R, UV[b] * R, UV[c] * R
    x0 = max(int(min(ua[0], ub[0], uc[0])) - 1, 0); x1 = min(int(max(ua[0], ub[0], uc[0])) + 2, R)
    y0 = max(int(min(ua[1], ub[1], uc[1])) - 1, 0); y1 = min(int(max(ua[1], ub[1], uc[1])) + 2, R)
    if x1 <= x0 or y1 <= y0:
        continue
    gx, gy = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
    d = (ub[1] - uc[1]) * (ua[0] - uc[0]) + (uc[0] - ub[0]) * (ua[1] - uc[1])
    if abs(d) < 1e-9:
        continue
    l0 = ((ub[1] - uc[1]) * (gx - uc[0]) + (uc[0] - ub[0]) * (gy - uc[1])) / d
    l1 = ((uc[1] - ua[1]) * (gx - uc[0]) + (ua[0] - uc[0]) * (gy - uc[1])) / d
    l2 = 1 - l0 - l1
    e = -0.6 / max(abs(d), 1) ** 0.5
    inside = (l0 >= e) & (l1 >= e) & (l2 >= e)
    if not inside.any():
        continue
    pp = l0[..., None] * P[a] + l1[..., None] * P[b] + l2[..., None] * P[c]
    sub = posmap[y0:y1, x0:x1]
    sub[inside] = pp[inside]
for _ in range(6):  # 给贴图岛外圈补一圈位置，避免接缝处透出原来的颜色
    hole = np.isnan(posmap[..., 0])
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        sh = np.roll(posmap, (dy, dx), axis=(0, 1))
        fill = hole & ~np.isnan(sh[..., 0])
        posmap[fill] = sh[fill]
        hole = np.isnan(posmap[..., 0])
valid = ~np.isnan(posmap[..., 0])
X = np.where(valid, posmap[..., 0], 9); Y = np.where(valid, posmap[..., 1], 9); Z = np.where(valid, posmap[..., 2], 9)
rgb = px[..., :3]
luma = rgb @ np.array([0.3, 0.59, 0.11], dtype=np.float32)

front = valid & (Y < -0.10)
eye_px = front & (luma < 0.32) & (Z > 0.55) & (Z < 0.92) & (np.abs(X) < 0.21)
found = []
for sgn in (1, -1):
    m = eye_px & (X * sgn > 0.02)
    ex, ez = X[m], Z[m]
    for _ in range(4):   # 去掉胡须、睫毛这些离群的深色点
        cx, cz = ex.mean(), ez.mean()
        sd = (ex.std() + ez.std()) / 2
        keep = np.sqrt((ex - cx) ** 2 + (ez - cz) ** 2) < sd * 2.6
        ex, ez = ex[keep], ez[keep]
    found.append((abs(float(cx)), float(cz), float(ex.std() + ez.std())))
    print("EYE", sgn, [round(v, 3) for v in found[-1]], len(ex))
ecx = (found[0][0] + found[1][0]) / 2; ecz = (found[0][1] + found[1][1]) / 2; er = (found[0][2] + found[1][2]) / 2 * 1.12
eyes = [(ecx, ecz, er, er), (-ecx, ecz, er, er)]

ring = valid & (Y < -0.12) & (Z > 0.28) & (Z < 0.54) & (rgb[..., 2] - rgb[..., 0] > 0.12)
print("RING texels", int(ring.sum()))

DARK = np.array([0.20, 0.12, 0.10], dtype=np.float32)
PINK = np.array([1.0, 0.62, 0.66], dtype=np.float32)


def variant(kind):
    o = rgb.copy()
    for cx, cz, rx, rz in eyes:
        r = max(rx, rz)
        dx, dz = (X - cx), (Z - cz)
        dist = np.sqrt(dx * dx + dz * dz)
        near = front & (dist < r * 2.2)
        furm = near & (dist > r * 1.35) & (dist < r * 1.8) & (luma > 0.55)
        fur = rgb[furm].mean(0) if furm.any() else np.array([0.9, 0.88, 0.87], dtype=np.float32)
        thick = r * 0.20
        side = 1 if cx > 0 else -1
        if kind in ("happy", "sleep"):
            cover = near * (1 - smooth(r * 1.12, r * 1.32, dist))
            o[:] = o * (1 - cover[..., None]) + fur * cover[..., None]
            if kind == "happy":   # ^ ^
                cc = np.sqrt(dx * dx + (dz + r * 0.55) ** 2)
                arc = (np.abs(cc - r * 0.95) < thick) & (dz + r * 0.55 > r * 0.45)
            else:                 # 闭眼 ‿
                cc = np.sqrt(dx * dx + (dz - r * 0.75) ** 2)
                arc = (np.abs(cc - r * 0.95) < thick) & (dz - r * 0.75 < -r * 0.45)
            arc &= near
            o[arc] = DARK
        elif kind == "tired":     # 半耷拉的眼皮，外侧往下垂
            lid = cz + r * 0.05 - side * dx * 0.28
            cover = near * (1 - smooth(r * 1.12, r * 1.32, dist)) * smooth(lid - r * 0.05, lid + r * 0.05, Z)
            o[:] = o * (1 - cover[..., None]) + fur * cover[..., None]
            line = near & (np.abs(Z - lid) < thick * 0.7) & (dist < r * 1.05)
            o[line] = DARK
    if kind == "happy":           # 腮红
        for sgn in (1, -1):
            cx, cz, rx, rz = eyes[0 if sgn > 0 else 1]
            r = max(rx, rz)
            d = np.sqrt(((X - cx - sgn * r * 1.3) / (r * 1.5)) ** 2 + ((Z - cz + r * 2.1) / (r * 0.9)) ** 2)
            b = front * (1 - smooth(0.3, 1.0, d)) * 0.55
            o[:] = o * (1 - b[..., None]) + PINK * b[..., None]
    return o


def save(arr, name, size=1024, fmt="JPEG"):
    h = arr.shape[0]
    rgba = np.ones((h, h, 4), dtype=np.float32)
    rgba[..., :arr.shape[2]] = arr
    im = bpy.data.images.new(name, h, h, alpha=False)
    im.pixels.foreach_set(rgba.ravel())
    if size != h:
        im.scale(size, size)
    im.file_format = fmt
    im.filepath_raw = f"{out}/{name}.{'jpg' if fmt == 'JPEG' else 'png'}"
    bpy.context.scene.render.image_settings.quality = 90
    im.save()


bpy.context.scene.view_settings.view_transform = "Standard"
save(rgb, "face_open")
for k in ("happy", "sleep", "tired"):
    save(variant(k), f"face_{k}")
mask = np.zeros((R, R, 3), dtype=np.float32)
mask[ring] = 1
save(mask, "ring_mask", size=1024)
nimg = next(i for i in bpy.data.images if "Normal" in i.name)
npx = np.array(nimg.pixels[:], dtype=np.float32).reshape(nimg.size[1], nimg.size[0], 4)
save(npx[..., :3], "normal")
print("DONE")

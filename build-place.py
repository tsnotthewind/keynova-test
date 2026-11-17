#!/usr/bin/env python3
"""Build the Keynova test place + Keynova project from the Cadence test data.

Reads (all local, already verified on disk):
  ../cadence-test/cadence-test-scene.cadence  - R15 rig parts (size, CFrame, color)
  ../cadence-test/cadence-test-scene.rbmx     - KeyframeSequence poses (the motion)

Writes (into this directory):
  test-place.rbxlx    - Roblox XML place: baseplate + R15 rig (Parts, Humanoid,
                        15 Motor6Ds) + camera + ServerStorage/KeynovaSaves save
  keynova-project.json - Keynova v2 project (format "keynova", version 2),
                        built from the same poses, validated against a Python
                        mirror of Keynova's own Engine.validate().

Grounding notes (read from Keynova.rbxmx source, Keynova 0.3):
  * Project schema: {format:"keynova", version:2, name, fps, duration (frames),
    loop, items, tracks, markers}; Engine.newProject / Engine.validate.
  * Joint tracks use property "Transform" bound to a Motor6D; export converts
    Transform -> C0. Rest C0 goes in track.rest (Engine.encode of the C0).
  * Path segments are {name, class, index} (1-based ordinal among same
    name+class siblings); Runtime.path walks up to `game`.
  * Saves live as a StringValue in ServerStorage/KeynovaSaves (no rig bound)
    or in the rig Model's AnimSaves folder (rig bound).
  * Keyframe limit: <= 20 keys per track (Roblox sequence capacity).
  * CFrame values encode as the 12 numbers from CFrame:GetComponents().

TO-VERIFY ON FIRST RUN (flagged, not hidden):
  * Joint track property is "Transform" (proven from exportData). The
    HumanoidRootPart root-motion track uses property "CFrame" on the Part
    itself, and the camera push-in uses a "FieldOfView" number track --
    both are best-grounded guesses, NOT proven from the source.
  * Whether Keynova's file list shows the ServerStorage/KeynovaSaves save
    and loads it when clicked.
"""
import json
import math
import os
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
CADENCE = os.path.join(HERE, "..", "cadence-test", "cadence-test-scene.cadence")
RBMX = os.path.join(HERE, "..", "cadence-test", "cadence-test-scene.rbmx")
PLACE_OUT = os.path.join(HERE, "test-place.rbxlx")
PROJECT_OUT = os.path.join(HERE, "keynova-project.json")

FPS = 30
DURATION_FRAMES = 150  # 5 seconds at 30 fps

# ---------------------------------------------------------------- CFrame math
# A CFrame is (x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22) --
# exactly CFrame:GetComponents() order. Rotation is row-major orthonormal.

def cf_mul(a, b):
    ax, ay, az = a[0], a[1], a[2]
    ar = [a[3:6], a[6:9], a[9:12]]
    br = [b[3:6], b[6:9], b[9:12]]
    r = [[sum(ar[i][k] * br[k][j] for k in range(3)) for j in range(3)]
         for i in range(3)]
    p = [ax + sum(ar[i][k] * b[k] for k in range(3)) for i in range(3)]
    # p[i] = a_pos[i] + sum_k ar[i][k]*b_pos[k]; b_pos = (b0,b1,b2)
    p = [ax + ar[0][0]*b[0] + ar[0][1]*b[1] + ar[0][2]*b[2],
         ay + ar[1][0]*b[0] + ar[1][1]*b[1] + ar[1][2]*b[2],
         az + ar[2][0]*b[0] + ar[2][1]*b[1] + ar[2][2]*b[2]]
    return tuple(p + [v for row in r for v in row])

def cf_inv(a):
    # transpose rotation, p' = -R^T * p
    r = [[a[3 + i*3 + j] for j in range(3)] for i in range(3)]
    rt = [[r[j][i] for j in range(3)] for i in range(3)]
    p = [a[0], a[1], a[2]]
    ip = [-sum(rt[i][k] * p[k] for k in range(3)) for i in range(3)]
    return tuple(ip + [v for row in rt for v in row])

IDENTITY = (0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)

def cf_look_at(eye, target, up=(0.0, 1.0, 0.0)):
    # Roblox lookAt: -Z faces the target.
    ex, ey, ez = eye
    tx, ty, tz = target
    fx, fy, fz = tx - ex, ty - ey, tz - ez
    fl = math.sqrt(fx*fx + fy*fy + fz*fz)
    fx, fy, fz = fx/fl, fy/fl, fz/fl
    # right = forward x up  (forward is -Z, so right = up x forward... use
    # Roblox convention: X = up cross (-forward)? Keep it simple and standard:
    #   z_axis = -forward, x_axis = normalize(cross(up, z_axis)),
    #   y_axis = cross(z_axis, x_axis)
    zx, zy, zz = -fx, -fy, -fz
    xx = up[1]*zz - up[2]*zy
    xy = up[2]*zx - up[0]*zz
    xz = up[0]*zy - up[1]*zx
    xl = math.sqrt(xx*xx + xy*xy + xz*xz)
    xx, xy, xz = xx/xl, xy/xl, xz/xl
    yx = zy*xz - zz*xy
    yy = zz*xx - zx*xz
    yz = zx*xy - zy*xx
    return (ex, ey, ez, xx, yx, zx, xy, yy, zy, xz, yz, zz)

def fmt(f):
    s = ("%.6f" % f).rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"

# ---------------------------------------------------------------- inputs
cad = json.load(open(CADENCE))
rig = None
for item in cad["items"]:
    if item.get("kind") == "rig":
        rig = item["rig"]
        break
assert rig, "no rig item in .cadence file"
parts = {p["name"]: p for p in rig["parts"]}
print(f"rig parts from .cadence: {len(parts)} -> {sorted(parts)}")

# Parse the .rbmx KeyframeSequence: {time: {poseName: (12 floats,)}}
tree = ET.parse(RBMX)
root = tree.getroot()
keyframes = {}  # time(float) -> {pose name -> cframe tuple}
for kf in root.iter("Item"):
    if kf.get("class") != "Keyframe":
        continue
    t = None
    poses = {}
    for prop in kf.find("Properties"):
        if prop.get("name") == "Time":
            t = float(prop.text)
    for pose in kf.iter("Item"):
        if pose.get("class") != "Pose":
            continue
        name, cf = None, None
        for prop in pose.find("Properties"):
            if prop.get("name") == "Name":
                name = prop.text
            if prop.tag == "CoordinateFrame" and prop.get("name") == "CFrame":
                vals = [float(c.text) for c in prop]
                assert len(vals) == 12, f"Pose {name} CFrame has {len(vals)} comps"
                cf = tuple(vals)
        if name and cf:
            poses[name] = cf
    keyframes[t] = poses
times = sorted(keyframes)
print(f"rbmx keyframe times: {times}")
pose_names = sorted(keyframes[times[0]])
print(f"poses at t=0: {pose_names}")
# Keyframes are sparse: a Keyframe only carries Poses for joints that change
# at that time. Carry each joint's last value forward so every keyframe has
# the full pose set (this is exactly how the engine samples it).
full = {}
last = {}
for t in times:
    last = dict(last)
    last.update(keyframes[t])
    missing = [n for n in pose_names if n not in last]
    assert not missing, f"t={t} missing poses even after carry-forward: {missing}"
    full[t] = dict(last)
keyframes = full

# frames: seconds * 30, rounded; must be unique and <= 150
frames = []
for t in times:
    f = int(round(t * FPS))
    assert f <= DURATION_FRAMES, f"frame {f} > duration"
    assert f not in frames, f"duplicate frame {f}"
    frames.append(f)
print(f"frames: {frames} (count {len(frames)}, limit 20/track)")

# ---------------------------------------------------------------- rig geometry
# Part world CFrames: rig origin translation * part cf (relative to origin).
min_bottom = min(p["cf"][1] - p["size"][1] / 2.0 for p in parts.values())
origin_y = -min_bottom + 0.02  # feet just above the baseplate top (y=0)
ORIGIN = (0.0, origin_y, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
print(f"lowest part bottom (rel. origin): {min_bottom:.4f}; rig origin y={origin_y:.4f}")
world = {name: cf_mul(ORIGIN, tuple(p["cf"])) for name, p in parts.items()}

# Motor6D joints: (joint name, Part0, Part1). Standard R15 joint set.
JOINTS = [
    ("RootJoint", "HumanoidRootPart", "LowerTorso"),
    ("Waist", "LowerTorso", "UpperTorso"),
    ("Neck", "UpperTorso", "Head"),
    ("LeftShoulder", "UpperTorso", "LeftUpperArm"),
    ("LeftElbow", "LeftUpperArm", "LeftLowerArm"),
    ("LeftWrist", "LeftLowerArm", "LeftHand"),
    ("RightShoulder", "UpperTorso", "RightUpperArm"),
    ("RightElbow", "RightUpperArm", "RightLowerArm"),
    ("RightWrist", "RightLowerArm", "RightHand"),
    ("LeftHip", "LowerTorso", "LeftUpperLeg"),
    ("LeftKnee", "LeftUpperLeg", "LeftLowerLeg"),
    ("LeftAnkle", "LeftLowerLeg", "LeftFoot"),
    ("RightHip", "LowerTorso", "RightUpperLeg"),
    ("RightKnee", "RightUpperLeg", "RightLowerLeg"),
    ("RightAnkle", "RightLowerLeg", "RightFoot"),
]
# Pose name -> the Motor6D whose Part1 is that part (Pose.CFrame == that C0).
POSE_TO_JOINT = {
    "LowerTorso": "RootJoint", "UpperTorso": "Waist", "Head": "Neck",
    "LeftUpperArm": "LeftShoulder", "LeftLowerArm": "LeftElbow",
    "RightUpperArm": "RightShoulder", "RightLowerArm": "RightElbow",
    "LeftUpperLeg": "LeftHip", "LeftLowerLeg": "LeftKnee",
    "RightUpperLeg": "RightHip", "RightLowerLeg": "RightKnee",
}
rest_c0 = {}   # joint name -> C0 at rest (from t=0 poses)
for pose_name, joint in POSE_TO_JOINT.items():
    rest_c0[joint] = keyframes[times[0]][pose_name]

# Motor6D C0/C1. Relation that must hold at rest:
#   Part0.CFrame * C0 == Part1.CFrame * C1
# so C1 = Part1^-1 * Part0 * C0. Unanimated joints: C0 = Part0^-1*Part1, C1 = I.
joint_cf = {}
for joint, p0, p1 in JOINTS:
    if joint in rest_c0:
        c0 = rest_c0[joint]
    else:
        c0 = cf_mul(cf_inv(world[p0]), world[p1])
    c1 = cf_mul(cf_mul(cf_inv(world[p1]), world[p0]), c0)
    joint_cf[joint] = (c0, c1)
    # sanity: rest relation holds to numerical precision
    lhs = cf_mul(world[p0], c0)
    rhs = cf_mul(world[p1], c1)
    err = max(abs(a - b) for a, b in zip(lhs, rhs))
    assert err < 1e-4, f"{joint}: rest relation off by {err}"
print(f"joints: {len(JOINTS)} (animated {len(rest_c0)}, static {len(JOINTS)-len(rest_c0)})")

# ---------------------------------------------------------------- Keynova project
# Paths are {name, class, index} segments from `game` down (Runtime.path).
def path_for(*segments):
    # segments: (name, class) pairs under Workspace/TestRig
    p = [{"name": "Workspace", "class": "Workspace", "index": 1},
         {"name": "TestRig", "class": "Model", "index": 1}]
    for name, cls in segments:
        p.append({"name": name, "class": cls, "index": 1})
    return p

def uid(prefix, n):
    return f"{prefix}_{n:03d}"

items, tracks = [], []
item_id = {}
n = 0
def add_item(name, cls, *segs):
    global n
    n += 1
    iid = uid("item", n)
    items.append({"id": iid, "path": path_for(*segs)})
    item_id[name] = iid
    return iid

# Rig model item (the project rig binding).
rig_item = add_item("TestRig", "Model")
# Joint items: one per Motor6D.
for joint, p0, p1 in JOINTS:
    add_item(joint, "Motor6D", (joint, "Motor6D"))
# Root part item.
root_item = add_item("HumanoidRootPart", "Part", ("HumanoidRootPart", "Part"))
# Camera item.
cam_path = [{"name": "Workspace", "class": "Workspace", "index": 1},
            {"name": "Camera", "class": "Camera", "index": 1}]
n += 1
cam_item = uid("item", n)
items.append({"id": cam_item, "path": cam_path})

def key(kid, frame, value, target_path):
    return {"id": uid("key", kid), "frame": frame, "value": [round(v, 6) for v in value],
            "easing": "Linear", "direction": "InOut", "targetPath": target_path}

kid = 0
def add_track(name, iid, prop, vtype, key_values, rest=None):
    """key_values: list of (frame, value) with value a 12-tuple or a number."""
    global kid
    t = {"id": uid("track", len(tracks) + 1), "name": name, "itemId": iid,
         "property": prop, "valueType": vtype, "keys": [],
         "locked": False, "enabled": True}
    # targetPath = the item's own path
    tpath = next(it["path"] for it in items if it["id"] == iid)
    t["targetPath"] = tpath
    if rest is not None:
        t["rest"] = [round(v, 6) for v in rest]
    for frame, value in key_values:
        kid += 1
        if isinstance(value, (int, float)):
            val = value
        else:
            val = [round(v, 6) for v in value]
        t["keys"].append({"id": uid("key", kid), "frame": frame, "value": val,
                          "easing": "Linear", "direction": "InOut",
                          "targetPath": tpath})
    tracks.append(t)
    return t

# 11 animated joint tracks (property "Transform", proven from exportData).
for joint, p0, p1 in JOINTS:
    if joint not in rest_c0:
        continue
    pose_name = p1  # Pose named after Part1 holds this joint's C0
    kvs = [(f, keyframes[t][pose_name]) for f, t in zip(frames, times)]
    add_track(joint, item_id[joint], "Transform", "CFrame", kvs,
              rest=rest_c0[joint])

# Root-motion track (TO-VERIFY: property "CFrame" on the root Part).
# Root Pose CFrames are rig-origin-relative; compose with the rig origin so
# frame 0 lands exactly where the place put the rig.
root_kvs = [(f, cf_mul(ORIGIN, keyframes[t]["HumanoidRootPart"]))
            for f, t in zip(frames, times)]
add_track("HumanoidRootPart", root_item, "CFrame", "CFrame", root_kvs)

# Camera push-in (TO-VERIFY: "FieldOfView" number track on the Camera).
# The Cadence video pushed FOV 70 -> 40 across the 5 s.
add_track("FieldOfView", cam_item, "FieldOfView", "number",
          [(0, 70), (DURATION_FRAMES, 40)])

project = {"format": "keynova", "version": 2, "name": "keynova-test-scene",
           "fps": FPS, "duration": DURATION_FRAMES, "loop": False,
           "items": items, "tracks": tracks, "markers": [],
           "rigItemId": rig_item, "groupKeyframes": False}

# --- Python mirror of Engine.validate (Keynova.rbxmx, lines ~1314-1401) ---
EASING = {"Linear", "Constant", "Sine", "Quad", "Cubic", "Quart", "Quint",
          "Sextic", "Expo", "Circ", "Back", "Bounce", "Elastic"}
DIRS = {"In", "Out", "InOut", "OutIn"}
VTYPES = {"CFrame", "Vector3", "Color3", "Vector2", "UDim", "UDim2", "Rect",
          "NumberRange", "NumberSequence", "ColorSequence", "number",
          "boolean", "string"}

def is_num(x):
    return isinstance(x, (int, float)) and math.isfinite(x)

def valid_path(p):
    if p is None:
        return True
    if not isinstance(p, list):
        return False
    for s in p:
        if not isinstance(s, dict) or not isinstance(s.get("name"), str) \
                or not isinstance(s.get("class"), str) or s.get("class") == "" \
                or not isinstance(s.get("index"), int) or s["index"] < 1:
            return False
    return True

def enc_ok(v, vt):
    if vt == "CFrame":
        return isinstance(v, list) and len(v) == 12 and all(is_num(x) for x in v)
    if vt == "number":
        return is_num(v)
    return False

def validate(proj):
    assert proj["format"] == "keynova" and proj["version"] == 2
    assert isinstance(proj["name"], str)
    assert is_num(proj["fps"]) and proj["fps"] > 0
    assert isinstance(proj["duration"], int) and proj["duration"] >= 0
    assert isinstance(proj["loop"], bool)
    iids, tids, kids = set(), set(), set()
    for it in proj["items"]:
        assert it["id"] not in iids and it["id"], "dup item id"
        iids.add(it["id"])
        assert valid_path(it.get("path")), f"bad item path {it['id']}"
    for tr in proj["tracks"]:
        assert tr["id"] not in tids and tr["id"], "dup track id"
        tids.add(tr["id"])
        assert tr["itemId"] in iids, f"track {tr['id']} bad itemId"
        assert isinstance(tr["name"], str) and tr["property"] and tr["valueType"] in VTYPES
        assert valid_path(tr.get("targetPath")), f"bad track path {tr['id']}"
        assert len(tr["keys"]) <= 20, f"track {tr['id']} has >20 keys"
        seen = set()
        for k in tr["keys"]:
            assert k["id"] not in kids and k["id"], "dup key id"
            kids.add(k["id"])
            assert isinstance(k["frame"], int) and 0 <= k["frame"] <= proj["duration"]
            assert k["frame"] not in seen, "dup frame in track"
            seen.add(k["frame"])
            assert enc_ok(k["value"], tr["valueType"]), f"bad key value {k['id']}"
            assert k.get("easing", "Linear") in EASING
            assert k.get("direction", "InOut") in DIRS
            assert valid_path(k.get("targetPath")), f"bad key path {k['id']}"
    assert proj["rigItemId"] in iids, "rigItemId missing"
    return True

validate(project)
print(f"project valid: {len(items)} items, {len(tracks)} tracks, "
      f"{sum(len(t['keys']) for t in tracks)} keys")
project_json = json.dumps(project, separators=(",", ":"))
print(f"project JSON bytes: {len(project_json)}")
json.dump(project, open(PROJECT_OUT, "w"), indent=1)

# ---------------------------------------------------------------- place .rbxlx
def cf_xml(cf):
    tags = ["X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12",
            "R20", "R21", "R22"]
    inner = "".join(f"<{t}>{fmt(v)}</{t}>" for t, v in zip(tags, cf))
    return f"<CoordinateFrame name=\"CFrame\">{inner}</CoordinateFrame>"

def v3_xml(name, v):
    return (f"<Vector3 name=\"{name}\"><X>{fmt(v[0])}</X><Y>{fmt(v[1])}</Y>"
            f"<Z>{fmt(v[2])}</Z></Vector3>")

def esc(s):
    return escape(str(s), {'"': "&quot;"})

lines = []
lines.append('<roblox version="4">')
lines.append('<Meta name="ExplicitAutoJoints">true</Meta>')
refn = [0]
def ref():
    refn[0] += 1
    return f"RBX{refn[0]}"

# Workspace + Camera + baseplate + rig
ws = ref()
cam_ref = ref()
base_ref = ref()
rig_ref = ref()
lines.append(f'<Item class="Workspace" referent="{ws}"><Properties>'
             f'<string name="Name">Workspace</string>'
             f'<Ref name="CurrentCamera">{cam_ref}</Ref></Properties>')
# Camera: at (7, 5, 11) looking at the rig (0, 2.2, 0), FOV 70.
cam_cf = cf_look_at((7.0, 5.0, 11.0), (0.0, 2.2, 0.0))
lines.append(f'<Item class="Camera" referent="{cam_ref}"><Properties>'
             f'<string name="Name">Camera</string>{cf_xml(cam_cf)}'
             f'<float name="FieldOfView">70</float></Properties></Item>')
# Baseplate 64x1x64, top at y=0.
lines.append(f'<Item class="Part" referent="{base_ref}"><Properties>'
             f'<string name="Name">Baseplate</string>'
             f'{cf_xml((0.0, -0.5, 0.0, 1, 0, 0, 0, 1, 0, 0, 0, 1))}'
             f'{v3_xml("size", (64, 1, 64))}'
             f'<bool name="Anchored">true</bool>'
             f'<bool name="CanCollide">true</bool></Properties></Item>')
# Rig Model
hrp_ref = ref()
lines.append(f'<Item class="Model" referent="{rig_ref}"><Properties>'
             f'<string name="Name">TestRig</string>'
             f'<Ref name="PrimaryPart">{hrp_ref}</Ref></Properties>')
lines.append(f'<Item class="Humanoid" referent="{ref()}"><Properties>'
             f'<string name="Name">Humanoid</string></Properties></Item>')
part_ref = {}
for name in sorted(parts):
    p = parts[name]
    r = hrp_ref if name == "HumanoidRootPart" else ref()
    part_ref[name] = r
    transp = p.get("transparency", 0)
    lines.append(f'<Item class="Part" referent="{r}"><Properties>'
                 f'<string name="Name">{esc(name)}</string>'
                 f'{cf_xml(world[name])}'
                 f'{v3_xml("size", p["size"])}'
                 f'<bool name="Anchored">true</bool>'
                 f'<bool name="CanCollide">false</bool>'
                 f'<float name="Transparency">{fmt(transp)}</float>'
                 f'</Properties></Item>')
for joint, p0, p1 in JOINTS:
    c0, c1 = joint_cf[joint]
    c0_xml = cf_xml(c0).replace('name="CFrame"', 'name="C0"', 1)
    c1_xml = cf_xml(c1).replace('name="CFrame"', 'name="C1"', 1)
    lines.append(f'<Item class="Motor6D" referent="{ref()}"><Properties>'
                 f'<string name="Name">{joint}</string>'
                 f'<Ref name="Part0">{part_ref[p0]}</Ref>'
                 f'<Ref name="Part1">{part_ref[p1]}</Ref>'
                 f'{c0_xml}'
                 f'{c1_xml}'
                 f'</Properties></Item>')
lines.append('</Item>')  # Model
lines.append('</Item>')  # Workspace
# ServerStorage / KeynovaSaves / StringValue with the project JSON.
ss = ref()
ks = ref()
lines.append(f'<Item class="ServerStorage" referent="{ss}"><Properties>'
             f'<string name="Name">ServerStorage</string></Properties>')
lines.append(f'<Item class="Folder" referent="{ks}"><Properties>'
             f'<string name="Name">KeynovaSaves</string></Properties>')
lines.append(f'<Item class="StringValue" referent="{ref()}"><Properties>'
             f'<string name="Name">keynova-test-scene</string>'
             f'<string name="Value">{esc(project_json)}</string>'
             f'</Properties></Item>')
lines.append('</Item></Item>')  # Folder, ServerStorage
lines.append('</roblox>')
open(PLACE_OUT, "w").write("\n".join(lines) + "\n")

# Verify the place parses as XML and re-check key counts.
ET.parse(PLACE_OUT)
print(f"wrote {PLACE_OUT} ({os.path.getsize(PLACE_OUT)} bytes)")
print(f"wrote {PROJECT_OUT} ({os.path.getsize(PROJECT_OUT)} bytes)")
print("OK - place parses as XML, project passes Engine.validate mirror")

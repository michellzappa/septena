#!/usr/bin/env python3
"""
Septena 3D Marketing Studio Renderer (Blender 5.x Cycles / Metal GPU)

Usage:
  blender -b --python render.py -- \
    --mac screens/demo_mac.png \
    --ios screens/demo_ios.png \
    --watch screens/demo_watch.png \
    --phone pro \
    --preset hero-vertical \
    --samples 64 \
    --out renders/hero_vertical.png
"""
import argparse
import math
import os
import sys
import bpy
import bmesh
import mathutils

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(SCRIPT_DIR, "models")
SCREENS_DIR = os.path.join(SCRIPT_DIR, "screens")
RENDERS_DIR = os.path.join(SCRIPT_DIR, "renders")


def parse_args():
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1:]
    else:
        argv = []
    p = argparse.ArgumentParser(description="Render Septena 3D marketing scene")
    p.add_argument("--mac", default=os.path.join(SCREENS_DIR, "demo_mac.png"))
    p.add_argument("--ipad", default=os.path.join(SCREENS_DIR, "demo_ipad.png"))
    p.add_argument("--no-ipad", action="store_true", help="Omit the iPad Mini from the scene")
    p.add_argument("--ios", default=os.path.join(SCREENS_DIR, "demo_ios.png"))
    p.add_argument("--watch", default=os.path.join(SCREENS_DIR, "demo_watch.png"))
    p.add_argument("--phone", choices=["pro", "air"], default="pro")
    p.add_argument("--mac-finish", choices=["silver", "space-black"], default="silver")
    p.add_argument("--preset", choices=["hero-vertical", "ortho-vertical", "iso-vertical", "hero-wide", "square", "closeup-phone"], default="hero-vertical")
    p.add_argument("--keep-notch", action="store_true", help="Keep the MacBook camera notch (removed by default)")
    p.add_argument("--samples", type=int, default=64)
    p.add_argument("--scale", type=float, default=1.0)
    p.add_argument("--out", default=None)
    p.add_argument("--save-blend", default=None)
    return p.parse_args(argv)


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_cycles(scene, samples):
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'GPU'
    scene.cycles.samples = samples
    scene.cycles.use_adaptive_sampling = True
    scene.cycles.adaptive_threshold = 0.015
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 8
    scene.cycles.diffuse_bounces = 4
    scene.cycles.glossy_bounces = 4
    scene.cycles.transmission_bounces = 4
    scene.cycles.transparent_max_bounces = 4

    try:
        prefs = bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type = 'METAL'
        prefs.get_devices()
        for dev in prefs.devices:
            dev.use = True
    except Exception as e:
        print("Metal GPU init note:", e)

    # Color management: AgX Base Contrast keeps metallics rich while preserving UI fidelity
    scene.view_settings.view_transform = 'AgX'
    try:
        scene.view_settings.look = 'AgX - Punchy'
    except Exception:
        try:
            scene.view_settings.look = 'AgX - Medium High Contrast'
        except Exception:
            pass
    scene.view_settings.exposure = 0.0
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'


def append_all_objects(blend_path, collection_name):
    col = bpy.data.collections.new(collection_name)
    bpy.context.scene.collection.children.link(col)

    with bpy.data.libraries.load(blend_path, link=False) as (data_from, data_to):
        data_to.objects = list(data_from.objects)

    objs = []
    for obj in data_to.objects:
        if obj is not None:
            col.objects.link(obj)
            objs.append(obj)
    return col, objs


def create_root_empty(name, objs, col):
    root = bpy.data.objects.new(name, None)
    col.objects.link(root)
    for o in objs:
        if o.parent is None:
            o.parent = root
    return root


def get_world_bbox(objs):
    bpy.context.view_layer.update()
    mins = mathutils.Vector((1e9, 1e9, 1e9))
    maxs = mathutils.Vector((-1e9, -1e9, -1e9))
    for o in objs:
        if o.type != 'MESH':
            continue
        mw = o.matrix_world
        for vert in o.data.vertices:
            v = mw @ vert.co
            if v.x < mins.x: mins.x = v.x
            if v.y < mins.y: mins.y = v.y
            if v.z < mins.z: mins.z = v.z
            if v.x > maxs.x: maxs.x = v.x
            if v.y > maxs.y: maxs.y = v.y
            if v.z > maxs.z: maxs.z = v.z
    return mins, maxs


def drop_to_floor(root, objs, z_floor=0.0):
    mins, _ = get_world_bbox(objs)
    root.location.z += (z_floor - mins.z)
    bpy.context.view_layer.update()


def reproject_planar_uv(obj, mat_name, u_axis, v_axis, flip_u=False, flip_v=False, inset=0.0):
    """Re-normalize UVs of faces using `mat_name` cleanly to [0, 1] x [0, 1]."""
    mat_idx = next((i for i, m in enumerate(obj.data.materials) if m and m.name == mat_name), None)
    if mat_idx is None:
        print(f"WARN: material {mat_name} not found on {obj.name}")
        return
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    uv_layer = bm.loops.layers.uv.active or bm.loops.layers.uv.new("UVMap")
    faces = [f for f in bm.faces if f.material_index == mat_idx]
    if not faces:
        bm.free()
        return

    axis_map = {'x': 0, 'y': 1, 'z': 2}
    ui = axis_map[u_axis]
    vi = axis_map[v_axis]

    umin = vmin = 1e9
    umax = vmax = -1e9
    for f in faces:
        for l in f.loops:
            p = l.vert.co
            umin = min(umin, p[ui])
            umax = max(umax, p[ui])
            vmin = min(vmin, p[vi])
            vmax = max(vmax, p[vi])

    ur = max(umax - umin, 1e-6)
    vr = max(vmax - vmin, 1e-6)

    for f in faces:
        for l in f.loops:
            p = l.vert.co
            u = (p[ui] - umin) / ur
            v = (p[vi] - vmin) / vr
            if flip_u:
                u = 1.0 - u
            if flip_v:
                v = 1.0 - v
            if inset != 0.0:
                u = (u - 0.5) * (1.0 + inset * 2.0) + 0.5
                v = (v - 0.5) * (1.0 + inset * 2.0) + 0.5
            l[uv_layer].uv = (u, v)

    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


def make_emissive_screen_material(mat, image_path, cam_strength=1.22, bounce_strength=5.5, glass_gloss=0.018, corner_radius=0.0, aspect=1.0):
    """
    Sets up a realistic glass-covered OLED/Retina screen:
    - Camera rays see crisp, high-contrast, un-washed-out UI colors (`cam_strength` ~1.5 with mild
      gamma/saturation compensation against AgX highlight lift) + subtle glass specular sheen.
    - Indirect diffuse/glossy rays see boosted emission (`bounce_strength`) so the screen casts rich
      real reflections onto the dark matte desk without blowing out UI text!
    - Optional `corner_radius` (> 0, in V-axis UV units) applies an analytic rounded-rectangle bezel
      mask to all four corners (e.g. symmetric top + bottom rounded OLED MacBook Pro corners).
    """
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new('ShaderNodeOutputMaterial')
    out.location = (960, 0)

    tex_coord = nt.nodes.new('ShaderNodeTexCoord')
    tex_coord.location = (-720, 0)

    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.location = (-480, 0)
    img = bpy.data.images.load(os.path.abspath(image_path), check_existing=True)
    img.colorspace_settings.name = 'sRGB'
    tex.image = img
    tex.extension = 'EXTEND'

    # Camera-ray contrast compensation so AgX doesn't wash out light UI cards, borders, or text
    gamma = nt.nodes.new('ShaderNodeGamma')
    gamma.location = (-200, 120)
    gamma.inputs['Gamma'].default_value = 1.28

    hsv = nt.nodes.new('ShaderNodeHueSaturation')
    hsv.location = (-20, 120)
    hsv.inputs['Saturation'].default_value = 1.16
    hsv.inputs['Value'].default_value = 1.0

    light_path = nt.nodes.new('ShaderNodeLightPath')
    light_path.location = (-20, 320)

    # Separate emission shaders: camera rays vs indirect desk bounce
    emit_cam = nt.nodes.new('ShaderNodeEmission')
    emit_cam.location = (220, 120)
    emit_cam.inputs['Strength'].default_value = cam_strength

    emit_bounce = nt.nodes.new('ShaderNodeEmission')
    emit_bounce.location = (220, -40)
    emit_bounce.inputs['Strength'].default_value = bounce_strength

    mix_emit = nt.nodes.new('ShaderNodeMixShader')
    mix_emit.location = (420, 80)

    # Subtle glossy glass reflection over the display
    glossy = nt.nodes.new('ShaderNodeBsdfGlossy')
    glossy.location = (220, -220)
    glossy.inputs['Color'].default_value = (1.0, 1.0, 1.0, 1.0)
    glossy.inputs['Roughness'].default_value = 0.04

    fresnel = nt.nodes.new('ShaderNodeFresnel')
    fresnel.location = (220, -380)
    fresnel.inputs['IOR'].default_value = 1.48

    mul_fres = nt.nodes.new('ShaderNodeMath')
    mul_fres.operation = 'MULTIPLY'
    mul_fres.location = (400, -300)
    mul_fres.inputs[1].default_value = glass_gloss

    add_shader = nt.nodes.new('ShaderNodeMixShader')
    add_shader.location = (580, 0)

    nt.links.new(tex_coord.outputs['UV'], tex.inputs['Vector'])
    nt.links.new(tex.outputs['Color'], gamma.inputs['Color'])
    nt.links.new(gamma.outputs['Color'], hsv.inputs['Color'])
    nt.links.new(hsv.outputs['Color'], emit_cam.inputs['Color'])
    nt.links.new(tex.outputs['Color'], emit_bounce.inputs['Color'])

    nt.links.new(light_path.outputs['Is Camera Ray'], mix_emit.inputs['Fac'])
    nt.links.new(emit_bounce.outputs['Emission'], mix_emit.inputs[1])
    nt.links.new(emit_cam.outputs['Emission'], mix_emit.inputs[2])

    nt.links.new(fresnel.outputs['Fac'], mul_fres.inputs[0])
    nt.links.new(mul_fres.outputs['Value'], add_shader.inputs['Fac'])
    nt.links.new(mix_emit.outputs['Shader'], add_shader.inputs[1])
    nt.links.new(glossy.outputs['BSDF'], add_shader.inputs[2])

    if corner_radius > 0.0:
        # Analytic rounded-rectangle SDF in UV space: masks all 4 corners smoothly into glossy black bezel
        sep = nt.nodes.new('ShaderNodeSeparateXYZ')
        sub_u = nt.nodes.new('ShaderNodeMath'); sub_u.operation = 'SUBTRACT'; sub_u.inputs[1].default_value = 0.5
        abs_u = nt.nodes.new('ShaderNodeMath'); abs_u.operation = 'ABSOLUTE'
        mul_a = nt.nodes.new('ShaderNodeMath'); mul_a.operation = 'MULTIPLY'; mul_a.inputs[1].default_value = aspect
        sub_bu = nt.nodes.new('ShaderNodeMath'); sub_bu.operation = 'SUBTRACT'; sub_bu.inputs[1].default_value = 0.5 * aspect - corner_radius
        max_u = nt.nodes.new('ShaderNodeMath'); max_u.operation = 'MAXIMUM'; max_u.inputs[1].default_value = 0.0

        sub_v = nt.nodes.new('ShaderNodeMath'); sub_v.operation = 'SUBTRACT'; sub_v.inputs[1].default_value = 0.5
        abs_v = nt.nodes.new('ShaderNodeMath'); abs_v.operation = 'ABSOLUTE'
        sub_bv = nt.nodes.new('ShaderNodeMath'); sub_bv.operation = 'SUBTRACT'; sub_bv.inputs[1].default_value = 0.5 - corner_radius
        max_v = nt.nodes.new('ShaderNodeMath'); max_v.operation = 'MAXIMUM'; max_v.inputs[1].default_value = 0.0

        comb = nt.nodes.new('ShaderNodeCombineXYZ')
        vlen = nt.nodes.new('ShaderNodeVectorMath'); vlen.operation = 'LENGTH'
        gt = nt.nodes.new('ShaderNodeMath'); gt.operation = 'GREATER_THAN'; gt.inputs[1].default_value = corner_radius

        bezel_bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
        bezel_bsdf.inputs['Base Color'].default_value = (0.006, 0.006, 0.007, 1.0)
        bezel_bsdf.inputs['Roughness'].default_value = 0.06
        if 'Coat Weight' in bezel_bsdf.inputs:
            bezel_bsdf.inputs['Coat Weight'].default_value = 0.6

        mix_corner = nt.nodes.new('ShaderNodeMixShader')
        mix_corner.location = (780, 0)

        nt.links.new(tex_coord.outputs['UV'], sep.inputs['Vector'])
        nt.links.new(sep.outputs['X'], sub_u.inputs[0])
        nt.links.new(sub_u.outputs['Value'], abs_u.inputs[0])
        nt.links.new(abs_u.outputs['Value'], mul_a.inputs[0])
        nt.links.new(mul_a.outputs['Value'], sub_bu.inputs[0])
        nt.links.new(sub_bu.outputs['Value'], max_u.inputs[0])

        nt.links.new(sep.outputs['Y'], sub_v.inputs[0])
        nt.links.new(sub_v.outputs['Value'], abs_v.inputs[0])
        nt.links.new(abs_v.outputs['Value'], sub_bv.inputs[0])
        nt.links.new(sub_bv.outputs['Value'], max_v.inputs[0])

        nt.links.new(max_u.outputs['Value'], comb.inputs['X'])
        nt.links.new(max_v.outputs['Value'], comb.inputs['Y'])
        nt.links.new(comb.outputs['Vector'], vlen.inputs[0])
        nt.links.new(vlen.outputs['Value'], gt.inputs[0])

        nt.links.new(gt.outputs['Value'], mix_corner.inputs['Fac'])
        nt.links.new(add_shader.outputs['Shader'], mix_corner.inputs[1])
        nt.links.new(bezel_bsdf.outputs['BSDF'], mix_corner.inputs[2])
        nt.links.new(mix_corner.outputs['Shader'], out.inputs['Surface'])
    else:
        nt.links.new(add_shader.outputs['Shader'], out.inputs['Surface'])


def set_simple_pbr(mat, base_color, metallic=0.0, roughness=0.3, coat=0.0, bump_scale=0.0, bump_strength=0.0):
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    out.location = (400, 0)
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.location = (100, 0)
    bsdf.inputs['Base Color'].default_value = (*base_color, 1.0)
    bsdf.inputs['Metallic'].default_value = metallic
    bsdf.inputs['Roughness'].default_value = roughness
    if 'Coat Weight' in bsdf.inputs:
        bsdf.inputs['Coat Weight'].default_value = coat
    if bump_strength > 0.0:
        tc = nt.nodes.new('ShaderNodeTexCoord')
        noise = nt.nodes.new('ShaderNodeTexNoise')
        noise.inputs['Scale'].default_value = bump_scale
        noise.inputs['Detail'].default_value = 8.0
        bump = nt.nodes.new('ShaderNodeBump')
        bump.inputs['Strength'].default_value = bump_strength
        nt.links.new(tc.outputs['Object'], noise.inputs['Vector'])
        nt.links.new(noise.outputs['Fac'], bump.inputs['Height'])
        nt.links.new(bump.outputs['Normal'], bsdf.inputs['Normal'])
    nt.links.new(bsdf.outputs['BSDF'], out.inputs['Surface'])


def build_desk(scene):
    bpy.ops.mesh.primitive_plane_add(size=20.0, location=(0.0, 0.0, 0.0))
    desk = bpy.context.active_object
    desk.name = "StudioDesk"

    mat = bpy.data.materials.new("MatteSlateDesk")
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new('ShaderNodeOutputMaterial')
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.inputs['Metallic'].default_value = 0.0
    if 'Specular IOR Level' in bsdf.inputs:
        bsdf.inputs['Specular IOR Level'].default_value = 0.55

    tc = nt.nodes.new('ShaderNodeTexCoord')

    # Macro slate variation (subtle dark matte stone/leather desk grain)
    noise_macro = nt.nodes.new('ShaderNodeTexNoise')
    noise_macro.inputs['Scale'].default_value = 14.0
    noise_macro.inputs['Detail'].default_value = 8.0
    noise_macro.inputs['Roughness'].default_value = 0.65

    # Micro matte grain
    noise_micro = nt.nodes.new('ShaderNodeTexNoise')
    noise_micro.inputs['Scale'].default_value = 420.0
    noise_micro.inputs['Detail'].default_value = 10.0
    noise_micro.inputs['Roughness'].default_value = 0.72

    # Color ramp for deep charcoal-black matte slate
    col_ramp = nt.nodes.new('ShaderNodeValToRGB')
    col_ramp.color_ramp.elements[0].position = 0.25
    col_ramp.color_ramp.elements[0].color = (0.008, 0.008, 0.009, 1.0)
    col_ramp.color_ramp.elements[1].position = 0.80
    col_ramp.color_ramp.elements[1].color = (0.019, 0.019, 0.021, 1.0)

    # Roughness variation: localized soft specular sheen without turning into a mirror
    rough_ramp = nt.nodes.new('ShaderNodeValToRGB')
    rough_ramp.color_ramp.elements[0].position = 0.2
    rough_ramp.color_ramp.elements[0].color = (0.26, 0.26, 0.26, 1.0)
    rough_ramp.color_ramp.elements[1].position = 0.85
    rough_ramp.color_ramp.elements[1].color = (0.46, 0.46, 0.46, 1.0)

    bump_macro = nt.nodes.new('ShaderNodeBump')
    bump_macro.inputs['Strength'].default_value = 0.035
    bump_macro.inputs['Distance'].default_value = 0.002

    bump_micro = nt.nodes.new('ShaderNodeBump')
    bump_micro.inputs['Strength'].default_value = 0.075
    bump_micro.inputs['Distance'].default_value = 0.0005

    nt.links.new(tc.outputs['Object'], noise_macro.inputs['Vector'])
    nt.links.new(tc.outputs['Object'], noise_micro.inputs['Vector'])
    nt.links.new(noise_macro.outputs['Fac'], col_ramp.inputs['Fac'])
    nt.links.new(col_ramp.outputs['Color'], bsdf.inputs['Base Color'])
    nt.links.new(noise_macro.outputs['Fac'], rough_ramp.inputs['Fac'])
    nt.links.new(rough_ramp.outputs['Color'], bsdf.inputs['Roughness'])

    nt.links.new(noise_macro.outputs['Fac'], bump_macro.inputs['Height'])
    nt.links.new(noise_micro.outputs['Fac'], bump_micro.inputs['Height'])
    nt.links.new(bump_macro.outputs['Normal'], bump_micro.inputs['Normal'])
    nt.links.new(bump_micro.outputs['Normal'], bsdf.inputs['Normal'])
    nt.links.new(bsdf.outputs['BSDF'], out.inputs['Surface'])

    desk.data.materials.append(mat)
    return desk


def build_topo_backdrop(scene, preset="hero-vertical"):
    """Dark matte studio wall with subtle procedural topographic contour lines."""
    if preset == "iso-vertical":
        # Angled perpendicular to the 3/4 isometric camera so topo contours fill the upper dark backdrop
        bpy.ops.mesh.primitive_plane_add(size=6.0, location=(0.24, 0.56, 0.72), rotation=(math.radians(90), 0, math.radians(-21)))
    else:
        bpy.ops.mesh.primitive_plane_add(size=4.0, location=(0.0, 0.45, 0.75), rotation=(math.radians(90), 0, 0))
    wall = bpy.context.active_object
    wall.name = "TopoBackdrop"

    mat = bpy.data.materials.new("TopoWall")
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new('ShaderNodeOutputMaterial')
    bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.inputs['Roughness'].default_value = 0.92
    if 'Specular IOR Level' in bsdf.inputs:
        bsdf.inputs['Specular IOR Level'].default_value = 0.08

    tc = nt.nodes.new('ShaderNodeTexCoord')

    # Smooth low-frequency elevation noise -> contour rings
    noise = nt.nodes.new('ShaderNodeTexNoise')
    noise.inputs['Scale'].default_value = 2.6
    noise.inputs['Detail'].default_value = 3.0
    noise.inputs['Roughness'].default_value = 0.45
    noise.inputs['Distortion'].default_value = 0.25

    mul = nt.nodes.new('ShaderNodeMath')
    mul.operation = 'MULTIPLY'
    mul.inputs[1].default_value = 26.0

    # Periodic wave: abs(fract(x) - 0.5) -> thin crisp contour lines
    fract = nt.nodes.new('ShaderNodeMath')
    fract.operation = 'FRACT'

    sub = nt.nodes.new('ShaderNodeMath')
    sub.operation = 'SUBTRACT'
    sub.inputs[1].default_value = 0.5

    absv = nt.nodes.new('ShaderNodeMath')
    absv.operation = 'ABSOLUTE'

    # Thin contour line mask (whisper-subtle crisp topographic contours)
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (1.0, 1.0, 1.0, 1.0)
    ramp.color_ramp.elements[1].position = 0.026
    ramp.color_ramp.elements[1].color = (0.0, 0.0, 0.0, 1.0)

    mix_col = nt.nodes.new('ShaderNodeMix')
    mix_col.data_type = 'RGBA'
    mix_col.inputs['A'].default_value = (0.011, 0.011, 0.012, 1.0)  # deep charcoal base
    mix_col.inputs['B'].default_value = (0.030, 0.030, 0.033, 1.0)  # subtle topo contour line

    nt.links.new(tc.outputs['Object'], noise.inputs['Vector'])
    nt.links.new(noise.outputs['Fac'], mul.inputs[0])
    nt.links.new(mul.outputs['Value'], fract.inputs[0])
    nt.links.new(fract.outputs['Value'], sub.inputs[0])
    nt.links.new(sub.outputs['Value'], absv.inputs[0])
    nt.links.new(absv.outputs['Value'], ramp.inputs['Fac'])
    nt.links.new(ramp.outputs['Color'], mix_col.inputs['Factor'])
    nt.links.new(mix_col.outputs['Result'], bsdf.inputs['Base Color'])
    nt.links.new(bsdf.outputs['BSDF'], out.inputs['Surface'])

    wall.data.materials.append(mat)
    return wall


def remove_macbook_notch(disp_obj, disp_mat_name):
    """Reassign inner bezel faces protruding into the display rectangle to the display material."""
    disp_idx = next((i for i, m in enumerate(disp_obj.data.materials) if m and m.name == disp_mat_name), None)
    bezel_idx = next((i for i, m in enumerate(disp_obj.data.materials) if m and m.name.startswith("Bezel")), None)
    if disp_idx is None or bezel_idx is None:
        return
    bm = bmesh.new()
    bm.from_mesh(disp_obj.data)
    disp_faces = [f for f in bm.faces if f.material_index == disp_idx]
    if not disp_faces:
        bm.free()
        return
    xs = [v.co.x for f in disp_faces for v in f.verts]
    zs = [v.co.z for f in disp_faces for v in f.verts]
    xmin, xmax, zmin, zmax = min(xs), max(xs), min(zs), max(zs)
    moved = 0
    for f in bm.faces:
        if f.material_index == bezel_idx:
            c = f.calc_center_median()
            if xmin < c.x < xmax and zmin < c.z < zmax:
                f.material_index = disp_idx
                moved += 1
    bm.to_mesh(disp_obj.data)
    bm.free()
    disp_obj.data.update()
    print(f"Removed MacBook notch ({moved} bezel faces converted to display)")


def build_macbook(mac_screen_path, keep_notch=False, finish="silver"):
    col, objs = append_all_objects(os.path.join(MODELS_DIR, "macbook_pro_14_2024.blend"), "MacBookPro")
    root = create_root_empty("MacBookRoot", objs, col)

    # Open lid back slightly (~8 deg past 90) so screen looks natural and doesn't glare overhead
    hinge = next((o for o in objs if o.name.startswith("Rotate Screen")), None)
    if hinge:
        # Rotate Screen has rot_z = 90 deg, so tilting screen back is around local Y
        hinge.rotation_euler.y += math.radians(7.0)

    # Tune materials for authentic bead-blasted Apple anodized aluminum (satin-matte, not mirror-shiny)
    alu_col = (0.46, 0.46, 0.48) if finish == "silver" else (0.085, 0.086, 0.092)
    alu_rough = 0.42 if finish == "silver" else 0.44
    for mat in bpy.data.materials:
        if mat.name.startswith("GreyMetalic"):
            set_simple_pbr(mat, alu_col, metallic=0.88, roughness=alu_rough, bump_scale=1800.0, bump_strength=0.015)
        elif mat.name.startswith("Bezel"):
            set_simple_pbr(mat, (0.008, 0.008, 0.009), metallic=0.0, roughness=0.06, coat=0.6)
        elif mat.name.startswith("BlackMetalic") or mat.name.startswith("Black Plastic"):
            set_simple_pbr(mat, (0.018, 0.018, 0.020), metallic=0.1, roughness=0.45)
        elif mat.name.startswith("Keyboard"):
            # Keep original keyboard legend texture if present, dark matte keys with subtle legends
            if mat.node_tree:
                for n in mat.node_tree.nodes:
                    if n.type == 'BSDF_PRINCIPLED':
                        if 'Emission Strength' in n.inputs:
                            n.inputs['Emission Strength'].default_value = 0.0
                        n.inputs['Roughness'].default_value = 0.55
                        n.inputs['Base Color'].default_value = (0.015, 0.015, 0.017, 1.0)

    # Reproject Display.002 screen UVs edge-to-edge and apply crisp emissive screenshot
    disp = next((o for o in objs if o.name.startswith("Display")), None)
    if disp:
        disp_mat = next((m for m in disp.data.materials if m and m.name.startswith("Display")), None)
        if disp_mat:
            if not keep_notch:
                remove_macbook_notch(disp, disp_mat.name)
            reproject_planar_uv(disp, disp_mat.name, u_axis='x', v_axis='z', flip_u=False, flip_v=False)
            make_emissive_screen_material(
                disp_mat, mac_screen_path,
                cam_strength=1.52, bounce_strength=8.5, glass_gloss=0.015,
                corner_radius=0.036, aspect=1.522,
            )

    root.location = (0.0, 0.03, 0.0)
    drop_to_floor(root, objs, 0.0)
    return root, objs


def thin_ipad_bezels(ipad_obj, screen_mat_name, target_bezel_m=0.0042):
    """Expand the iPad screen polygon outward to thin the chunky 10mm bezels down to sleek ~4.2mm bezels."""
    scr_idx = next((i for i, m in enumerate(ipad_obj.data.materials) if m and m.name == screen_mat_name), None)
    bez_idx = next((i for i, m in enumerate(ipad_obj.data.materials) if m and m.name.startswith("Pre-Screen")), None)
    if scr_idx is None or bez_idx is None:
        return
    bm = bmesh.new()
    bm.from_mesh(ipad_obj.data)
    scr_faces = [f for f in bm.faces if f.material_index == scr_idx]
    bez_faces = [f for f in bm.faces if f.material_index == bez_idx]
    if not scr_faces or not bez_faces:
        bm.free()
        return

    s_verts = {v for f in scr_faces for v in f.verts}
    sx = [v.co.x for v in s_verts]
    sy = [v.co.y for v in s_verts]
    cx = 0.5 * (min(sx) + max(sx))
    cy = 0.5 * (min(sy) + max(sy))
    hx = 0.5 * (max(sx) - min(sx))
    hy = 0.5 * (max(sy) - min(sy))

    front_bez = [v for f in bez_faces for v in f.verts if v.co.z > 0.002]
    bx = [v.co.x for v in front_bez]
    by = [v.co.y for v in front_bez]
    bhx = 0.5 * (max(bx) - min(bx))
    bhy = 0.5 * (max(by) - min(by))

    new_hx = max(hx, bhx - target_bezel_m)
    new_hy = max(hy, bhy - target_bezel_m)
    scale_x = new_hx / hx
    scale_y = new_hy / hy

    for v in s_verts:
        v.co.x = cx + (v.co.x - cx) * scale_x
        v.co.y = cy + (v.co.y - cy) * scale_y

    bm.to_mesh(ipad_obj.data)
    bm.free()
    ipad_obj.data.update()
    print(f"Thinned iPad bezels -> ~{target_bezel_m*1000:.1f}mm (scale_x={scale_x:.3f}, scale_y={scale_y:.3f})")


def build_ipad(ipad_screen_path, preset="iso-vertical", finish="silver"):
    col, objs = append_all_objects(os.path.join(MODELS_DIR, "ipad_mini_space_grey.blend"), "iPadMini")
    root = create_root_empty("iPadRoot", objs, col)

    body_col = (0.28, 0.28, 0.30) if finish == "silver" else (0.09, 0.09, 0.10)
    ipad_mesh = next((o for o in objs if o.type == 'MESH' and any(m and m.name.startswith("Screen Image") for m in o.data.materials)), None)
    if ipad_mesh:
        for m in ipad_mesh.data.materials:
            if not m:
                continue
            if m.name.startswith("Screen Image"):
                thin_ipad_bezels(ipad_mesh, m.name, target_bezel_m=0.0042)
                reproject_planar_uv(ipad_mesh, m.name, u_axis='x', v_axis='y', flip_u=False, flip_v=False)
                # Analytic concentric inner corner radius (~8.4mm = outer 12.6mm - 4.2mm bezel)
                make_emissive_screen_material(
                    m, ipad_screen_path,
                    cam_strength=1.48, bounce_strength=4.8, glass_gloss=0.018,
                    corner_radius=0.068, aspect=1.507,
                )
            elif m.name.startswith("Pre-Screen") or m.name.startswith("Glass Front"):
                set_simple_pbr(m, (0.005, 0.005, 0.006), metallic=0.0, roughness=0.04, coat=0.8)
            elif m.name.startswith("Body") or m.name.startswith("Inside"):
                set_simple_pbr(m, body_col, metallic=0.88, roughness=0.40, bump_scale=1600.0, bump_strength=0.012)

    if preset == "iso-vertical":
        # Landscape iPad Mini tucked in front of left half of MacBook keyboard, slightly more upright (18 deg lean)
        # to pair cleanly with the lower hero isometric camera angle.
        root.rotation_euler = (math.radians(72.0), 0.0, math.radians(-18.0))
        root.location = (-0.092, -0.145, 0.0)
    else:
        root.rotation_euler = (math.radians(68.0), 0.0, math.radians(10.0))
        root.location = (-0.125, -0.185, 0.0)
    drop_to_floor(root, objs, 0.0)
    return root, objs


def remove_iphone_island(phone_obj, screen_mat_name):
    """Remove front-facing Dynamic Island / selfie cutout faces in the top-center zone without touching corners or rails."""
    scr_idx = next((i for i, m in enumerate(phone_obj.data.materials) if m and m.name == screen_mat_name), None)
    if scr_idx is None:
        return
    bm = bmesh.new()
    bm.from_mesh(phone_obj.data)
    scr_faces = [f for f in bm.faces if f.material_index == scr_idx]
    if not scr_faces:
        bm.free()
        return
    xs = [v.co.x for f in scr_faces for v in f.verts]
    ys = [v.co.y for f in scr_faces for v in f.verts]
    zs = [v.co.z for f in scr_faces for v in f.verts]
    cx_scr = 0.5 * (min(xs) + max(xs))
    ymax = max(ys)
    z_scr = sum(zs) / len(zs)
    to_del = []
    for f in bm.faces:
        if f.material_index == scr_idx:
            continue
        mat = phone_obj.data.materials[f.material_index] if f.material_index < len(phone_obj.data.materials) else None
        mname = mat.name if mat else ""
        # Never touch titanium chassis rails or outer front glass
        if "color" in mname.lower() or "glass" in mname.lower():
            continue
        c = f.calc_center_median()
        in_top_center = abs(c.x - cx_scr) < 0.015 and (ymax - 0.013) < c.y < (ymax - 0.0002)
        if in_top_center and (c.z < z_scr + 0.0008 or "Lens2" in mname or "2112" in mname):
            to_del.append(f)
    if to_del:
        bmesh.ops.delete(bm, geom=to_del, context='FACES')
        bm.to_mesh(phone_obj.data)
        phone_obj.data.update()
        print(f"Removed iPhone Dynamic Island ({len(to_del)} top-center cutout faces)")
    bm.free()


def build_iphone(ios_screen_path, phone_type="pro", keep_notch=False, preset="hero-vertical"):
    if phone_type == "air":
        blend_fn = "iphone_17_air.blend"
        screen_prefix = "17Air_Screen"
        frame_prefixes = ("17Air_color1", "17Air_color2", "17Air_color3")
    else:
        blend_fn = "iphone_17_pro_max.blend"
        screen_prefix = "17ProMax_Screen"
        frame_prefixes = ("17ProMax_color", "17ProMax_color2", "17ProMax_color3")

    col, objs = append_all_objects(os.path.join(MODELS_DIR, blend_fn), "iPhone")
    root = create_root_empty("iPhoneRoot", objs, col)

    phone_mesh = next((o for o in objs if o.type == 'MESH'), None)
    if phone_mesh:
        screen_mat = next((m for m in phone_mesh.data.materials if m and m.name.startswith(screen_prefix)), None)
        if screen_mat:
            if not keep_notch:
                remove_iphone_island(phone_mesh, screen_mat.name)
            # In local coords: screen faces -Z; +Y is top, -X is right side when viewed from -Z
            reproject_planar_uv(phone_mesh, screen_mat.name, u_axis='x', v_axis='y', flip_u=True, flip_v=False)
            make_emissive_screen_material(screen_mat, ios_screen_path, cam_strength=1.48, bounce_strength=4.5, glass_gloss=0.018)

        for m in phone_mesh.data.materials:
            if not m:
                continue
            if any(m.name.startswith(p) for p in frame_prefixes):
                # Warm desert/natural brushed titanium rail
                set_simple_pbr(m, (0.76, 0.64, 0.54), metallic=1.0, roughness=0.18, coat=0.25, bump_scale=1200.0, bump_strength=0.004)
            elif "Black" in m.name or "black" in m.name:
                set_simple_pbr(m, (0.008, 0.008, 0.009), metallic=0.0, roughness=0.08, coat=0.5)

    if preset == "iso-vertical":
        # Tucked right in front of the MacBook's right keyboard/palm-rest edge, positioned near the right side of the frame
        root.rotation_euler = (math.radians(76.0), 0.0, math.radians(158.0))
        root.location = (0.084, -0.118, 0.0)
    else:
        # Stand upright facing -Y, leaned back ~11 deg, yawed slightly left (-14 deg) so right titanium rail catches rim light
        root.rotation_euler = (math.radians(79.0), 0.0, math.radians(166.0))
        root.location = (0.052, -0.255, 0.0)
    drop_to_floor(root, objs, 0.0)
    return root, objs


def relax_watch_soft_strap(watch_obj):
    """Flatten the rigid circular sport-band loop into a soft relaxed strap so the Watch lies low on the desk."""
    strap_mats = {
        i for i, m in enumerate(watch_obj.data.materials)
        if m and (m.name.startswith("Rubber") or m.name == "Metal" or m.name.startswith("Metal."))
    }
    case_mats = {
        i for i, m in enumerate(watch_obj.data.materials)
        if m and (m.name.startswith("Black metal") or m.name.startswith("Screen"))
    }
    bm = bmesh.new()
    bm.from_mesh(watch_obj.data)
    case_verts = {v for f in bm.faces if f.material_index in case_mats for v in f.verts}
    strap_verts = {v for f in bm.faces if f.material_index in strap_mats for v in f.verts} - case_verts

    # Case back sits around y = -0.022; compress strap depth behind case & tuck bottom stilt loop gently up
    y_back = -0.022
    z_case_bot = 0.0165
    pin_mats = {i for i, m in enumerate(watch_obj.data.materials) if m and (m.name == "Metal" or m.name.startswith("Metal."))}
    pin_verts = {v for f in bm.faces if f.material_index in pin_mats for v in f.verts}
    for v in strap_verts:
        if v.co.y > y_back:
            dy = v.co.y - y_back
            # Smoothly compress rear strap loop to ~42% depth (relaxed silicone drape)
            v.co.y = y_back + dy * 0.42
        if v.co.z < z_case_bot:
            # Tuck the rigid bottom band loop close under the watch body so the watch sits low on the floor
            dz = z_case_bot - v.co.z
            v.co.z = z_case_bot - dz * 0.28
        if v in pin_verts:
            # Keep underside clasp pin tucked inside the relaxed strap so it never pokes under the watch
            v.co.z += 0.010
            v.co.y -= 0.004

    bm.to_mesh(watch_obj.data)
    bm.free()
    watch_obj.data.update()


def build_watch(watch_screen_path, preset="hero-vertical"):
    col, objs = append_all_objects(os.path.join(MODELS_DIR, "smart_watch_2.blend"), "AppleWatch")
    root = create_root_empty("WatchRoot", objs, col)

    watch_mesh = next((o for o in objs if o.name.startswith("A smartwatch")), None)
    if watch_mesh:
        relax_watch_soft_strap(watch_mesh)
        for m in watch_mesh.data.materials:
            if not m:
                continue
            if m.name.startswith("Rubber"):
                set_simple_pbr(m, (0.025, 0.025, 0.027), metallic=0.0, roughness=0.58, bump_scale=600.0, bump_strength=0.012)
            elif m.name.startswith("Metal") or m.name.startswith("Black metal"):
                set_simple_pbr(m, (0.20, 0.16, 0.13), metallic=1.0, roughness=0.22, coat=0.15)
            elif m.name == "Screen" or m.name.startswith("Screen."):
                # Glossy jet-black curved glass bezel around OLED
                set_simple_pbr(m, (0.003, 0.003, 0.004), metallic=0.0, roughness=0.03, coat=1.0)
            elif m.name.startswith("Screen_inside"):
                reproject_planar_uv(watch_mesh, m.name, u_axis='x', v_axis='z', flip_u=False, flip_v=False)
                make_emissive_screen_material(m, watch_screen_path, cam_strength=1.75, bounce_strength=3.5, glass_gloss=0.02)

    # Remove detached rear clasp pin (Cylinder.003) since the relaxed strap compresses forward,
    # and shade the Digital Crown (wheel.001) in dark warm titanium
    kept_objs = []
    for o in objs:
        if o.type == 'MESH' and o.name.startswith("Cylinder"):
            bpy.data.objects.remove(o, do_unlink=True)
            continue
        kept_objs.append(o)
        if o.type == 'MESH' and o != watch_mesh:
            for m in o.data.materials:
                if m:
                    set_simple_pbr(m, (0.32, 0.24, 0.19), metallic=1.0, roughness=0.20)
    objs = kept_objs

    if preset == "iso-vertical":
        # Laid low on the desk resting naturally on its relaxed soft strap between iPad Mini and iPhone
        root.rotation_euler = (math.radians(-46.0), 0.0, math.radians(-18.0))
        root.location = (-0.002, -0.228, 0.0)
    else:
        # Tilt face upward toward camera (-34 deg) resting firmly on desk, yaw slightly left (-12 deg) showing crown
        root.rotation_euler = (math.radians(-34.0), 0.0, math.radians(-12.0))
        root.location = (-0.068, -0.255, 0.0)
    drop_to_floor(root, objs, 0.0)
    return root, objs


def setup_lighting_and_world(scene):
    world = bpy.data.worlds.new("StudioWorld")
    scene.world = world
    nt = world.node_tree
    bg = nt.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.014, 0.014, 0.016, 1.0)
        bg.inputs[1].default_value = 0.50

    def add_area(name, loc, target, energy, size_x, size_y, col=(1.0, 1.0, 1.0)):
        ldata = bpy.data.lights.new(name, type='AREA')
        ldata.shape = 'RECTANGLE'
        ldata.energy = energy
        ldata.size = size_x
        ldata.size_y = size_y
        ldata.color = col
        lobj = bpy.data.objects.new(name, ldata)
        scene.collection.objects.link(lobj)
        lobj.location = loc
        direction = mathutils.Vector(target) - mathutils.Vector(loc)
        lobj.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
        return lobj

    # 1. Soft overhead studio softbox
    add_area("OverheadSoftbox", (0.0, -0.18, 0.95), (0.0, -0.05, 0.05), energy=7.5, size_x=0.9, size_y=0.6, col=(0.98, 0.97, 0.96))

    # 2. Warm right-side rim light (crisp golden-copper highlight along iPhone titanium rail & MacBook edge)
    add_area("WarmRimRight", (0.48, -0.14, 0.28), (0.05, -0.22, 0.08), energy=15.0, size_x=0.22, size_y=0.55, col=(1.0, 0.72, 0.48))

    # 3. Subtle cool-neutral left fill
    add_area("LeftFill", (-0.55, -0.32, 0.28), (-0.06, -0.22, 0.05), energy=4.0, size_x=0.45, size_y=0.45, col=(0.92, 0.94, 1.0))

    # 4. Localized subtle warm orange glow under MacBook/Watch (tighter & softer than v2)
    add_area("WarmDeskGlowLeft", (-0.10, -0.10, 0.11), (-0.11, -0.24, 0.0), energy=0.55, size_x=0.14, size_y=0.08, col=(1.0, 0.36, 0.05))


def setup_camera(scene, preset, scale):
    presets = {
        "hero-vertical": {
            "res": (1080, 1920),
            "type": "PERSP",
            "loc": (0.0, -0.71, 0.285),
            "target": (0.0, -0.06, 0.105),
            "lens": 70.0,
            "use_dof": False,
            "fstop": 16.0,
        },
        "ortho-vertical": {
            "res": (1080, 1920),
            "type": "ORTHO",
            "loc": (0.0, -0.85, 0.34),
            "target": (0.0, -0.08, 0.10),
            "ortho_scale": 0.365,
            "use_dof": False,
            "fstop": 16.0,
        },
        "iso-vertical": {
            "res": (1080, 1920),
            "type": "ORTHO",
            # Low 9.5-deg elevation ray pulled 3x back along the sightline so all ortho rays
            # originate well above Z=0; zoomed tight so the iPhone rail sits cleanly on the right edge.
            "loc": (-1.029, -2.590, 0.549),
            "target": (-0.015, -0.025, 0.106),
            "ortho_scale": 0.334,
            "use_dof": False,
            "fstop": 16.0,
        },
        "hero-wide": {
            "res": (1920, 1080),
            "type": "PERSP",
            "loc": (0.0, -0.68, 0.28),
            "target": (0.0, -0.05, 0.105),
            "lens": 42.0,
            "use_dof": False,
            "fstop": 16.0,
        },
        "square": {
            "res": (1440, 1440),
            "type": "PERSP",
            "loc": (0.0, -0.72, 0.31),
            "target": (0.0, -0.05, 0.10),
            "lens": 58.0,
            "use_dof": False,
            "fstop": 16.0,
        },
        "closeup-phone": {
            "res": (1080, 1920),
            "type": "PERSP",
            "loc": (0.02, -0.46, 0.17),
            "target": (0.055, -0.19, 0.08),
            "lens": 110.0,
            "use_dof": True,
            "fstop": 3.5,
        },
    }
    cfg = presets[preset]
    scene.render.resolution_x = int(cfg["res"][0] * scale)
    scene.render.resolution_y = int(cfg["res"][1] * scale)
    scene.render.resolution_percentage = 100

    cdata = bpy.data.cameras.new("StudioCam")
    cdata.sensor_fit = 'HORIZONTAL'
    cdata.sensor_width = 36.0
    cdata.type = cfg.get("type", "PERSP")
    if cdata.type == "ORTHO":
        cdata.ortho_scale = cfg["ortho_scale"]
    else:
        cdata.lens = cfg["lens"]
    cdata.dof.use_dof = cfg["use_dof"]
    cdata.dof.focus_distance = (mathutils.Vector(cfg["target"]) - mathutils.Vector(cfg["loc"])).length
    cdata.dof.aperture_fstop = cfg["fstop"]

    cobj = bpy.data.objects.new("StudioCam", cdata)
    scene.collection.objects.link(cobj)
    cobj.location = cfg["loc"]
    direction = mathutils.Vector(cfg["target"]) - mathutils.Vector(cfg["loc"])
    cobj.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    scene.camera = cobj
    return cobj


def main():
    args = parse_args()
    os.makedirs(RENDERS_DIR, exist_ok=True)
    out_path = args.out or os.path.join(RENDERS_DIR, f"{args.preset}_{args.phone}.png")
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    clear_scene()
    scene = bpy.context.scene
    setup_cycles(scene, args.samples)
    build_desk(scene)
    build_topo_backdrop(scene, preset=args.preset)
    build_macbook(args.mac, keep_notch=args.keep_notch, finish=args.mac_finish)
    if not args.no_ipad:
        build_ipad(args.ipad, preset=args.preset, finish=args.mac_finish)
    build_iphone(args.ios, args.phone, keep_notch=args.keep_notch, preset=args.preset)
    build_watch(args.watch, preset=args.preset)
    setup_lighting_and_world(scene)
    setup_camera(scene, args.preset, args.scale)

    if args.save_blend:
        os.makedirs(os.path.dirname(os.path.abspath(args.save_blend)), exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))
        print(f"Saved studio blend -> {args.save_blend}")

    scene.render.filepath = os.path.abspath(out_path)
    bpy.ops.render.render(write_still=True)
    print(f"Rendered -> {out_path}")


if __name__ == "__main__":
    main()

"""Build the ferry cast with Blender 4.5 and export each character at origin.

From the repository root:
    blender --background --python art/characters/build_ferry_characters.py
Pass -- --preview to also render a studio lineup beside Blender's temp files.
"""

import math
import sys
from pathlib import Path
from tempfile import gettempdir

import bpy
from mathutils import Euler, Vector


ROOT = Path(__file__).resolve().parents[2]
MODELS = ROOT / "client" / "assets" / "models"
RENDER = "--preview" in sys.argv
TAU = math.tau


def material(name, hex_color, roughness=0.78, metallic=0.0, emission=0.0):
    def linear(value):
        return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4

    color = tuple(linear(int(hex_color[i:i + 2], 16) / 255) for i in (0, 2, 4)) + (1,)
    value = bpy.data.materials.new(name)
    value.diffuse_color = color
    value.use_nodes = True
    bsdf = value.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission > 0.0:
        bsdf.inputs["Emission Color"].default_value = color
        bsdf.inputs["Emission Strength"].default_value = emission
    return value


def normals_smooth(mesh):
    for face in mesh.polygons:
        face.use_smooth = True


class Figure:
    def __init__(self, name):
        self.parts = []
        self.collection = bpy.data.collections.new(name)
        bpy.context.scene.collection.children.link(self.collection)

    def mesh(self, name, vertices, faces, ink, bone):
        data = bpy.data.meshes.new(name)
        data.from_pydata(vertices, [], faces)
        data.update()
        item = bpy.data.objects.new(name, data)
        self.collection.objects.link(item)
        item.data.materials.append(ink)
        normals_smooth(data)
        if bone:
            item.vertex_groups.new(name=bone).add(list(range(len(vertices))), 1, "REPLACE")
        self.parts.append(item)
        return item

    def egg(self, name, position, axes, ink, bone=None, tilt=(0, 0, 0), sides=20, rows=12):
        center = Vector(position)
        rotate = Euler(tilt).to_matrix()
        vertices = [center + rotate @ Vector((0, 0, axes[2]))]
        for row in range(1, rows):
            theta = math.pi * row / rows
            for side in range(sides):
                phi = TAU * side / sides
                point = Vector((
                    axes[0] * math.sin(theta) * math.cos(phi),
                    axes[1] * math.sin(theta) * math.sin(phi),
                    axes[2] * math.cos(theta),
                ))
                vertices.append(center + rotate @ point)
        vertices.append(center + rotate @ Vector((0, 0, -axes[2])))
        faces = [(0, 1 + j, 1 + (j + 1) % sides) for j in range(sides)]
        for row in range(rows - 2):
            start = 1 + row * sides
            faces.extend((start + j, start + j + sides, start + (j + 1) % sides + sides,
                          start + (j + 1) % sides) for j in range(sides))
        last = len(vertices) - 1 - sides
        faces.extend((last + (j + 1) % sides, last + j, len(vertices) - 1)
                     for j in range(sides))
        return self.mesh(name, vertices, faces, ink, bone)

    def loft(self, name, rings, ink, bone=None, sides=32, drape=0.0):
        vertices = []
        for z, rx, ry, dy in rings:
            for side in range(sides):
                phi = TAU * side / sides
                fold = 1 + drape * math.cos(phi * 7)
                vertices.append((rx * fold * math.cos(phi), dy + ry * fold * math.sin(phi),
                                 z + drape * 0.065 * math.cos(7 * phi)))
        faces = [tuple(reversed(range(sides)))]
        for row in range(len(rings) - 1):
            start = row * sides
            faces.extend((start + j, start + (j + 1) % sides, start + (j + 1) % sides + sides,
                          start + j + sides) for j in range(sides))
        faces.append(tuple(range(len(vertices) - sides, len(vertices))))
        return self.mesh(name, vertices, faces, ink, bone)

    def sweep(self, name, profile, ink, bone=None, sides=12, steps=5, aspect=1.0, up=(0, 0, 1), bands=()):
        source = [Vector(point) for point in profile]
        samples = []
        for index in range(len(source) - 1):
            before = source[max(0, index - 1)]
            start = source[index]
            end = source[index + 1]
            after = source[min(len(source) - 1, index + 2)]
            for step in range(steps):
                t = step / steps
                samples.append(0.5 * (
                    2 * start + (end - before) * t
                    + (2 * before - 5 * start + 4 * end - after) * t ** 2
                    + (-before + 3 * start - 3 * end + after) * t ** 3
                ))
        samples.append(source[-1])
        vertices = []
        last_tangent = width = None
        for index, sample in enumerate(samples):
            tangent = (samples[min(index + 1, len(samples) - 1)].to_3d()
                       - samples[max(index - 1, 0)].to_3d()).normalized()
            if last_tangent is None:
                direction = Vector(up)
                if abs(tangent.dot(direction)) > 0.93:
                    direction = Vector((0, 1, 0)) if abs(tangent.y) < 0.90 else Vector((1, 0, 0))
                width = tangent.cross(direction).normalized()
            else:
                width = last_tangent.rotation_difference(tangent) @ width
            height = tangent.cross(width).normalized()
            last_tangent = tangent
            radius = max(0.001, sample[3])
            for side in range(sides):
                phi = TAU * side / sides
                point = sample.to_3d() + radius * (
                    width * math.cos(phi) + height * math.sin(phi) * aspect)
                vertices.append(point)
        faces = [tuple(reversed(range(sides)))]
        for row in range(len(samples) - 1):
            start = row * sides
            faces.extend((start + j, start + (j + 1) % sides, start + (j + 1) % sides + sides,
                          start + j + sides) for j in range(sides))
        faces.append(tuple(range(len(vertices) - sides, len(vertices))))
        shape = self.mesh(name, vertices, faces, ink, bone)
        for start, end, shade in bands:
            slot = shape.data.materials.find(shade.name)
            if slot == -1:
                slot = len(shape.data.materials)
                shape.data.materials.append(shade)
            first = max(0, round(start * (len(samples) - 1)))
            last = min(len(samples) - 1, round(end * (len(samples) - 1)))
            for face in range(1 + first * sides, 1 + last * sides):
                shape.data.polygons[face].material_index = slot
            if first == 0:
                shape.data.polygons[0].material_index = slot
            if last == len(samples) - 1:
                shape.data.polygons[-1].material_index = slot
        return shape

    def merge(self, name):
        bpy.ops.object.select_all(action="DESELECT")
        for item in self.parts:
            item.select_set(True)
        bpy.context.view_layer.objects.active = self.parts[0]
        if len(self.parts) > 1:
            bpy.ops.object.join()
        item = bpy.context.object
        item.name = name
        item.data.name = f"{name} surfaces"
        self.parts = [item]
        return item


def face_y(center, axes, x, z, depth=0):
    u = (x - center[0]) / axes[0]
    v = (z - center[2]) / axes[2]
    return center[1] - axes[1] * math.sqrt(max(0.015, 1 - u * u - v * v)) - depth


def ink_line(figure, name, points, center, axes, ink, bone=None, depth=0.002):
    return figure.sweep(name, [
        (x, face_y(center, axes, x, z, depth), z, r) for x, z, r in points
    ], ink, bone, sides=10, steps=6, aspect=0.18, up=(0, 1, 0))


def eye(figure, side, x, y, z, scale, iris, liner, white, pupil, gleam, bone=None, tilted=0.0):
    turn = (0, side * tilted, side * 0.20)
    figure.egg("Eye rim", (x, y, z), (.063 * scale, .021 * scale, .078 * scale),
               liner, bone, tilt=turn)
    figure.egg("Warm sclera", (x - side * .002 * scale, y - .012 * scale, z - .004 * scale),
               (.054 * scale, .021 * scale, .066 * scale), white, bone, tilt=turn)
    figure.egg("Iris", (x - side * .008 * scale, y - .027 * scale, z + .001),
               (.040 * scale, .017 * scale, .057 * scale), iris, bone, tilt=turn)
    figure.egg("Pupil", (x - side * .009 * scale, y - .038 * scale, z + .004 * scale),
               (.026 * scale, .009 * scale, .043 * scale), pupil, bone, tilt=turn)
    figure.egg("Eye catchlight", (x - .012 * scale, y - .046 * scale, z + .027 * scale),
               (.012 * scale, .004 * scale, .015 * scale), gleam, bone, sides=12, rows=8)
    figure.egg("Small eye catchlight", (x + .011 * scale, y - .044 * scale, z - .019 * scale),
               (.005 * scale, .003 * scale, .007 * scale), gleam, bone, sides=10, rows=7)


def little_smile(figure, y, z, span, ink, bone=None):
    for side in (-1, 1):
        figure.sweep("Smile", [
            (0, y, z, .0052),
            (side * span * .47, y + .002, z - .010, .0048),
            (side * span * .84, y + .010, z - .008, .0041),
            (side * span, y + .018, z + .004, .0015),
        ], ink, bone, sides=7)


def frog_buttons(figure, y, z, ink, bone=None, size=1):
    figure.egg("Cord knot", (0, y - .011 * size, z), (.019 * size, .014 * size, .014 * size),
               ink, bone, sides=12, rows=8)
    for side in (-1, 1):
        figure.sweep("Tied loop", [
            (0, y, z, .008 * size),
            (side * .032 * size, y, z + .012 * size, .008 * size),
            (side * .049 * size, y, z - .008 * size, .008 * size),
            (side * .029 * size, y - .003 * size, z - .018 * size, .007 * size),
            (0, y, z, .006 * size),
        ], ink, bone, sides=8)
        figure.sweep("Hanging cord", [
            (0, y, z, .009 * size),
            (side * .018 * size, y - .010 * size, z - .033 * size, .009 * size),
            (side * .022 * size, y - .003 * size, z - .064 * size, .008 * size),
            (side * .025 * size, y, z - .068 * size, .004 * size),
        ], ink, bone, sides=8)


def sewn_edge(figure, name, path, radius, ink, bone=None):
    figure.sweep(name, [(*point, radius) for point in path], ink, bone, sides=8)


def costume(figure, cloth, dark, edge, binding, bone=None, scale=1.0):
    def sizes(rings):
        return [tuple(v * scale for v in row) for row in rings]

    figure.loft("Pleated tunic", sizes([
        (.195, .196, .121, .007), (.212, .235, .151, .001), (.254, .236, .153, .001),
        (.375, .191, .130, .002), (.477, .205, .142, .014), (.560, .187, .138, .024),
        (.632, .143, .112, .027), (.664, .103, .086, .027),
    ]), cloth, bone, drape=.058)
    figure.loft("Contrast hem", sizes([
        (.209, .224, .145, .001), (.218, .236, .154, .001), (.232, .237, .155, .001),
    ]), dark, bone, drape=.058)
    figure.loft("Waist sash", sizes([
        (.343, .201, .138, .003), (.350, .209, .149, .004), (.375, .205, .145, .004),
        (.393, .201, .141, .004), (.398, .196, .137, .004),
    ]), binding, bone)
    figure.loft("Sash edge", sizes([
        (.351, .209, .149, .004), (.355, .212, .151, .004), (.362, .212, .151, .004),
        (.365, .208, .149, .004),
    ]), dark, bone)
    for sign in (-1, 1):
        sewn_edge(figure, "Wrap lapel", [tuple(v * scale for v in row) for row in [
            (sign * .132, -.059, .619), (sign * .099, -.113, .556),
            (sign * .052, -.137, .495), (sign * -.013, -.147, .434),
            (sign * -.081, -.141, .395),
        ]], (.014 if sign == 1 else .009) * scale, edge if sign == 1 else dark, bone)
        sewn_edge(figure, "Skirt seam", [tuple(v * scale for v in row) for row in [
            (sign * .025, -.145, .340), (sign * .033, -.154, .280),
            (sign * .043, -.151, .231),
        ]], .0045 * scale, dark, bone)


def make_tiger(p):
    f = Figure("Tiger swordsman")
    center, axes = (0, -.005, .907), (.294, .228, .249)
    f.egg("Tiger head", center, axes, p["gold"], "head", sides=40, rows=26)
    f.egg("Crown tuft", (0, .016, 1.146), (.069, .056, .044), p["gold"], "head",
          tilt=(.18, -.35, 0))
    for side in (-1, 1):
        f.egg("Round ear", (side * .211, .014, 1.130), (.095, .061, .108), p["stripe"], "head",
              tilt=(.05, side * .39, side * -.14))
        f.egg("Golden ear rim", (side * .211, -.021, 1.132), (.077, .032, .090), p["gold"], "head",
              tilt=(.05, side * .39, side * -.14))
        f.egg("Cream ear", (side * .210, -.045, 1.137), (.054, .015, .066), p["fur"], "head",
              tilt=(.02, side * .39, side * -.14))
        f.egg("Inner ear", (side * .201, -.053, 1.110), (.035, .011, .034), p["rose"], "head",
              tilt=(0, side * .39, 0))
        f.egg("Cheek ruff", (side * .183, -.134, .812), (.122, .076, .092), p["fur"], "head",
              tilt=(.029, -side * .51, side * .20))
        for index in range(3):
            z = .825 + index * .025
            f.sweep("Cheek tuft", [
                (side * .202, -.108, z - .014, .039),
                (side * (.253 + index * .005), -.096, z, .028),
                (side * (.289 + index * .004), -.075, z + .031, .006),
            ], p["fur"], "head", aspect=.69, up=(0, 1, 0))
        f.egg("Eye cushion", (side * .111, -.204, .914), (.088, .037, .089), p["fur"], "head",
              tilt=(0, -side * .27, side * .18))
        eye(f, side, side * .113, -.226, .906, 1.06, p["amber"], p["stripe"], p["eye_white"],
            p["pupil"], p["gleam"], "head", tilted=-.22)
        ink_line(f, "Brow", [(side * .068, .989, .006), (side * .107, 1.016, .017),
                             (side * .145, 1.012, .018), (side * .175, .983, .005)],
                 center, axes, p["stripe"], "head", depth=.029)
        for stripe in [
            [(0.013, 1.080, .013), (.056, 1.084, .013), (.095, 1.076, .010), (.132, 1.057, .002)],
            [(.009, 1.039, .018), (.043, 1.043, .013), (.071, 1.033, .002)],
            [(.282, .982, .011), (.239, .962, .020), (.220, .922, .016), (.209, .900, .002)],
            [(.280, .910, .010), (.253, .872, .016), (.227, .853, .011), (.204, .845, .002)],
        ]:
            ink_line(f, "Fur stripe", [(x * side, z, radius) for x, z, radius in stripe],
                     center, axes, p["stripe"], "head", depth=.012)
        f.egg("Muzzle pad", (side * .055, -.219, .790), (.074, .057, .050), p["fur"], "head",
              tilt=(0, side * .10, 0))
        for x, z in ((.077, .814), (.096, .801), (.068, .798)):
            f.egg("Whisker spot", (side * x, -.268 + (x - .068) * .46, z),
                  (.0047, .003, .0047), p["toffee"], "head", sides=10, rows=6)
        for idx, dz in enumerate((.012, -.004, -.020)):
            f.sweep("Tiger whisker", [
                (side * .102, -.245, .802 + dz, .0036),
                (side * .198, -.230, .806 + dz * 1.2, .0026),
                (side * .285, -.198, .795 + dz * 1.6, .0010),
            ], p["stripe"], "head", sides=6, steps=3)
    ink_line(f, "Crown stripe", [(0, 1.142, .004), (.002, 1.105, .023), (-.004, 1.055, .021),
                                 (0, 1.010, .013), (0, .982, .002)],
             center, axes, p["stripe"], "head", depth=.009)
    f.egg("Chin", (0, -.155, .752), (.123, .098, .053), p["fur"], "head")
    f.egg("Nose bridge", (0, -.212, .848), (.063, .047, .069), p["gold"], "head")
    f.egg("Nose", (0, -.265, .826), (.038, .022, .024), p["nose"], "head")
    f.egg("Nose sheen", (-.009, -.283, .836), (.018, .004, .005), p["nose_light"], "head",
          sides=14, rows=8)
    sewn_edge(f, "Philtrum", [(0, -.281, .813), (0, -.278, .795), (0, -.276, .785)],
              .005, p["stripe"], "head")
    little_smile(f, -.275, .787, .067, p["stripe"], "head")
    costume(f, p["indigo"], p["indigo_dark"], p["linen"], p["leather"], "chest")
    frog_buttons(f, -.151, .369, p["leather_light"], "chest")
    # Jade waist pendant & gold belt clasp
    f.egg("Belt brass clasp", (0, -.156, .372), (.036, .016, .026), p["brass"], "chest", sides=16, rows=10)
    f.sweep("Jade pendant cord", [
        (.112, -.126, .354, .005), (.126, -.136, .312, .005), (.132, -.139, .265, .004),
    ], p["scarf"], "chest", sides=6)
    f.egg("Waist jade disc", (.133, -.142, .258), (.029, .011, .032), p["jade_light"], "chest",
          tilt=(.08, -.18, .22), sides=18, rows=10)
    f.sweep("Jade tassel", [
        (.133, -.142, .228, .007), (.138, -.145, .195, .014), (.142, -.146, .178, .009),
    ], p["scarf_edge"], "chest", sides=8)

    scarf = []
    for index in range(13):
        phi = TAU * index / 12
        scarf.append((.166 * math.cos(phi), .017 + .122 * math.sin(phi),
                      .693 + .041 * math.sin(phi), .045 + .009 * max(0, -math.sin(phi))))
    f.sweep("Scarf collar", scarf, p["scarf"], "chest", aspect=.73, steps=3)
    scarf_edge = [(x, y - .013, z - .024, .007) for x, y, z, _ in scarf[6:13]]
    f.sweep("Scarf stitching", scarf_edge, p["scarf_edge"], "chest", sides=8, steps=5)
    f.egg("Scarf knot", (-.158, .014, .686), (.056, .053, .039), p["scarf"], "chest",
          tilt=(.30, -.30, .25))
    for offset, length, color in ((0, 1, p["scarf"]), (.034, .76, p["scarf_edge"])):
        f.sweep("Scarf tail", [
            (-.177, .039, .674 - offset, .037), (-.246, .089, .662 - offset, .045),
            (-.299 * length - .04, .136, .617 - offset, .040),
            (-.359 * length - .03, .168, .575 - offset, .025),
            (-.400 * length - .02, .170, .558 - offset, .010),
        ], color, "scarf", aspect=.37, up=(0, 1, 0))
    tail = [
        (.122, .084, .275, .048), (.251, .141, .244, .058),
        (.341, .166, .286, .066), (.374, .135, .381, .067),
        (.338, .106, .467, .061), (.286, .101, .486, .044), (.266, .090, .466, .007),
    ]
    f.sweep("Striped tail", tail, p["gold"], "tail", sides=20, steps=10,
            bands=[(start, end, p["stripe"]) for start, end in ((.13, .21), (.41, .53), (.69, .79), (.88, 1))])

    for side, suffix in ((-1, "L"), (1, "R")):
        shoulder, thigh, foot = f"arm.{suffix}", f"leg.{suffix}", f"foot.{suffix}"
        f.sweep("Sleeve and linen cuff", [
            (side * .128, .012, .590, .104), (side * .207, .006, .532, .098),
            (side * .246, -.019, .465, .077), (side * .257, -.026, .438, .072),
            (side * .259, -.030, .416, .055),
        ], p["indigo"], shoulder, aspect=.91, up=(0, 1, 0), bands=((.55, 1, p["linen"]),))
        # Leather wuxia bracer with brass stud
        f.sweep("Leather bracer", [
            (side * .244, -.018, .472, .080), (side * .256, -.025, .440, .075),
            (side * .258, -.029, .422, .064),
        ], p["leather"], shoulder, aspect=.92, up=(0, 1, 0), sides=14)
        f.egg("Bracer stud", (side * .288, -.054, .448), (.012, .012, .012), p["brass"], shoulder, sides=10, rows=6)
        f.egg("Paw", (side * .262, -.044, .382), (.067, .056, .064), p["gold"], shoulder,
              tilt=(.13, side * .14, 0))
        f.egg("Paw marking", (side * .264, -.080, .396), (.057, .024, .017), p["stripe"], shoulder)
        for finger in (-1, 0, 1):
            f.egg("Paw toe", (side * .264 + .026 * finger, -.076, .357 + .006 * abs(finger)),
                  (.019, .023, .021), p["fur"], shoulder, sides=14, rows=9)
        f.egg("Trouser leg", (side * .108, .007, .187), (.093, .101, .096), p["trousers"], thigh,
              tilt=(.02, side * .08, 0))
        f.egg("Footwrap", (side * .104, -.006, .108), (.079, .078, .044), p["linen"], foot)
        f.egg("Sole", (side * .111, -.029, .036), (.079, .104, .036), p["stripe"], foot)
        f.egg("Tiger foot", (side * .110, -.042, .054), (.075, .105, .050), p["fur"], foot)
        for finger in (-1, 0, 1):
            f.egg("Foot toe", (side * .111 + finger * .031, -.123, .047 + .004 * abs(finger)),
                  (.023, .025, .024), p["fur"], foot, sides=14, rows=9)
    sword(f, p)
    return f


def sword(figure, p):
    base = Vector((-.228, .152, .301))
    tip = Vector((.321, .186, 1.079))
    direction = (tip - base).normalized()

    def along(t, width):
        return (*base.lerp(tip, t), width)

    figure.sweep("Sword scabbard", [along(0, .027), along(.022, .039), along(.38, .034),
                                   along(.73, .043), along(.769, .041)], p["wood"], "chest",
                 aspect=.60, up=(0, 1, 0))
    for first, last in ((.02, .08), (.71, .76), (.94, 1)):
        figure.sweep("Brass sword fitting", [along(first, .041), along((first + last) / 2, .048),
                                             along(last, .043)], p["brass"], "chest",
                     aspect=.75, up=(0, 1, 0))
    figure.sweep("Sword handle", [along(.743, .030), along(.807, .031), along(.951, .031),
                                 along(.98, .023)], p["leather"], "chest")
    for index in range(7):
        t = .798 + index * .021
        figure.sweep("Hilt wrap", [along(t, .031), along(t + .005, .034), along(t + .010, .031)],
                     p["leather_light"], "chest", sides=10, steps=3)
    guard = Vector(along(.772, 0)[:3])
    cross = Vector((direction.z, 0, -direction.x))
    figure.sweep("Sword guard", [(*(guard + cross * spread), radius)
                                for spread, radius in ((-.07, .015), (-.047, .021),
                                                       (.047, .021), (.07, .014))],
                 p["brass"], "chest", aspect=.70, up=(0, 1, 0))
    figure.sweep("Hilt tassel cord", [
        (.312, .164, 1.064, .008), (.359, .156, 1.021, .008), (.367, .136, .960, .008),
    ], p["scarf_edge"], "chest", sides=8)
    figure.sweep("Hilt tassel", [(.367, .136, .970, .013), (.367, .133, .941, .013),
                                (.370, .131, .906, .026), (.372, .134, .898, .018)],
                 p["scarf"], "chest", sides=12)


def make_rabbit(p):
    f = Figure("Rabbit herbalist")
    center, axes = (0, -.009, .770), (.241, .189, .213)
    f.egg("Silvery head", center, axes, p["rabbit"], sides=36, rows=24)
    f.egg("Cream chin", (0, -.119, .665), (.170, .080, .076), p["fur"])
    for i, (x, y, z) in enumerate(((-.049, -.070, .963), (.011, -.100, .972), (.055, -.065, .949))):
        f.sweep("Soft tuft", [(x + .037, y + .010, z - .020, .027),
                             (x + .008, y - .008, z + .018, .032),
                             (x - .017, y + .004, z + .036 - i * .004, .007)],
                p["rabbit_light"], sides=12)
    for side in (-1, 1):
        ear_angle = side * (.29 if side == 1 else .24)
        f.egg("Long ear", (side * .126, .002, 1.071), (.078, .060, .217), p["rabbit"],
              tilt=(-.12, ear_angle, 0), sides=24, rows=16)
        f.egg("Cream ear edge", (side * .128, -.046, 1.074), (.058, .021, .177), p["rabbit_light"],
              tilt=(-.12, ear_angle, 0), sides=24, rows=16)
        f.egg("Blush inner ear", (side * .132, -.061, 1.089), (.043, .012, .153), p["rose"],
              tilt=(-.12, ear_angle, 0), sides=24, rows=16)
        f.egg("Face mask", (side * .113, -.146, .737), (.118, .058, .092), p["fur"],
              tilt=(0, side * .36, side * .18))
        for index in range(2):
            f.sweep("Side ruff", [(side * .154, -.102, .696 + index * .027, .035),
                                 (side * .204, -.099, .718 + index * .027, .030),
                                 (side * .234, -.085, .743 + index * .027, .006)],
                    p["fur"], aspect=.67, up=(0, 1, 0))
        f.egg("Peach blush", (side * .162, -.190, .709), (.052, .018, .023), p["blush"],
              tilt=(0, side * .18, side * .33), sides=20)
        eye(f, side, side * .092, -.188, .770, .92, p["rabbit_iris"], p["ink"], p["eye_white"],
            p["pupil"], p["gleam"], tilted=-.16)
        ink_line(f, "Eyebrow", [(side * .068, .855, .004), (side * .094, .878, .010),
                                (side * .124, .877, .010), (side * .151, .854, .003)],
                 center, axes, p["rabbit_dark"], depth=.009)
        f.egg("Bunny muzzle", (side * .032, -.177, .678), (.056, .039, .036), p["fur"])
    f.egg("Pink nose", (0, -.215, .697), (.024, .013, .017), p["nose_light"])
    little_smile(f, -.215, .673, .040, p["ink"])
    costume(f, p["sage"], p["sage_dark"], p["linen"], p["sage_dark"], scale=.88)
    for side in (-1, 1):
        f.sweep("Sage sleeve and rolled trim", [
            (side * .104, .012, .513, .085), (side * .178, -.018, .461, .092),
            (side * .199, -.062, .391, .071), (side * .169, -.103, .366, .063),
            (side * .135, -.129, .363, .046),
        ], p["sage"], aspect=.93, bands=((.65, 1, p["linen"]),))
        f.egg("Pouch grasp", (side * .114, -.151, .364), (.045, .042, .038), p["fur"])
        f.egg("Trouser leg", (side * .091, .018, .139), (.080, .083, .090), p["sage_dark"])
        f.egg("Bunny foot", (side * .091, -.043, .042), (.073, .093, .042), p["rabbit_light"])
        for finger in (-1, 0, 1):
            f.egg("Toes", (side * .091 + finger * .025, -.118, .038), (.021, .029, .026),
                  p["fur"], sides=14, rows=9)
    f.egg("Rabbit tail", (-.135, .121, .252), (.081, .063, .068), p["rabbit_light"], sides=22)

    f.egg("Herb pouch", (0, -.158, .308), (.100, .064, .097), p["pouch"], sides=24, rows=16)
    f.egg("Pouch gather", (0, -.158, .397), (.066, .047, .039), p["pouch"], sides=22)
    for angle in range(7):
        phi = TAU * angle / 7
        f.egg("Gathered linen fold", (.051 * math.cos(phi), -.158 + .036 * math.sin(phi), .425),
              (.022, .017, .021), p["linen"], tilt=(.28 * math.sin(phi), -.39 * math.cos(phi), 0),
              sides=12, rows=8)
    f.egg("Pouch opening", (0, -.158, .432), (.043, .028, .009), p["leather"])
    frog_buttons(f, -.208, .397, p["sage_dark"], size=.67)
    for x, z, size in ((.041, .276, .034), (.053, .288, .027), (.026, .283, .029)):
        f.sweep("Embroidered herb", [(x, -.217, z, .003), (x + size * .26, -.214, z + size * .50, .007),
                                    (x + size * .44, -.210, z + size, .002)], p["sage_dark"],
                sides=7, steps=4, aspect=.44, up=(0, 1, 0))
    # Woven bamboo herb basket on back + medicinal herbs + waist gourd
    f.loft("Herb basket", [
        (.315, .096, .076, .185), (.370, .112, .088, .192), (.475, .128, .098, .198),
        (.565, .138, .104, .202), (.595, .132, .098, .200),
    ], p["straw"], sides=20, drape=.035)
    f.loft("Basket rim", [
        (.575, .142, .108, .202), (.595, .146, .112, .202), (.612, .140, .106, .202),
    ], p["ochre"], sides=20)
    for idx, (ox, oy, h) in enumerate(((-.055, .188, .72), (.008, .205, .75), (.062, .195, .70), (-.020, .232, .69))):
        f.sweep("Fresh herb sprig", [
            (ox, oy, .575, .010), (ox * 1.15, oy + .018, .645, .022), (ox * 1.25, oy + .030, h, .004),
        ], p["jade_light"] if idx % 2 == 0 else p["sage_dark"], sides=8, steps=4, aspect=.38, up=(0, 1, 0))
    f.egg("Medicine gourd bottom", (.176, -.058, .302), (.048, .048, .054), p["brass"], sides=18, rows=12)
    f.egg("Medicine gourd top", (.176, -.058, .372), (.033, .033, .036), p["brass"], sides=16, rows=10)
    f.egg("Gourd stopper", (.176, -.058, .412), (.014, .014, .015), p["scarf"], sides=12, rows=8)
    return f


def straw_leaf(figure, base, tip, width, ink):
    a, b = Vector(base), Vector(tip)
    profile = [
        (*a, width * .55), (*a.lerp(b, .27), width), (*a.lerp(b, .60), width * .74),
        (*a.lerp(b, .82), width * .40), (*b, .0015),
    ]
    figure.sweep("Lacquered straw blade", profile, ink, sides=8, steps=3,
                 aspect=.30, up=(0, 0, 1))


def make_ox(p):
    f = Figure("Ox ferryman")
    center, axes = (0, .003, .818), (.278, .208, .207)
    f.egg("Chestnut head", center, axes, p["ox"], sides=36, rows=24)
    f.egg("Muzzle mass", (0, -.163, .711), (.156, .092, .096), p["ox_dark"])
    f.egg("Velvet muzzle", (0, -.198, .716), (.142, .081, .070), p["ox_muzzle"], sides=28)
    f.egg("Muzzle top", (0, -.237, .739), (.122, .046, .051), p["ox_muzzle"], sides=28)
    for side in (-1, 1):
        f.egg("Nostril rim", (side * .075, -.271, .755), (.028, .013, .020), p["ox_rose"],
              tilt=(0, -side * .56, side * .32))
        f.egg("Nostril", (side * .077, -.281, .757), (.019, .007, .013), p["stripe"],
              tilt=(0, -side * .56, side * .32), sides=14, rows=9)
        f.egg("Broad ear", (side * .299, .009, .867), (.129, .067, .061), p["ox_dark"],
              tilt=(.17, -side * .27, side * .08))
        f.egg("Ear bronze", (side * .308, -.025, .867), (.113, .047, .050), p["ox"],
              tilt=(.17, -side * .27, side * .08))
        f.egg("Ear blush", (side * .326, -.059, .862), (.077, .019, .032), p["ox_rose"],
              tilt=(.17, -side * .29, side * .09))
        horn = [
            (side * .148, .011, .968, .076), (side * .235, .020, 1.001, .074),
            (side * .303, .024, 1.032, .061), (side * .334, .020, 1.106, .043),
            (side * .322, .005, 1.186, .021), (side * .292, -.021, 1.225, .003),
        ]
        f.sweep("Ivory horn", horn, p["horn"], sides=20, steps=8, aspect=.82,
                bands=((0, .14, p["horn_base"]),))
        eye(f, side, side * .113, -.186, .831, .89, p["amber_dark"], p["ink"],
            p["eye_white"], p["pupil"], p["gleam"], tilted=-.35)
        ink_line(f, "Heavy brow", [(side * .056, .887, .004), (side * .094, .915, .015),
                                    (side * .126, .921, .020), (side * .172, .901, .004)],
                 center, axes, p["ox_dark"], depth=.016)
        for index in range(4):
            x = side * (.022 + index * .037)
            f.sweep("Shaggy forelock", [
                (side * .038 + x * .19, -.029, 1.035 + .006 * index, .041),
                (x, -.135, .999 + .008 * index, .047 - .004 * index),
                (x + side * .014, -.183, .952 + .011 * index, .021),
                (x + side * .011, -.187, .920 + .016 * index, .004),
            ], p["ox_hair"] if index % 2 else p["ox"], sides=12, aspect=.69, up=(0, 1, 0))
    little_smile(f, -.270, .680, .074, p["ox_dark"])
    # Brass nose ring
    nose_ring = []
    for index in range(15):
        phi = math.radians(-155 + 310 * index / 14)
        nose_ring.append((.046 * math.sin(phi), -.286 - .006 * math.cos(phi), .698 - .042 * math.cos(phi), .0085))
    f.sweep("Brass nose ring", nose_ring, p["brass"], sides=10, steps=2)
    costume(f, p["mustard"], p["ochre"], p["linen"], p["indigo"], scale=1.07)
    f.loft("Straw cape collar", [
        (.530, .266, .136, .013), (.563, .286, .147, .018), (.622, .233, .138, .017),
        (.665, .160, .116, .012), (.699, .135, .096, .023),
    ], p["ochre"], drape=.075)
    frog_buttons(f, -.153, .596, p["linen"], size=1.04)
    frog_buttons(f, -.161, .387, p["indigo"], size=1.14)
    for side in (-1, 1):
        f.sweep("Ferryman sleeve and cuff", [
            (side * .149, .021, .595, .119), (side * .246, .003, .508, .102),
            (side * .266, -.026, .459, .080), (side * .282, -.041, .425, .073),
            (side * .283, -.045, .405, .060),
        ], p["mustard"], aspect=.90, bands=((.55, 1, p["linen"]),))
        f.egg("Ferryman hand", (side * .281, -.049, .375), (.072, .063, .065), p["ox"])
        for finger in (-1, 0, 1):
            f.egg("Fingers", (side * .278 + .027 * finger, -.091, .356),
                  (.023, .020, .025), p["ox_hair"], sides=14, rows=9)
        f.egg("Ferryman trousers", (side * .113, .013, .164), (.109, .104, .100), p["trousers"])
        f.egg("Padded ankle wrap", (side * .118, .008, .084), (.087, .081, .048), p["linen"])
        f.egg("Cloven hoof", (side * .122, -.028, .043), (.085, .098, .043), p["ox_dark"])
        for toe in (-1, 1):
            f.egg("Hoof toe", (side * .122 + toe * .036, -.091, .041), (.035, .038, .036),
                  p["hoof"], sides=16)
        for layer in range(3):
            for index in range(10):
                angle = -.98 + 2.17 * index / 9
                spread = .222 - .029 * layer
                base = (side * spread * math.cos(angle), .153 * math.sin(angle), .631 + .025 * layer)
                tip = (
                    side * (spread + .153 - .004 * layer) * math.cos(angle),
                    (.247 - .020 * layer) * math.sin(angle),
                    .503 + .049 * layer + .024 * abs(math.sin(angle)),
                )
                straw_leaf(f, base, tip, .036 - .004 * layer,
                           (p["straw_light"], p["straw"], p["mustard"])[(index + 2 * layer) % 3])
    # Conical woven bamboo hat (douli) slung across back
    hat_center = Vector((0.0, .235, .565))
    hat_rings = []
    for rad, depth in ((.012, .118), (.095, .086), (.195, .048), (.305, .010), (.355, -.010)):
        ring_pts = []
        for s in range(28):
            phi = TAU * s / 28
            ring_pts.append((hat_center.x + rad * math.cos(phi),
                             hat_center.y + depth,
                             hat_center.z + rad * math.sin(phi)))
        hat_rings.append(ring_pts)
    hat_verts = [pt for ring in hat_rings for pt in ring]
    hat_faces = []
    for r in range(len(hat_rings) - 1):
        for s in range(28):
            n = (s + 1) % 28
            a = r * 28 + s
            b = r * 28 + n
            c = (r + 1) * 28 + n
            d = (r + 1) * 28 + s
            hat_faces.append((a, b, c, d))
    f.mesh("Bamboo rain hat", hat_verts, hat_faces, p["straw_light"], None)
    hat_rim = [(hat_center.x + .355 * math.cos(TAU * s / 28),
                hat_center.y - .010,
                hat_center.z + .355 * math.sin(TAU * s / 28), .013) for s in range(29)]
    f.sweep("Hat bamboo rim", hat_rim, p["ochre"], sides=8, steps=2)
    return f


def make_snake(p):
    f = Figure("Jade reed snake")
    body = []
    for i in range(25):
        pct = i / 24
        phi = -.59 - TAU * 1.11 * pct
        radial = .274 + .067 * math.sin(math.pi * pct) - .17 * pct ** 5
        z = .103 + .132 * math.exp(-9 * pct) + .067 * pct ** 5
        thickness = .006 + .094 * min(1, pct * 6)
        body.append((radial * math.cos(phi), radial * math.sin(phi), z, thickness))
    body.extend([
        (.074, .035, .204, .107), (.115, -.006, .279, .107), (.106, -.030, .365, .102),
        (.053, -.038, .451, .102), (-.008, -.059, .534, .104), (-.017, -.080, .603, .107),
    ])
    f.sweep("Complete coiled body", body, p["jade"], sides=24, steps=5)
    for index in range(4, 22):
        radial = Vector(body[index][:2]).normalized()
        x, y, z, radius = body[index]
        phi = math.atan2(radial.y, radial.x)
        f.egg("Coil belly plate", (x + radial.x * .065, y + radial.y * .064, z - .045),
              (.044, .029, .027), p["snake_belly"] if index % 3 else p["snake_belly_dark"],
              tilt=(.30, 0, phi + math.pi / 2), sides=14, rows=8)
        if index % 2 == 0:
            f.egg("Jade scale accent", (x + radial.x * .042, y + radial.y * .042, z + .087),
                  (.032, .020, .006), p["jade_light"], tilt=(.17, .18, phi),
                  sides=14, rows=8)
    for index in range(2, 12):
        t = index / 11
        x = .097 * math.sin(math.pi * t * 1.30)
        y = -.092 - .074 * t
        z = .187 + .390 * t
        f.egg("Neck belly plate", (x, y, z), (.077 + .014 * math.sin(math.pi * t), .032, .030),
              p["snake_belly"] if index % 4 else p["snake_belly_dark"],
              tilt=(.13, -.24 + .60 * t, 0), sides=22, rows=10)

    center, axes = (-.029, -.099, .643), (.193, .157, .155)
    f.egg("Jade head", center, axes, p["jade"], sides=36, rows=22)
    f.egg("Pale lower jaw", (-.038, -.157, .569), (.153, .117, .064), p["snake_belly"], sides=26)
    f.egg("Short snout", (-.037, -.198, .610), (.126, .085, .054), p["jade"], sides=28, rows=14)
    for side in (-1, 1):
        x = -.029 + side * .100
        f.egg("Brow ridge", (x, -.204, .661), (.084, .047, .065), p["jade_dark"],
              tilt=(0, side * .41, side * .33))
        f.egg("Pale eye edge", (x, -.225, .648), (.061, .038, .044), p["snake_belly"],
              tilt=(0, -side * .37, side * .31))
        f.egg("Amber eye", (x, -.252, .652), (.048, .025, .038), p["snake_eye"],
              tilt=(0, -side * .35, side * .27), sides=22)
        f.egg("Vertical pupil", (x - side * .007, -.271, .652), (.012, .009, .030), p["pupil"],
              tilt=(0, -side * .18, side * .22), sides=14, rows=10)
        f.egg("Snake catchlight", (x - .006, -.277, .666), (.008, .004, .009), p["gleam"],
              sides=12, rows=8)
        f.egg("Nostril", (-.037 + side * .050, -.273, .615), (.013, .008, .006), p["jade_dark"],
              tilt=(0, side * .28, side * .19), sides=12, rows=8)
        f.sweep("Snake smile", [
            (-.037, -.276, .585, .004), (-.037 + side * .076, -.259, .584, .005),
            (-.037 + side * .122, -.220, .590, .004), (-.037 + side * .148, -.182, .610, .002),
        ], p["jade_dark"], sides=7, steps=5)
        ink_line(f, "Pale temple marking", [
            (-.029 + side * .155, .715, .006),
            (-.029 + side * .109, .736, .011),
            (-.029 + side * .092, .756, .009),
            (-.029 + side * .058, .759, .005),
        ], center, axes, p["snake_belly_dark"], depth=.010)
    for row in range(3):
        for col in range(-row - 1, row + 2):
            x = -.030 + .042 * col
            z = .773 - .020 * row
            if abs(col) + row > 4:
                continue
            y = face_y(center, axes, x, z, .003)
            f.egg("Forehead scale", (x, y, z), (.016, .004, .010),
                  p["jade_light"] if (col + row) % 3 else p["jade_dark"],
                  tilt=(.55 - .11 * row, 0, -.10 * col), sides=12, rows=7)
    tongue = [(-.043, -.268, .581, .009), (-.043, -.294, .571, .009), (-.045, -.327, .551, .008)]
    f.sweep("Tongue", tongue, p["tongue"], sides=8, aspect=.70)
    for side in (-1, 1):
        f.sweep("Forked tongue tip", [tongue[-1], (-.046 + side * .012, -.347, .536, .005),
                                     (-.046 + side * .016, -.359, .533, .0015)],
                p["tongue"], sides=7, aspect=.72)
        # Curved ivory fangs
        f.sweep("Snake fang", [
            (-.037 + side * .058, -.255, .586, .011),
            (-.037 + side * .061, -.265, .560, .007),
            (-.037 + side * .056, -.261, .538, .0015),
        ], p["horn"], sides=8, steps=3)
        # Flared hood frill behind head
        f.egg("Cobra hood frill", (-.018 + side * .128, -.068, .555), (.088, .032, .155),
              p["jade_dark"], tilt=(.14, side * .22, side * -.28), sides=18, rows=12)
        f.egg("Hood gold accent", (-.018 + side * .136, -.092, .565), (.052, .014, .105),
              p["snake_belly"], tilt=(.14, side * .22, side * -.28), sides=14, rows=10)
    # Dorsal ridge crest spines along raised neck
    for idx in range(6):
        t = idx / 5
        f.egg("Dorsal spine", (.060 * (1 - t) - .015 * t, .018 - .040 * t, .26 + .34 * t),
              (.014, .034, .022), p["jade_light"] if idx % 2 == 0 else p["jade_dark"],
              tilt=(-.35, 0, 0), sides=10, rows=6)
    return f


def tiger_rig(figure, mesh):
    rig = bpy.data.armatures.new("Tiger bones")
    actor = bpy.data.objects.new("Tiger", rig)
    figure.collection.objects.link(actor)
    bpy.context.view_layer.objects.active = actor
    actor.show_in_front = True
    rig.display_type = "STICK"
    bpy.ops.object.mode_set(mode="EDIT")

    def bone(name, start, end, parent=None):
        edit = rig.edit_bones.new(name)
        edit.head, edit.tail = start, end
        if parent:
            edit.parent = rig.edit_bones[parent]

    bone("root", (0, 0, 0), (0, 0, .26))
    bone("hips", (0, 0, .28), (0, 0, .40), "root")
    bone("chest", (0, 0, .38), (0, .014, .684), "hips")
    bone("head", (0, -.006, .680), (0, -.006, 1.130), "chest")
    bone("tail", (.122, .084, .275), (.358, .150, .344), "hips")
    bone("scarf", (-.175, .033, .668), (-.398, .165, .568), "chest")
    for side, label in ((-1, "L"), (1, "R")):
        bone(f"arm.{label}", (side * .146, .005, .575), (side * .262, -.028, .424), "chest")
        bone(f"leg.{label}", (side * .105, .003, .259), (side * .105, .002, .104), "hips")
        bone(f"foot.{label}", (side * .105, .002, .104), (side * .108, -.085, .050), f"leg.{label}")
    bpy.ops.object.mode_set(mode="OBJECT")
    mesh.parent = actor
    modifier = mesh.modifiers.new("Tiger skin", "ARMATURE")
    modifier.object = actor
    bpy.context.scene.render.fps = 24
    actor.animation_data_create()
    for action_name, duration, animate in (("idle", 48, tiger_idle), ("walk", 24, tiger_walk), ("attack", 16, tiger_attack)):
        action = bpy.data.actions.new(action_name)
        actor.animation_data.action = action
        for step in range(9):
            phase = TAU * (step % 8) / 8
            frame = step * duration // 8
            for target, (location, rotation, scale) in animate(phase).items():
                part = actor.pose.bones[target]
                part.rotation_mode = "XYZ"
                part.location = location
                part.rotation_euler = rotation
                part.scale = scale
                part.keyframe_insert("location", frame=frame, group=target)
                part.keyframe_insert("rotation_euler", frame=frame, group=target)
                part.keyframe_insert("scale", frame=frame, group=target)
        plant_feet(actor, mesh, duration, action_name == "walk")
        actor.animation_data.action = None
        track = actor.animation_data.nla_tracks.new()
        track.name = action_name
        track.strips.new(action_name, 0, action)
        track.mute = True
    actor.animation_data.nla_tracks["idle"].mute = False
    bpy.context.scene.frame_start = 0
    bpy.context.scene.frame_set(0)
    return actor


def plant_feet(actor, mesh, duration, walking):
    scene = bpy.context.scene
    supports = []
    for side, label in ((-1, "L"), (1, "R")):
        foot = actor.pose.bones[f"foot.{label}"]
        leg = actor.pose.bones[f"leg.{label}"]
        group_index = mesh.vertex_groups[foot.name].index
        vertices = [vertex.co.copy() for vertex in mesh.data.vertices
                    if any(group.group == group_index for group in vertex.groups)]
        supports.append((side, leg, foot, foot.bone.matrix_local.inverted(), vertices))
    for frame in range(duration + 1):
        scene.frame_set(frame)
        stride = math.sin(TAU * (frame % duration) / duration) if walking else 0
        for side, leg, foot, bind_inverse, vertices in supports:
            posed = foot.matrix @ bind_inverse
            sole_height = min((posed @ vertex).z for vertex in vertices)
            desired_height = .057 * max(0, side * stride)
            # The thigh bone's local Y axis points toward the ankle.
            leg.location.y += sole_height - desired_height
            leg.keyframe_insert("location", frame=frame, group=leg.name)


def transform(location=(0, 0, 0), rotation=(0, 0, 0), scale=(1, 1, 1)):
    return location, rotation, scale


def tiger_idle(theta):
    sway = math.sin(theta)
    inhale = (1 - math.cos(theta)) / 2
    return {
        "hips": transform(location=(0, .009 * inhale, 0)),
        "chest": transform(rotation=(.018 * sway, 0, .018 * sway),
                           scale=(1 + .018 * inhale, 1, 1 + .015 * inhale)),
        "head": transform(rotation=(-.024 * sway, .018 * sway, -.024 * sway)),
        "arm.L": transform(rotation=(.025 * sway, 0, .020 * inhale)),
        "arm.R": transform(rotation=(.025 * sway, 0, -.020 * inhale)),
        "leg.L": transform(),
        "leg.R": transform(),
        "foot.L": transform(),
        "foot.R": transform(),
        "scarf": transform(rotation=(.053 * sway, .059 * math.sin(theta - .3), 0)),
        "tail": transform(rotation=(.056 * sway, .16 * math.sin(theta - .7), .060 * sway)),
    }


def tiger_walk(theta):
    stride = math.cos(theta)
    lift = math.sin(theta)
    bob = .016 * (1 - math.cos(2 * theta))
    pose = {
        "hips": transform(location=(.023 * lift, bob, 0), rotation=(0, -.065 * stride, 0)),
        "chest": transform(rotation=(.083, .160 * stride, .071 * lift)),
        "head": transform(rotation=(-.073 + .048 * math.cos(2 * theta), -.068 * stride, -.071 * lift)),
        "scarf": transform(rotation=(.18, .147 * math.sin(theta - .5), -.115 * lift)),
        "tail": transform(rotation=(.04, .27 * math.sin(theta - .6), -.11 * stride)),
    }
    for sign, label in ((-1, "L"), (1, "R")):
        swing = stride * sign
        swing_lift = max(0, lift * sign)
        pose[f"arm.{label}"] = transform(rotation=(.61 * swing, .08 * swing, -.063 * sign))
        pose[f"leg.{label}"] = transform(rotation=(-.62 * swing + .37 * swing_lift, 0, -.07 * sign),
                                          location=(0, -.034 * swing_lift, 0))
        pose[f"foot.{label}"] = transform(rotation=(.48 * swing - .43 * swing_lift, 0, 0))
    return pose


def tiger_attack(theta):
    # Martial forward strike: wind-up -> crisp palm/paw thrust -> recover
    strike = math.sin(theta)
    thrust = max(0.0, math.sin(theta - 0.35))
    return {
        "hips": transform(location=(0, 0.025 * thrust, -0.055 * thrust), rotation=(0, 0.14 * strike, 0)),
        "chest": transform(rotation=(0.24 * thrust, -0.32 * strike, 0.08 * thrust)),
        "head": transform(rotation=(-0.14 * thrust, 0.22 * strike, 0)),
        "arm.L": transform(rotation=(-0.45 * strike, 0, -0.22 * thrust)),
        "arm.R": transform(rotation=(1.15 * thrust - 0.25 * max(0.0, -strike), 0.20 * thrust, 0.18 * thrust)),
        "leg.L": transform(rotation=(0.28 * thrust, 0, 0)),
        "leg.R": transform(rotation=(-0.32 * thrust, 0, 0)),
        "foot.L": transform(),
        "foot.R": transform(),
        "scarf": transform(rotation=(0.35 * thrust, 0.28 * strike, -0.18 * thrust)),
        "tail": transform(rotation=(0.15 * thrust, -0.35 * strike, 0.12 * thrust)),
    }


def palette():
    colors = {
        "gold": ("Tiger persimmon", "DF8E36", .86), "stripe": ("Burnt umber", "3B221D", .88),
        "fur": ("Cream fur", "F6E2B8", .90), "rose": ("Soft ear blush", "E29B84", .86),
        "amber": ("Tiger amber", "B26C2A", .14), "amber_dark": ("Ox amber", "844F24", .16),
        "eye_white": ("Natural sclera", "FFF5DA", .18), "pupil": ("Dark eye glass", "1C1513", .08),
        "gleam": ("Glint", "FFFDF0", .08, .0, .45), "toffee": ("Warm fur freckles", "B57153", .86),
        "nose": ("Rose umber", "8F4C3C", .32), "nose_light": ("Nose blush", "CC876E", .36),
        "linen": ("Raw linen", "E2C493", .88), "leather": ("Oiled leather", "5C301F", .44),
        "leather_light": ("Laced leather", "A26037", .50), "indigo": ("Indigo cotton", "3C5270", .84),
        "indigo_dark": ("Indigo binding", "27364E", .86), "trousers": ("Padded brown", "52463F", .88),
        "scarf": ("Madder scarf", "B03A27", .82), "scarf_edge": ("Coral topstitch", "DB6E4B", .78),
        "wood": ("Rosewood", "4F2D21", .52), "brass": ("Burnished brass", "D0A052", .26, .84),
        "rabbit": ("Rabbit pebble fur", "B4A591", .90), "rabbit_light": ("Rabbit fur tips", "D2C3AA", .90),
        "rabbit_dark": ("Rabbit gray brow", "867261", .88), "rabbit_iris": ("Rabbit tea iris", "8C6342", .16),
        "blush": ("Peach cheek", "EEA891", .86), "ink": ("Deep brown", "3A251F", .82),
        "sage": ("Sage cotton", "6C8265", .84), "sage_dark": ("Mossy cloth", "405849", .86),
        "pouch": ("Ochre pouch linen", "D1A35F", .86), "ox": ("Ox warm chestnut", "AD693A", .88),
        "ox_dark": ("Ox dark chestnut", "5F3A2A", .88), "ox_hair": ("Ox copper hair", "9E572E", .88),
        "ox_muzzle": ("Ox muzzle", "E4A478", .78), "ox_rose": ("Ox ear salmon", "C98661", .82),
        "horn": ("Worn ivory", "E8D3B0", .38), "horn_base": ("Weathered ivory", "9C846A", .52),
        "mustard": ("Ochre cotton", "C48F3B", .86), "ochre": ("Straw's umber", "7F5829", .84),
        "straw": ("Honey straw", "CC9A4D", .82), "straw_light": ("Pale sun straw", "E2B764", .80),
        "hoof": ("Soft hoof", "4F382E", .42), "jade": ("Jade scales", "46765E", .36),
        "jade_dark": ("Deep jade", "2A5446", .40), "jade_light": ("Sunlit jade", "6FA17B", .32),
        "snake_belly": ("Snake belly ivory", "E8CF98", .62), "snake_belly_dark": ("Snake shadow ivory", "C0A26B", .66),
        "snake_eye": ("Snake gold iris", "E6A135", .12, .0, .55), "tongue": ("Snake tongue", "B64844", .36),
    }
    return {name: material(*values) for name, values in colors.items()}


def export(figure, species, rig=None):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in figure.parts:
        obj.select_set(True)
    if rig:
        rig.select_set(True)
        bpy.context.view_layer.objects.active = rig
        for track in rig.animation_data.nla_tracks:
            track.mute = False
    bpy.ops.export_scene.gltf(
        filepath=str(MODELS / f"{species}.glb"),
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_animations=rig is not None,
        export_animation_mode="NLA_TRACKS",
        export_frame_range=False,
        export_current_frame=False,
        export_force_sampling=True,
        export_skins=True,
        export_extras=True,
    )
    if rig:
        for track in rig.animation_data.nla_tracks:
            track.mute = track.name != "idle"
        bpy.context.scene.frame_set(0)
    obj = figure.parts[0]
    print(f"{species}: {len(obj.data.vertices)} vertices, {len(obj.data.materials)} materials")


def lighting(collection, name, point, power, size, target=(0, 0, .53), color=(1, 1, 1)):
    data = bpy.data.lights.new(name, "AREA")
    data.energy = power
    data.size = size
    data.color = color
    item = bpy.data.objects.new(name, data)
    collection.objects.link(item)
    item.location = point
    item.rotation_euler = (Vector(target) - item.location).to_track_quat("-Z", "Y").to_euler()


def studio():
    scene = bpy.context.scene
    collection = bpy.data.collections.new("Studio")
    scene.collection.children.link(collection)
    floor_material = material("Slate blue studio floor", "40525C")
    data = bpy.data.meshes.new("Studio floor")
    data.from_pydata([(-100, -100, -.006), (100, -100, -.006), (100, 100, -.006),
                    (-100, 100, -.006)], [], [(0, 1, 2, 3)])
    floor = bpy.data.objects.new("Ground", data)
    collection.objects.link(floor)
    floor.data.materials.append(floor_material)
    camera_data = bpy.data.cameras.new("Lineup")
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = 4.20
    camera = bpy.data.objects.new("Lineup camera", camera_data)
    camera.location = (.61, -6.4, 2.35)
    camera.rotation_euler = (Vector((0, 0, .61)) - camera.location).to_track_quat("-Z", "Y").to_euler()
    collection.objects.link(camera)
    scene.camera = camera
    lighting(collection, "High softbox", (-1.9, -3.8, 4), 320, 3.5, color=(1, .87, .70))
    lighting(collection, "Broad fill", (3.6, -2.5, 2.5), 220, 3.3, color=(.69, .82, 1))
    lighting(collection, "Warm rim", (-1.2, 2.1, 3.6), 370, 3.2, color=(1, .83, .58))
    scene.world = bpy.data.worlds.new("Studio ambience")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (.38, .38, .38, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = .35
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 1560
    scene.render.resolution_y = 670
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
    for workspace in bpy.data.workspaces:
        for screen in workspace.screens:
            for area in screen.areas:
                if area.type == "VIEW_3D":
                    view = area.spaces.active
                    view.region_3d.view_perspective = "CAMERA"
                    view.shading.color_type = "MATERIAL"
                    view.overlay.show_overlays = False


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    MODELS.mkdir(parents=True, exist_ok=True)
    colors = palette()
    for index, (name, builder) in enumerate((
        ("tiger", make_tiger), ("rabbit", make_rabbit), ("ox", make_ox), ("snake", make_snake),
    )):
        figure = builder(colors)
        mesh = figure.merge(figure.collection.name)
        lowest = min(vertex.co.z for vertex in mesh.data.vertices)
        for vertex in mesh.data.vertices:
            vertex.co.z -= lowest
        mesh.data.update()
        rig = tiger_rig(figure, mesh) if name == "tiger" else None
        export(figure, name, rig)
        actor = rig or mesh
        actor.location.x = (index - 1.5) * .95
        actor.rotation_euler.z = math.radians((10, -5, 3, -9)[index])
    studio()
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(Path(__file__).with_name("Ferry Characters.blend")), compress=True)
    if RENDER:
        bpy.context.scene.render.filepath = str(Path(gettempdir()) / "ferry-characters.png")
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()

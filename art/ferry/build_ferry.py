"""Build the editable ferry scene and its Godot-ready glTF.

Run with Blender 4.5 from any directory:
    blender --background --factory-startup --python art/ferry/build_ferry.py

Add "-- --preview" to render the orthographic shot to the system temp folder.
Blender +Z is up; a server tile (column, row) is centered at
(column - 0.5, 0.5 - row, 0). The default glTF axis conversion yields
(column - 0.5, 0, row - 0.5) in Godot.
"""

from array import array
from math import atan2, cos, pi, sin
from pathlib import Path
import os
import random
import sys

import bpy
from mathutils import Vector
from mathutils.geometry import tessellate_polygon


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent / "ferry.blend"
EXPORT = ROOT / "client" / "assets" / "models" / "ferry.glb"
RNG = random.Random(1747)

bpy.ops.wm.read_factory_settings(use_empty=True)
SCENE = bpy.context.scene
SCENE.name = "Creek Bridge Ferry"


def collection(name):
    result = bpy.data.collections.new(name)
    SCENE.collection.children.link(result)
    return result


LAND = collection("01  Bank and flagstone")
INN = collection("02  Creek Bridge Inn")
BOAT = collection("03  Landing, boats and boathouse")
VEGETATION = collection("04  Willows and reedbeds")
DETAIL = collection("05  Wayside details")
STUDIO = collection("06  Preview camera and lights")


def rgb(code):
    def linear(component):
        value = int(component, 16) / 255
        return value / 12.92 if value < .04045 else ((value + .055) / 1.055) ** 2.4

    return tuple(linear(code[index:index + 2]) for index in (0, 2, 4))


def material(name, code, rough=.85, emission=0, texture=None):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*rgb(code), 1)
    mat.use_nodes = True
    tree = mat.node_tree
    shader = tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = mat.diffuse_color
    shader.inputs["Roughness"].default_value = rough
    if emission:
        shader.inputs["Emission Color"].default_value = mat.diffuse_color
        shader.inputs["Emission Strength"].default_value = emission
    if texture:
        node = tree.nodes.new("ShaderNodeTexImage")
        node.image = texture
        node.extension = "REPEAT"
        tree.links.new(node.outputs["Color"], shader.inputs["Base Color"])
    return mat


def palette(name, colors, **settings):
    return [material(f"{name} {index + 1}", code, **settings)
            for index, code in enumerate(colors.split())]


def atlas_images():
    src = bpy.data.images.load(str(ROOT / "client" / "assets" / "ferry-materials.png"))
    width, height = src.size
    pixels = array("f", [0]) * (width * height * 4)
    src.pixels.foreach_get(pixels)
    crops = {
        "Grass": (631, 3), "Flagstone": (3, 3),
        "Timber": (631, 631),
    }
    images = {}
    for name, (x, y) in crops.items():
        size = 620
        result = bpy.data.images.new(f"Ferry material atlas - {name}", size, size, alpha=False)
        crop = array("f")
        for row in range(height - y - size, height - y):
            start = (row * width + x) * 4
            crop.extend(pixels[start:start + size * 4])
        result.pixels.foreach_set(crop)
        result.pack()
        images[name] = result
    bpy.data.images.remove(src)
    return images


ATLAS = atlas_images()
GRASS = material("Meadow and wildflowers", "7e8851", texture=ATLAS["Grass"])
FLAGSTONE = material("Weathered yellow stone", "ccb185", texture=ATLAS["Flagstone"])
TIMBER = material("Sawn ferry boards", "97714e", texture=ATLAS["Timber"])
STONE = palette("Limestone", "746f60 928873 a59a7d b8aa89 c4b391")
MOSS = palette("Stone moss", "677043 7a8148 8e8b4d")
CLAY = palette("Reed flat", "9c8b62 a5956c b19e71 b6a778")
SLATE = palette("Fired roof tile", "283f42 344b4d 3f5555 475a55 51615d 596662")
LIME = palette("Limewashed plaster", "d3c7a5 e3d6b7 c9bd99 b9ae8e")
WOOD = palette("Weathered fir", "4a3428 5b4131 715039 805c42 92704c a07b53")
BROWN = palette("Bark", "594833 6c583e 7c684a 8c7552")
LEAVES = palette("Willow leaf", "435c46 51714e 678153 7b955e 99a368 a1ac79")
BAMBOO = palette("Bamboo leaf", "3d5c4b 4c6c54 568063 6c8a5a 83956b")
REED = palette("Reed blade", "566c4a 647c4f 839057 9d9a58 b2a368")
WICKER = palette("Woven rush", "7c6542 9e7950 b18d5e c0a576")
POT = palette("Glazed stoneware", "344d4a 4e6460 607a6d 877245 805442", rough=.45)
CLOTH = palette("Rust silk", "824331 a44f37 c15e3e d17a46")
LANTERN = palette("Lantern paper", "bd6135 d48541 eca85c", emission=.19)
METAL = material("Oxidized bronze", "806940", rough=.48)
INK = material("Blackened fir", "2f3028")
GOLD = material("Ochre paint", "e6bd79")
FOAM = material("Reflected light at shore", "a1a88a", rough=.53)


class Mesh:
    """Collect an editable mesh, batching the many individual decorative pieces."""

    def __init__(self, name, group):
        self.name = name
        self.group = group
        self.vertices = []
        self.faces = []
        self.materials = []
        self.face_materials = []
        self.uvs = []
        self.smooth = []

    def add(self, vertices, faces, mat, uv=None, smooth=False):
        if mat not in self.materials:
            self.materials.append(mat)
        offset = len(self.vertices)
        self.vertices.extend(vertices)
        for face in faces:
            self.faces.append(tuple(offset + index for index in face))
            self.face_materials.append(self.materials.index(mat))
            self.uvs.extend(uv(vertices[index]) if uv else (0, 0) for index in face)
            self.smooth.append(smooth)

    def polygon(self, vertices, mat, uv=None):
        vectors = [Vector(point) for point in vertices]
        self.add(vertices, tessellate_polygon([vectors]), mat, uv)

    def finish(self):
        if not self.faces:
            return
        geometry = bpy.data.meshes.new(self.name)
        geometry.from_pydata(self.vertices, [], self.faces)
        for mat in self.materials:
            geometry.materials.append(mat)
        for polygon, index, smooth in zip(geometry.polygons, self.face_materials, self.smooth):
            polygon.material_index = index
            polygon.use_smooth = smooth
        if any(uv != (0, 0) for uv in self.uvs):
            geometry.uv_layers.new(name="UVMap").data.foreach_set(
                "uv", [component for coord in self.uvs for component in coord]
            )
        geometry.validate()
        geometry.update()
        obj = bpy.data.objects.new(self.name, geometry)
        self.group.objects.link(obj)
        return obj


def loops(mesh, rings, mat, cap=True, smooth=False, uv=None):
    sides = len(rings[0])
    vertices = [vertex for ring in rings for vertex in ring]
    faces = [(index * sides + side, index * sides + (side + 1) % sides,
              (index + 1) * sides + (side + 1) % sides, (index + 1) * sides + side)
             for index in range(len(rings) - 1) for side in range(sides)]
    if cap:
        faces += [tuple(reversed(range(sides))),
                  tuple(range((len(rings) - 1) * sides, len(rings) * sides))]
    mesh.add(vertices, faces, mat, uv=uv, smooth=smooth)


def tube(mesh, points, radii, mat, sides=7, cap=True, smooth=True):
    rings = []
    vectors = [Vector(point) for point in points]
    for i, (point, radius) in enumerate(zip(vectors, radii)):
        direction = (vectors[min(i + 1, len(vectors) - 1)] - vectors[max(0, i - 1)]).normalized()
        reference = Vector((0, 1, 0)) if abs(direction.y) < .82 else Vector((1, 0, 0))
        axis = reference.cross(direction).normalized()
        tangent = direction.cross(axis).normalized()
        rings.append([point + radius * (cos(2 * pi * n / sides) * axis
                                        + sin(2 * pi * n / sides) * tangent)
                      for n in range(sides)])
    loops(mesh, rings, mat, cap, smooth)


def lathe(mesh, x, y, z, profile, mat, sides=12, ratio=1.0, cap=True):
    rings = [[(x + radius * cos(2 * pi * i / sides), y + ratio * radius * sin(2 * pi * i / sides), z + h)
              for i in range(sides)] for radius, h in profile]
    loops(mesh, rings, mat, cap, True)


def stepped_prism(mesh, points, levels, mat, uv=None, side=None):
    center_x = sum(x for x, _ in points) / len(points)
    center_y = sum(y for _, y in points) / len(points)
    if sum(x * points[(i + 1) % len(points)][1] - y * points[(i + 1) % len(points)][0]
           for i, (x, y) in enumerate(points)) < 0:
        points = list(reversed(points))
    rings = [[(center_x + (x - center_x) * scale, center_y + (y - center_y) * scale, z)
              for x, y in points] for z, scale in levels]
    loops(mesh, rings, side or mat, False, uv=uv)
    mesh.polygon(rings[-1], mat, uv)


def block(mesh, center, size, mat, bevel=0, angle=0, uv=None):
    x, y, z = center
    width, depth, height = size
    pairs = [(-width / 2, -depth / 2), (width / 2, -depth / 2),
             (width / 2, depth / 2), (-width / 2, depth / 2)]
    points = [(x + px * cos(angle) - py * sin(angle), y + px * sin(angle) + py * cos(angle))
              for px, py in pairs]
    if bevel:
        scale = 1 - 2 * bevel / min(width, depth)
        levels = [(z - height / 2, scale), (z - height / 2 + bevel, 1),
                  (z + height / 2 - bevel, 1), (z + height / 2, scale)]
    else:
        levels = [(z - height / 2, 1), (z + height / 2, 1)]
    stepped_prism(mesh, points, levels, mat, uv)
    mesh.polygon([(px, py, z - height / 2) for px, py in reversed(points)], mat, uv)


def reed_leaf(mesh, points, width, mat):
    vertices = []
    for (x, y, z), factor in zip(points, (.19, 1, .69, .03)):
        nx = points[-1][1] - points[0][1]
        ny = points[0][0] - points[-1][0]
        length = max(.0001, (nx * nx + ny * ny) ** .5)
        vx, vy = nx / length * width * factor, ny / length * width * factor
        vertices.extend([(x + vx, y + vy, z), (x, y, z + width * .19), (x - vx, y - vy, z)])
    faces = [(i, i + 3, i + 4, i + 1) for i in (0, 3, 6)]
    faces += [(i + 1, i + 4, i + 5, i + 2) for i in (0, 3, 6)]
    mesh.add(vertices, faces, mat)


def rock(mesh, x, y, z, rx, ry, h, rng=RNG):
    count = rng.randint(5, 8)
    angle = rng.random() * pi
    ring = [(cos(angle + i * 2 * pi / count) * rng.uniform(.82, 1.16),
             sin(angle + i * 2 * pi / count) * rng.uniform(.8, 1.16))
            for i in range(count)]
    lean = (rng.uniform(-rx * .26, rx * .26), rng.uniform(-ry * .26, ry * .26))
    rings = []
    for scale, level in ((.8, 0), (1, .35), (.60, .84)):
        rings.append([(x + dx * rx * scale + lean[0] * level,
                       y + dy * ry * scale + lean[1] * level,
                       z + h * (level + rng.uniform(-.09, .09))) for dx, dy in ring])
    for ai, (lower, upper) in enumerate(zip(rings, rings[1:])):
        for index in range(count):
            ni = (index + 1) % count
            mesh.add([lower[index], lower[ni], upper[ni], upper[index]], [(0, 1, 2, 3)],
                     rng.choice(STONE[ai:ai + 3] + (MOSS[:1] if ai else [])))
    peak = (x + lean[0] * .8, y + lean[1] * .8, z + h)
    for index in range(count):
        mesh.add([rings[-1][index], rings[-1][(index + 1) % count], peak], [(0, 1, 2)],
                 rng.choice(STONE[2:] + MOSS))


# The bank includes every walkable cell apart from the wooden landing.
# Positive values in this outline are map row distances, negated below.
BANK_OUTLINE = [
    (.06, .48), (.54, .13), (1.25, -.02), (2.06, .13), (2.87, .28), (3.67, .14),
    (4.13, .24), (4.79, .14), (5.47, .34), (6.16, .27), (6.78, .46),
    (7.05, .90), (7.15, 1.47), (7.06, 2.02), (7.27, 2.49),
    (7.47, 2.86), (7.93, 3.03), (8.62, 3.00), (9.09, 3.0), (9.71, 3.03),
    (10.25, 2.97), (10.80, 3.07), (11.27, 3.18), (11.71, 3.49), (11.87, 4.06),
    (11.74, 4.64), (11.94, 5.13), (12.08, 5.64), (11.89, 6.18), (11.96, 6.70),
    (11.69, 7.21), (11.18, 7.45), (10.63, 7.51), (10.11, 7.71), (9.61, 7.70),
    (9.13, 7.96), (8.45, 7.92), (8.13, 8.02), (7.47, 7.92), (6.91, 8.06),
    (6.24, 7.94), (5.62, 8.03), (4.90, 7.84), (4.32, 7.96), (3.76, 7.86),
    (3.01, 7.93), (2.49, 7.70), (1.95, 7.79), (1.41, 7.65), (.83, 7.72),
    (.42, 7.37), (.19, 6.83), (.01, 6.47), (.08, 5.82), (-.06, 5.35),
    (.06, 4.75), (-.09, 4.10), (.09, 3.60), (.03, 3.03), (.17, 2.54),
    (.02, 2.05), (.17, 1.65), (.03, 1.13),
]


def bank():
    bank = Mesh("Continuous meadow", LAND)
    shore = Mesh("Limestone rubble and inlet ripples", LAND)
    coords = [(x, -row) for x, row in reversed(BANK_OUTLINE)]
    bank.polygon([(x, y, -.033) for x, y in coords], GRASS, lambda p: (p[0] / 2.8, p[1] / 2.8))
    rows = [[], [], [], [], []]
    distances = (0, .077, .166, .236, .32)
    elevations = (-.033, -.066, -.143, -.206, -.239)
    for i, (x, y) in enumerate(coords):
        prev = Vector(coords[i - 1])
        following = Vector(coords[(i + 1) % len(coords)])
        tangent = (following - prev).normalized()
        outward = Vector((tangent.y, -tangent.x))
        disturbance = RNG.uniform(.80, 1.39)
        for row, distance, altitude in zip(rows, distances, elevations):
            radius = distance * disturbance
            row.append((x + radius * outward.x, y + radius * outward.y,
                        altitude + (RNG.uniform(-.019, .017) if distance else 0)))
    graded_shore(rows)
    for i, point in enumerate(coords):
        if RNG.random() < .64:
            x, y, z = rows[2][i]
            for _ in range(RNG.randint(3, 6)):
                radius = RNG.uniform(.038, .123)
                rock(shore, x + RNG.uniform(-.16, .16), y + RNG.uniform(-.09, .09), z - .022,
                     radius, radius * RNG.uniform(.65, 1.2), radius * .46)
        if RNG.random() < .27:
            x, y, z = rows[-1][i]
            length = RNG.uniform(.07, .19)
            shore.polygon([(x - length, y, z + .012), (x, y - .014, z + .013),
                           (x + length, y - .027, z + .014), (x - .04, y - .009, z + .014)], FOAM)
    bank.finish()
    shore.finish()


def graded_shore(rows):
    material_color = material("Moss, exposed soil and submerged riverbank", "ffffff", rough=.64)
    attribute_name = "Shoreline pigments"
    nodes = material_color.node_tree.nodes
    attribute = nodes.new("ShaderNodeVertexColor")
    attribute.layer_name = attribute_name
    material_color.node_tree.links.new(attribute.outputs["Color"],
                                       nodes.get("Principled BSDF").inputs["Base Color"])
    count = len(rows[0])
    vertices = [vertex for row in rows for vertex in row]
    faces = [(row * count + i, (row + 1) * count + i,
              (row + 1) * count + (i + 1) % count, row * count + (i + 1) % count)
             for row in range(len(rows) - 1) for i in range(count)]
    mesh = bpy.data.meshes.new("Softly graded riverbank")
    mesh.from_pydata(vertices, [], faces)
    mesh.materials.append(material_color)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    pigments = mesh.color_attributes.new(name=attribute_name, type="FLOAT_COLOR", domain="POINT")
    hues = ("919064", "7b7c53", "746e50", "646d50", "738671")
    for row, hue in enumerate(hues):
        for i in range(count):
            intensity = RNG.uniform(.78, 1.18)
            pigments.data[row * count + i].color = (*(channel * intensity for channel in rgb(hue)), 1)
    mesh.update()
    LAND.objects.link(bpy.data.objects.new("Mossy bank blending into damp silt", mesh))


def stone_path():
    path = Mesh("Individually cut flagstones and grit", LAND)
    rectangles = [
        (1.16, 10.92, 3.10, 3.94),
        (1.16, 4.90, 2.13, 3.10),
        (2.25, 5.73, 1.24, 2.13),
        (2.13, 5.99, 3.94, 4.77),
        (2.22, 3.17, 4.77, 6.94),
        (7.17, 10.94, 3.94, 4.79),
        (7.36, 8.43, 4.79, 6.88),
        (8.32, 8.74, 2.95, 3.10),
    ]
    for left, right, start, end in rectangles:
        rows = round((end - start) / .41)
        rows = max(1, rows)
        depth = (end - start) / rows
        for row in range(rows):
            offset = start + row * depth
            x = left
            while x < right - .07:
                length = min(right - x, RNG.uniform(.34, .92))
                if right - (x + length) < .22:
                    length = right - x
                gap = RNG.uniform(.012, .039)
                x0, x1 = x + gap, x + length - gap
                y0, y1 = -offset - depth + gap, -offset - gap
                tilt = RNG.uniform(-.036, .036)
                chip = min(.06, (x1 - x0) * .18, (y1 - y0) * .18)
                corners = [(x0 + chip, y0 + tilt), (x1 - chip, y0),
                           (x1, y0 + chip), (x1 - chip * .25, y1 - chip + tilt),
                           (x1 - chip, y1 + tilt), (x0 + chip, y1),
                           (x0, y1 - chip), (x0 + tilt * .3, y0 + chip)]
                height = RNG.uniform(-.007, .016)
                u, v = RNG.random(), RNG.random()
                stepped_prism(path, corners, [(-.034, .88), (height - .014, 1), (height, .95)],
                              FLAGSTONE, lambda p, u=u, v=v: (u + p[0] * .32, v + p[1] * .36),
                              RNG.choice(STONE[1:4]))
                x += length
    for _ in range(114):
        x = RNG.uniform(1.1, 10.9)
        y = RNG.choice((-3.05, -3.99)) + RNG.uniform(-.075, .075)
        r = RNG.uniform(.012, .048)
        rock(path, x, y, -.026, r, r * .8, r * .55)
    path.finish()


def flats():
    mesh = Mesh("Exposed mud, patches of sand and gravel", LAND)
    islands = [(8.63, -5.72, 1.21, .32), (9.56, -6.14, 1.22, .54),
               (9.06, -6.77, 1.46, .21), (10.43, -5.41, 1.1, .39),
               (10.56, -6.73, .72, .46), (10.52, -3.38, .35, .23)]
    for x, y, rx, ry in islands:
        n = 23
        radius = [RNG.uniform(.85, 1.09) for _ in range(n)]
        outer = [(x + cos(2 * pi * i / n) * rx * radius[i], y + sin(2 * pi * i / n) * ry * radius[i], -.031)
                 for i in range(n)]
        inner = [(x + (a - x) * .89, y + (b - y) * .81, -.018) for a, b, _ in outer]
        for i in range(n):
            j = (i + 1) % n
            mesh.add([outer[i], outer[j], inner[j], inner[i]], [(0, 1, 2, 3)], RNG.choice(CLAY[:2]))
        mesh.polygon(inner, RNG.choice(CLAY[1:]))
        for _ in range(25):
            a = RNG.uniform(0, 2 * pi)
            radius = RNG.random() ** .5
            r = RNG.uniform(.009, .038)
            rock(mesh, x + cos(a) * rx * radius, y + sin(a) * ry * radius,
                 -.017, r, r * .65, r * RNG.uniform(.35, .65))
    mesh.finish()


def curved_roof(mesh, x, y, width, depth, crown, drop):
    """Build a two-slope tiled roof with tapered, upturned eaves."""
    half_w, half_d = width / 2, depth / 2

    def surface(along, slope, side, lift=0):
        corner = abs(along / half_w) ** 6
        height = crown - drop * (1.46 * slope - .46 * slope ** 2)
        height += corner * (.025 + .15 * slope ** 2) + .075 * slope ** 8
        return (x + along, y + side * half_d * slope, height + lift)

    columns = max(10, round(width / .081))
    courses = max(5, round(half_d / .092))
    spacing = width / columns
    for side in (-1, 1):
        for row in range(courses):
            v0 = row / courses
            v1 = (row + 1) / courses
            for i in range(columns):
                u0 = -half_w + i * spacing
                u1 = u0 + spacing
                mat = RNG.choices(SLATE, (2, 7, 9, 6, 4, 2))[0]
                under = [surface(u0, v0, side), surface(u1, v0, side),
                         surface(u1, v1, side), surface(u0, v1, side)]
                mesh.add(under, [(0, 1, 2, 3)] if side > 0 else [(0, 3, 2, 1)], SLATE[0])
                tile = []
                for v, edge in ((max(0, v0 - .038), 0), (v1, .013)):
                    for offset, height in ((.018, .006), (.30, .022), (.68, .018), (.975, .002)):
                        tile.append(surface(u0 + offset * spacing, v, side, height + edge))
                for n in range(3):
                    face = (n, n + 1, n + 5, n + 4)
                    mesh.add(tile, [face if side > 0 else tuple(reversed(face))], mat)
                lip = [surface(u0 + spacing * offset, v1, side, lift)
                       for offset, lift in ((.018, -.028), (.975, -.028), (.975, .014),
                                            (.68, .031), (.30, .035), (.018, .019))]
                mesh.polygon(lip if side < 0 else list(reversed(lip)), SLATE[1] if i % 2 else SLATE[3])
        eave = [surface(half_w * ((i - 12) / 12), 1, side, -.044) for i in range(25)]
        tube(mesh, eave, [.034] * 25, WOOD[0], sides=5)
        for end in (-1, 1):
            border = [surface(end * half_w, i / 13, side, .01) for i in range(14)]
            tube(mesh, border, [.042] * 14, SLATE[0], sides=7)
            finial = [surface(end * half_w, 1, side, .018),
                      (x + end * (half_w + .067), y + side * (half_d + .027), border[-1][2] + .052),
                      (x + end * (half_w + .123), y + side * (half_d + .06), border[-1][2] + .124),
                      (x + end * (half_w + .155), y + side * (half_d + .052), border[-1][2] + .152)]
            tube(mesh, finial, [.052, .046, .030, .005], SLATE[0], sides=7)
    ridge = [(x + half_w * t * 1.03, y, crown + .037 + .12 * abs(t) ** 10)
             for t in (i / 12 - 1 for i in range(25))]
    tube(mesh, ridge, [.055] * 25, SLATE[1], sides=9)
    for end in (-1, 1):
        pos = (x + end * half_w * 1.03, y, crown + .16)
        lathe(mesh, *pos, [(.055, 0), (.044, .047), (.02, .092), (.005, .134)], SLATE[0])


def stairs(mesh, x, front, width):
    for row, (depth, top) in enumerate(((.31, .065), (.23, .105), (.146, .147))):
        for panel in range(3):
            dx = width * (panel - 1) / 3
            block(mesh, (x + dx, front - depth / 2 + .008, top / 2),
                  (width / 3 - .009, depth, top + .01), STONE[2 + (row + panel) % 3], .014)


def window(mesh, x, y, z, width, height, warm=True):
    block(mesh, (x, y + .012, z), (width + .04, .082, height + .04), WOOD[0], .008)
    block(mesh, (x, y - .034, z), (width, .027, height),
          LANTERN[0] if warm else INK, .006)
    for ox in (-1, 1):
        block(mesh, (x + ox * width / 2, y - .055, z),
              (.040, .063, height + .06), WOOD[2], .009)
        block(mesh, (x, y - .057, z + ox * height / 2),
              (width + .095, .072, .046), WOOD[2], .009)
    for i in (-2, -1, 0, 1, 2):
        block(mesh, (x + i * width / 6, y - .058, z), (.011, .016, height), WOOD[1])
    for i in (-1, 0, 1):
        block(mesh, (x, y - .059, z + i * height / 5), (width, .018, .012), WOOD[1])
    block(mesh, (x, y - .073, z - height * .54), (width + .13, .102, .029), WOOD[3], .006)


def lantern(mesh, x, y, hang, scale=1):
    z = hang - .25 * scale
    tube(mesh, [(x, y, z + .163 * scale), (x, y, hang + .005)],
         [.006 * scale] * 2, INK, sides=5)
    lathe(mesh, x, y, z, [(s * scale, h * scale) for s, h in
          ((.022, 0), (.058, .012), (.078, .045), (.081, .095), (.067, .133), (.032, .153))],
          LANTERN[2], 12)
    for ring in (0, .148):
        lathe(mesh, x, y, z + ring * scale, [(.037 * scale, 0), (.036 * scale, .017 * scale)],
              WOOD[1], 10)
    for i in range(8):
        a = i * 2 * pi / 8
        ribs = [(x + s * scale * cos(a), y + s * scale * sin(a), z + h * scale)
                for s, h in ((.03, .007), (.063, .024), (.08, .070), (.081, .094), (.069, .129), (.032, .148))]
        tube(mesh, ribs, [.0038 * scale] * 6, CLOTH[2], 4)
    for i in (-1, 0, 1):
        tube(mesh, [(x, y, z), (x + i * .008 * scale, y + .012 * scale, z - .046 * scale)],
             [.003 * scale, .002 * scale], CLOTH[2], sides=4)


def jar(mesh, x, y, z, size, mat):
    body = [(.34, 0), (.42, .05), (.53, .24), (.52, .53), (.43, .72), (.28, .82),
            (.29, .91), (.37, .93), (.37, 1), (.25, 1), (.24, .90), (.25, .84)]
    lathe(mesh, x, y, z, [(radius * size, h * size) for radius, h in body], mat, 12, cap=False)
    lathe(mesh, x, y, z + size * .834, [(.247 * size, 0), (.247 * size, .007)], INK, 12)
    for h in (.21, .28):
        lathe(mesh, x, y, z + h * size, [(.527 * size, 0), (.53 * size, .022 * size)], POT[1], 12)


def basket(mesh, x, y, z, size):
    lathe(mesh, x, y, z, [(size * r, size * h) for r, h in
          ((.38, 0), (.42, .05), (.52, .42), (.56, .65), (.48, .67), (.46, .61), (.32, .07))],
          WICKER[0], 14, cap=False)
    for i in range(7):
        h = (.04 + .10 * i) * size
        r = (.42 + .022 * i) * size
        lathe(mesh, x, y, z + h, [(r, 0), (r + .023 * size, .026 * size),
                                   (r + .018 * size, .050 * size)], WICKER[(i % 3) + 1], 14, cap=False)
    for i in range(12):
        a = 2 * pi * i / 12
        points = [(x + cos(a) * size * r, y + sin(a) * size * r, z + size * h)
                  for r, h in ((.418, .03), (.502, .42), (.559, .65))]
        tube(mesh, points, [.016 * size] * 3, WICKER[1], sides=4)


def textured_board(mesh, x, y, z, width, depth, height, angle=0):
    y_offset = RNG.uniform(0, 1)
    direction_x, direction_y = cos(angle), sin(angle)

    def uv(point):
        dx, dy, _ = Vector(point) - Vector((x, y, z))
        return ((dx * direction_x + dy * direction_y) * 1.6,
                y_offset + (dy * direction_x - dx * direction_y) * .79)

    block(mesh, (x, y, z), (width, depth, height), TIMBER, min(.009, height * .24), angle, uv)


def sign_lettering(group, x, y, z):
    source = Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts" / "msyhbd.ttc"
    if not source.exists():
        return
    lettering = bpy.data.curves.new("Creek Bridge Inn characters", "FONT")
    lettering.body = "溪桥客栈"
    lettering.font = bpy.data.fonts.load(str(source))
    lettering.align_x = "CENTER"
    lettering.align_y = "CENTER"
    lettering.size = .115
    lettering.extrude = .0009
    lettering.materials.append(GOLD)
    obj = bpy.data.objects.new("Gold-painted inn sign", lettering)
    group.objects.link(obj)
    obj.location = (x, y, z)
    obj.rotation_euler.x = pi / 2
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.convert(target="MESH")
    obj.select_set(False)


def inn():
    walls = Mesh("Inn stone plinth, plaster and timber frame", INN)
    lattice = Mesh("Shutters, balustrades and herb shop", INN)
    roofing = Mesh("Inn swept barrel-tile gables and porch canopy", INN)
    furn = Mesh("Inn paper lanterns, pottery and shopfront", INN)
    x, y, width, depth = 1.12, -.90, 1.56, 1.38
    front = y - depth / 2
    base, story, beam, wall_top = .138, .98, 1.08, 1.82

    block(walls, (x, y - .043, base / 2), (width + .15, depth + .18, base), STONE[1], .029)
    block(walls, (x, y - .05, base - .005), (width + .176, depth + .194, .051), STONE[3], .013)
    for side in (-1, 1):
        side_x = x + side * width / 2
        block(walls, (side_x, y, (base + wall_top) / 2),
              (.072, depth, wall_top - base), LIME[0 if side > 0 else 2], .018)
        walls.polygon([(side_x, y - depth / 2, wall_top - .033),
                       (side_x, y + depth / 2, wall_top - .033), (side_x, y, 2.30)], LIME[0])
        for i in range(12):
            width_of_cut = RNG.uniform(.088, .15)
            block(walls, (side_x + side * .042, y - depth * .48 + i * depth / 12, .25),
                  (.035, width_of_cut, RNG.uniform(.08, .13)), STONE[(i % 3) + 1], .011)
        for i in range(2):
            s_y = y + .24 - i * .40
            block(walls, (side_x + side * .045, s_y, 1.39), (.028, .18, .21), WOOD[0], .007)
            for n in (-1, 1):
                block(walls, (side_x + side * .066, s_y + n * .044, 1.39),
                      (.028, .013, .177), WOOD[4])
        for i in range(32):
            py = y + RNG.uniform(-.65, .65)
            z = RNG.uniform(.31, .47) if i < 22 else RNG.uniform(1.67, 1.81)
            block(walls, (side_x + side * .036, py, z),
                  (.008, RNG.uniform(.026, .107), RNG.uniform(.015, .036)), RNG.choice(LIME[2:]))

    block(walls, (x, y + depth / 2, (base + wall_top) / 2),
          (width, .082, wall_top - base), LIME[2])
    block(walls, (x, front + .065, 1.46), (width, .112, .73), LIME[1], .012)
    for post_x in (x - width / 2, x - .303, x + .304, x + width / 2):
        for post_y in (front - .035, y + depth / 2):
            block(walls, (post_x, post_y, .98), (.084, .083, 1.70), WOOD[1], .010)
            block(walls, (post_x, post_y, .207), (.113, .112, .102), STONE[2], .012)
    for z in (.20, .966, 1.14, 1.75):
        block(walls, (x, front - .038, z), (width + .103, .092, .063), WOOD[1], .010)
    for i in range(14):
        px = x - width / 2 + .063 + i * .108
        textured_board(lattice, px, y - depth / 2 - .14, .152, .293, .101, .041, angle=pi / 2)
    stairs(walls, x, front - .265, .64)
    for side in (-1, 1):
        wing = x + side * .525
        block(lattice, (wing, front + .04, .579), (.402, .074, .710), WOOD[0], .009)
        for i in range(6):
            plank_x = wing + (i - 2.5) * .064
            block(lattice, (plank_x, front - .011, .334), (.056, .041, .235),
                  WOOD[2 + (i % 3)], .006)
        window(lattice, wing, front - .016, .674, .316, .368)
        window(lattice, wing, front - .088, 1.433, .316, .385, warm=side > 0)
        lantern(furn, wing + side * .158, front - .234, .925, .87)
    block(lattice, (x, front + .19, .55), (.49, .073, .697), INK)
    for side in (-1, 1):
        planks_x = x + .22 * side
        for i in range(4):
            block(lattice, (planks_x + (i - 1.5) * .033, front + .065, .534),
                  (.031, .046, .622), WOOD[2 + (i % 3)], .004)
        block(lattice, (x + side * .16, front + .036, .63), (.035, .024, .04), METAL, .007)
    for i in range(6):
        px = x + (i - 2.5) * .28
        block(lattice, (px, front - .105, 1.21), (.037, .031, .162), WOOD[3], .005)
    block(lattice, (x, front - .128, 1.297), (width + .034, .043, .031), WOOD[2], .006)
    window(lattice, x, front - .079, 1.445, .30, .383, warm=True)

    curved_roof(roofing, x, y, 1.97, 1.86, 2.34, .59)
    curved_roof(roofing, x, front + .155, 1.92, .99, 1.21, .25)
    for i in range(9):
        rafter_x = x + (i - 4) * .194
        block(roofing, (rafter_x, front - .273, .987), (.039, .245, .035), WOOD[0], .007)
    block(lattice, (x, front - .153, .911), (.59, .051, .144), WOOD[4], .014)
    block(lattice, (x, front - .184, .911), (.555, .035, .12), INK, .012)
    sign_lettering(INN, x, front - .205, .913)
    for i, offset in enumerate((-.73, -.57, .56, .71)):
        jar(furn, x + offset, front - (.19 + .045 * (i % 2)), .168,
            .16 + .038 * (i % 2), POT[(i + 1) % 5])
    basket(furn, x + .81, front - .26, -.02, .196)
    for i in range(5):
        px = x - .63 + i * .084
        ends = [(px, front - .20, .835), (px, front - .214, .714)]
        tube(furn, ends, [.005, .004], WICKER[1], sides=4)
        for j in range(3):
            dy = .019 * (j - 1)
            pts = [(px, front - .214, .735), (px + dy * .45, front - .223, .722),
                   (px + dy * .8, front - .241, .701), (px + dy, front - .248, .690)]
            reed_leaf(furn, pts, .012, BROWN[2 + j % 2])
    for mesh in (walls, lattice, roofing, furn):
        mesh.finish()


def boathouse():
    walls = Mesh("Boathouse stone sill and boarded timber siding", BOAT)
    roofing = Mesh("Boathouse fired tile gable and reed awning", BOAT)
    tools = Mesh("Net frame, drying float line, lantern and casks", BOAT)
    x, y, width, depth = 6.49, -1.065, .85, 1.11
    front = y - depth / 2
    block(walls, (x, y - .063, .052), (width + .138, depth + .17, .145), STONE[2], .016)
    block(walls, (x, y, .527), (width - .030, depth - .020, .86), INK)
    for side in (-1, 1):
        xx = x + side * width / 2
        for i in range(11):
            yy = y + (i - 5) * .099
            h = RNG.uniform(.79, .90)
            block(walls, (xx, yy, h / 2 + .102), (.048, .096, h), RNG.choice(WOOD[1:]), .008)
        walls.polygon([(xx, y - depth / 2, .936), (xx, y + depth / 2, .936), (xx, y, 1.435)],
                      WOOD[2])
        for i in range(5):
            yy = y + (i - 2) * .15
            block(walls, (xx + side * .006, yy, 1.043), (.019, .093, .213), WOOD[2 + i % 3])
        for yy in (front, y + depth / 2):
            block(walls, (xx, yy, .576), (.073, .071, .972), WOOD[1], .007)
    for i in range(8):
        xx = x + (i - 3.5) * .105
        block(walls, (xx, front, .53), (.100, .054, .822), WOOD[2 + (i % 4)], .007)
    for z in (.208, .526, .92):
        block(walls, (x, front - .029, z), (width + .055, .044, .054), WOOD[1], .009)
    block(walls, (x - .196, front - .037, .50), (.266, .028, .62), WOOD[1], .005)
    for i in range(3):
        block(walls, (x - .192 + (i - 1) * .079, front - .062, .491), (.071, .027, .586),
              WOOD[2 + i], .005)
    block(walls, (x - .112, front - .085, .499), (.028, .017, .048), METAL, .004)
    window(walls, x + .22, front - .019, .625, .203, .248)
    stairs(walls, x - .20, front - .032, .31)
    curved_roof(roofing, x, y, 1.139, 1.45, 1.427, .47)
    for i in range(22):
        xx = x + (i - 10.5) * .048
        cube_z = 1 + .017 * abs(xx - x)
        tube(roofing, [(xx, front + .012, cube_z), (xx, front - .135, cube_z - .089),
                       (xx, front - .292, cube_z - .116 - RNG.uniform(0, .064))],
             [.019, .019, .012], WICKER[1 + i % 3], sides=5)
    tube(roofing, [(x - .53, front - .273, .849), (x + .53, front - .273, .849)],
         [.022, .022], WOOD[2], sides=6)
    lantern(tools, x - .383, front - .268, .836, .7)
    jar(tools, x + .452, front - .13, -.029, .208, POT[0])
    basket(tools, x + .29, front - .16, .075, .148)
    basket(tools, x + .576, front - .038, -.025, .151)
    for side in (-1, 1):
        xx = x + .014 + side * .159
        tube(tools, [(xx, y - .068, .107), (xx, y - .068, .574)],
             [.020, .014], WOOD[3], sides=6)
    for i in range(6):
        u = i / 5
        xx = x - .145 + u * .318
        yy = front + .789
        h = .877 - .063 * sin(pi * u)
        lathe(tools, xx, yy, h, [(.014, 0), (.023, .023), (.013, .039)], POT[(i + 2) % 5], 6)
    tube(tools, [(x - .18 + i * .064, front + .789, .92 - .063 * sin(pi * i / 6))
                 for i in range(7)], [.0034] * 7, WICKER[1], sides=4)
    for mesh in (walls, roofing, tools):
        mesh.finish()


def rope_coil(mesh, x, y, z, radius, mat):
    points = []
    for i in range(31):
        t = i / 30
        angle = t * 5 * pi
        r = radius * (1 - .66 * t)
        points.append((x + cos(angle) * r, y + sin(angle) * r * .72, z + t * .012))
    tube(mesh, points, [.007] * len(points), mat, sides=5)


def landing():
    dock = Mesh("Ferry landing planks, pilings and mooring rope", BOAT)
    skiff = Mesh("Open timber skiff, oar and straw hamper", BOAT)
    block(dock, (8.50, -2.335, -.055), (.92, 1.32, .031), WOOD[0], .006)
    for i in range(13):
        y = -1.69 - i * .108
        x = 8.50 + RNG.uniform(-.022, .022)
        textured_board(dock, x, y, -.020 + RNG.uniform(-.006, .004),
                       1.025 + RNG.uniform(-.033, .045), .103, .062, RNG.uniform(-.016, .016))
        for n in (-1, 1):
            lathe(dock, x + n * .442, y, .012, [(.013, -.005), (.009, .003)], METAL, sides=6)
    for x in (8.06, 8.94):
        block(dock, (x, -2.27, -.126), (.118, 1.41, .116), WOOD[0], .016)
        for n, y in enumerate((-1.67, -2.29, -2.85)):
            h = .282 - (n == 1) * .157
            tube(dock, [(x, y, -.35), (x + .011, y + .006, -.067), (x + .018, y, h)],
                 [.053, .058, .048], WOOD[1 + n], sides=8)
            if n == 1:
                continue
            for ring in range(3):
                z = h - .080 + .014 * ring
                lathe(dock, x + .013, y, z, [(.052, 0), (.057, .007), (.053, .013)],
                      WICKER[ring], 9)
    rope_coil(dock, 8.71, -1.89, .016, .105, WICKER[2])
    tube(dock, [(8.955, -1.683, .213), (9.072, -1.618, .129),
                (9.169, -1.514, -.052), (9.292, -1.394, -.041)],
         [.009] * 4, WICKER[2], sides=6)

    angle = -.23
    bx, by = 9.91, -1.28
    sin_angle, cos_angle = sin(angle), cos(angle)

    def to_skiff(x, y, z):
        return (bx + x * cos_angle - y * sin_angle, by + x * sin_angle + y * cos_angle, z)

    count = 24
    rings = []
    for length, breadth, level, swoop in (
            (.55, .159, -.29, .060), (.69, .243, -.206, .095),
            (.749, .277, -.063, .130), (.731, .229, -.067, .123),
            (.518, .164, -.214, .089)):
        rings.append([to_skiff(length * cos(t), breadth * sin(t) * (.72 + .28 * abs(sin(t))),
                              level + swoop * abs(cos(t)) ** 5)
                      for t in (2 * pi * i / count for i in range(count))])
    for level, (lower, upper) in enumerate(zip(rings, rings[1:])):
        for i in range(count):
            ni = (i + 1) % count
            skiff.add([lower[i], lower[ni], upper[ni], upper[i]], [(0, 1, 2, 3)],
                      WOOD[level + 1 + int(i % 4 == 0)])
    skiff.polygon(rings[-1], WOOD[1])
    tube(skiff, rings[2] + rings[2][:1], [.022] * (count + 1), WOOD[1], sides=6)
    for xx in (-.43, -.21, .02, .25, .44):
        x, y, z = to_skiff(xx, .0, -.064)
        textured_board(skiff, x, y, z, .44 - abs(xx) * .235, .108, .039, angle + pi / 2)
    start = to_skiff(-.55, -.096, -.021)
    end = to_skiff(.56, .12, .001)
    tube(skiff, [start, end], [.018, .012], WOOD[4], sides=5)
    skiff.polygon([to_skiff(x, y, .001) for x, y in
                   ((.42, .084), (.55, .082), (.59, .108), (.57, .17), (.44, .14))], WOOD[4])
    basket(skiff, *to_skiff(.326, -.072, -.062), .16)
    dock.finish()
    skiff.finish()


def medicine_chest():
    mesh = Mesh("Empty medicine chest with open hinged lid", DETAIL)
    x, y = 8.5, -4.5
    w, d, h = .36, .256, .142
    x0, x1, y0, y1 = x - w / 2, x + w / 2, y - d / 2, y + d / 2
    block(mesh, (x, y, .026), (w, d, .054), WOOD[1], .009)
    for row in range(2):
        z = .057 + row * .047
        for yy in (y0, y1):
            block(mesh, (x, yy, z), (w, .025, .048), WOOD[2 + row], .005)
        for xx in (x0, x1):
            block(mesh, (xx, y, z), (.027, d, .048), WOOD[3 + row], .005)
    for xx in (x0, x1):
        for yy in (y0, y1):
            block(mesh, (xx, yy, .079), (.040, .037, .138), WOOD[4], .006)
    for i in range(4):
        h0, h1 = i * .052, (i + 1) * .052 - .004
        shell = [(x0, y1 + h0 * .38, h + h0), (x1, y1 + h0 * .38, h + h0),
                 (x1, y1 + h1 * .38, h + h1), (x0, y1 + h1 * .38, h + h1)]
        mesh.add(shell, [(0, 1, 2, 3), (3, 2, 1, 0)], WOOD[2 + (i % 3)])
    for dx in (-.119, .119):
        tube(mesh, [(x + dx, y1 - .008, .129), (x + dx, y1 + .028, h + .075),
                    (x + dx, y1 + .083, h + .207)], [.014, .013, .010], METAL, sides=5)
    block(mesh, (x, y0 - .019, .100), (.047, .018, .041), METAL, .006)
    tube(mesh, [(8.668, -4.691, .016), (8.773, -4.715, .016), (8.822, -4.678, .032)],
         [.006, .007, .006], WICKER[1], 4)
    rope_coil(mesh, 8.727, -4.686, .016, .07, WICKER[0])
    mesh.finish()


def willow(x, y, height, lean, label):
    bark = Mesh(f"{label} willow - exposed roots and winding branches", VEGETATION)
    leaves = Mesh(f"{label} willow - fine pendulous leaves", VEGETATION)
    xlean, ylean = lean

    def at(dx, dy, dz):
        return (x + (dx + xlean * dz) * height, y + (dy + ylean * dz) * height, dz * height)

    trunk = [at(*point) for point in ((0, 0, -.013), (-.053, .017, .120), (-.037, .030, .269),
                                    (.024, .014, .424), (.058, .029, .564), (.020, .054, .687),
                                    (.036, .074, .802))]
    tube(bark, trunk, [height * r for r in (.115, .092, .072, .061, .049, .032, .008)],
         BROWN[1], sides=9)
    for i in range(6):
        a = i * pi / 3 + RNG.uniform(-.26, .26)
        ux, uy = cos(a), sin(a)
        roots = [(x + ux * d * height, y + uy * d * height, z * height)
                 for d, z in ((.029, .094), (.096, .059), (.198, .018), (.274, -.023))]
        tube(bark, roots, [height * r for r in (.052, .037, .017, .003)],
             BROWN[(i + 1) % 4], sides=6)
    for i in range(11):
        a = i * 2 * pi / 11 + RNG.uniform(-.24, .24)
        ux, uy = cos(a), sin(a)
        extension = RNG.uniform(.26, .43)
        altitude = RNG.uniform(.74, .98)
        mid = RNG.uniform(.480, .647)
        anchors = [at(.05, .039, mid), at(ux * .13, uy * .12, mid + .106),
                   at(ux * extension * .79, uy * extension * .81, altitude),
                   at(ux * extension, uy * extension, altitude - .024)]
        tube(bark, anchors, [height * r for r in (.046, .030, .014, .004)],
             BROWN[(i + 1) % 4], sides=6)
        for j in range(11):
            t = j / 11
            k = RNG.uniform(-.125, .125)
            start = Vector(at(ux * extension * (.47 + t * .56) - uy * k * .64,
                              uy * extension * (.47 + t * .56) + ux * k * .64,
                              altitude - .05 * sin(pi * t) + RNG.uniform(-.044, .04)))
            reach = RNG.uniform(.038, .118) * height
            drop = RNG.uniform(.17, .51) * height
            tr = Vector((ux * reach - uy * k * .48, uy * reach + ux * k * .48, 0))
            stem = [start, start + tr * .67 + Vector((0, 0, .029)),
                    start + tr + Vector((0, 0, -drop * .24)),
                    start + tr * 1.13 + Vector((0, 0, -drop * .64)),
                    start + tr * 1.09 + Vector((0, 0, -drop))]
            tube(bark, stem, [height * r for r in (.0045, .0039, .0032, .0029, .0012)],
                 REED[1], sides=4, cap=False)
            for idx in range(13):
                pct = idx / 13 * 3.99
                taper = 1 - idx / 23
                index = int(pct)
                start_leaf = stem[index].lerp(stem[index + 1], pct - index)
                span = RNG.uniform(.038, .082) * height * taper
                angle = RNG.uniform(0, 2 * pi)
                shift = Vector((cos(angle) * span, sin(angle) * span, -span * .69))
                blade = [start_leaf, start_leaf + shift * .43,
                         start_leaf + shift * .79 + Vector((0, 0, -span * .24)),
                         start_leaf + shift + Vector((0, 0, -span * .51))]
                reed_leaf(leaves, blade, RNG.uniform(.006, .014) * height * taper,
                          RNG.choices(LEAVES, (3, 4, 6, 5, 4, 2))[0])
    bark.finish()
    leaves.finish()


def grasses(mesh, x, y, height, count, kind=REED, z=-.021):
    for _ in range(count):
        a = RNG.uniform(0, 2 * pi)
        ux, uy = cos(a), sin(a)
        reach = RNG.uniform(.12, .64) * height
        h = RNG.uniform(.37, 1) * height
        mx = x + RNG.uniform(-.08, .08) * height
        my = y + RNG.uniform(-.08, .08) * height
        blade = [(mx, my, z), (mx + ux * reach * .15, my + uy * reach * .15, z + h * .43),
                 (mx + ux * reach * .48, my + uy * reach * .48, z + h * .79),
                 (mx + ux * reach, my + uy * reach, z + h * .94)]
        reed_leaf(mesh, blade, RNG.uniform(.035, .086) * height, RNG.choice(kind))


def cattail(mesh, x, y, z, height):
    rx, ry = RNG.uniform(-.122, .115), RNG.uniform(-.088, .115)
    middle = (x + rx * .34, y + ry * .34, z + height * .49)
    tuft = (x + rx, y + ry, z + height)
    tube(mesh, [(x, y, z), middle, tuft], [.009, .007, .004], REED[1], sides=4)
    end = (tuft[0] + rx * .13, tuft[1] + ry * .13, tuft[2] + height * .098)
    tube(mesh, [Vector(middle).lerp(Vector(tuft), .88), tuft, end], [.011, .028, .006],
         WICKER[1], sides=6)
    for i in range(4):
        dx, dy = RNG.uniform(-.057, .057), RNG.uniform(-.057, .057)
        tube(mesh, [tuft, (end[0] + dx, end[1] + dy, end[2] + height * .04)],
             [.0043, .0012], WICKER[2 + i % 2], sides=4)


def bamboo(mesh, x, y, high, z=-.025):
    for i in range(5):
        alt = RNG.uniform(.77, 1.08) * high
        dx, dy = RNG.uniform(-.21, .22) * high, RNG.uniform(-.17, .17) * high
        px, py = x + RNG.uniform(-.094, .094), y + RNG.uniform(-.090, .090)
        pole = [(px + dx * (n / 6) ** 1.21, py + dy * (n / 6) ** 1.21, z + alt * n / 6)
                for n in range(7)]
        radii = [(1 - n / 10) * .029 * high for n in range(7)]
        tube(mesh, pole, radii, BAMBOO[2 + i % 3], sides=6)
        for n, joint in enumerate(pole[1:-1], 1):
            r = radii[n]
            lathe(mesh, *joint, [(r * 1.25, 0), (r * 1.14, .015 * high)], BAMBOO[0], 7)
            if n < 2:
                continue
            for _ in range(3):
                a = RNG.uniform(0, 2 * pi)
                ux, uy = cos(a), sin(a)
                span = RNG.uniform(.085, .19) * high
                end = (joint[0] + ux * span, joint[1] + uy * span, joint[2] + span * .73)
                tube(mesh, [joint, end], [.005, .003], BAMBOO[2], sides=4)
                for _ in range(4):
                    aa = a + RNG.uniform(-1.3, 1.3)
                    ux2, uy2 = cos(aa), sin(aa)
                    l = RNG.uniform(.075, .17) * high
                    leaf = [(end[0] + s * ux2 * l, end[1] + s * uy2 * l,
                             end[2] + l * ((1 - s) * s - .21 * s)) for s in (0, .36, .69, 1)]
                    reed_leaf(mesh, leaf, .021 * high, RNG.choice(BAMBOO))


def landscape():
    stones = Mesh("Weathered shoreline stones and mossy outcrops", VEGETATION)
    greens = Mesh("Jointed bamboo, meadow blades and foxtail reeds", VEGETATION)
    flowers = Mesh("Wild orchids, tiny white blooms and lily pads", VEGETATION)
    accents = [(0.43, -4.74, .38, .28, .25), (5.56, -5.68, .38, .37, .27),
               (5.51, -5.19, .28, .21, .20), (.63, -6.92, .35, .24, .27),
               (2.86, -7.52, .31, .19, .17), (3.32, -7.21, .26, .22, .19),
               (11.62, -6.43, .33, .38, .24), (11.69, -4.86, .32, .27, .19),
               (7.16, -2.29, .28, .20, .19), (4.45, -.46, .35, .20, .22),
               (5.87, -.65, .38, .31, .23), (10.91, -7.37, .35, .25, .19)]
    for x, y, rx, ry, h in accents:
        rock(stones, x, y, -.024, rx, ry, h)
        for _ in range(7):
            radius = RNG.uniform(.025, .112)
            a = RNG.uniform(0, 2 * pi)
            dx, dy = cos(a) * rx * 1.2, sin(a) * ry * 1.2
            rock(stones, x + dx, y + dy, -.03, radius, radius * .8, radius * .76)
        for n in range(4):
            a = n * pi / 2 + RNG.uniform(0, .5)
            grasses(greens, x + cos(a) * rx * 1.20, y + sin(a) * ry * 1.14, .16, 9)
    for x, y, h in ((.33, -3.85, .93), (.26, -5.26, 1.0), (5.45, -5.54, 1.08),
                    (5.62, -5.93, .74), (6.64, -.53, .94), (2.81, -7.67, .62),
                    (7.26, -7.62, .84), (11.75, -5.76, .74), (.42, -1.99, .70)):
        bamboo(greens, x, y, h)
    for x, y, z, size in ((11.20, -5.29, -.02, .69), (11.62, -5.52, -.022, .80),
                           (11.28, -6.45, -.021, .67), (10.73, -6.89, -.02, .32),
                           (10.31, -7.23, -.022, .56), (9.85, -7.48, -.028, .39),
                           (11.91, -5.37, -.123, .52), (11.98, -5.88, -.102, .61),
                           (11.93, -5.13, -.096, .53), (11.83, -4.97, -.149, .53),
                           (11.31, -3.39, -.024, .46), (11.42, -3.22, -.114, .54),
                           (11.14, -3.11, -.094, .51), (10.84, -3.05, -.108, .27),
                           (7.37, -2.71, -.104, .38), (8.05, -2.87, -.080, .32),
                           (6.16, -7.80, -.038, .31), (.161, -5.79, -.155, .42),
                           (.51, -7.4, -.121, .36), (3.85, -7.88, -.119, .31)):
        grasses(greens, x, y, size * .66, 17, z=z)
        for i in range(8):
            cattail(greens, x + RNG.uniform(-.17, .17), y + RNG.uniform(-.16, .16),
                    z, size * RNG.uniform(.53, 1.01))
    for _ in range(235):
        x, y = RNG.uniform(.28, 11.75), RNG.uniform(-7.74, -.23)
        if (x > 7 and y > -3.25) or (x > 10.6 and y < -7.07):
            continue
        if (1.00 < x < 10.99 and -4.86 < y < -2.11) or (2.12 < x < 6 and y > -2.3):
            continue
        if (2.15 < x < 3.22 or 7.25 < x < 8.46) and -7 < y < -4.7:
            continue
        height = RNG.uniform(.038, .138)
        grasses(greens, x, y, height, RNG.randint(4, 8))
        if RNG.random() < .26:
            for i in range(3):
                xx = x + RNG.uniform(-.046, .046)
                yy = y + RNG.uniform(-.047, .047)
                head = height * RNG.uniform(.71, 1.24)
                tube(flowers, [(x, y, -.025), (xx, yy, head)], [.0029, .0023], REED[2], sides=4)
                lathe(flowers, xx, yy, head, [(.004, 0), (.013, .006), (.007, .011)],
                      LIME[1] if i < 2 else GOLD, 5, ratio=.79)
    for x, y in ((9.96, -2.44), (10.25, -2.56), (10.42, -2.44), (7.53, -1.11),
                 (7.66, -1.39), (10.77, -2.67), (.44, -7.66), (.32, -7.56)):
        rx = RNG.uniform(.064, .135)
        pad = [(x + cos(2 * pi * n / 12) * rx, y + sin(2 * pi * n / 12) * rx * .79, -.233)
               for n in range(1, 12)]
        pad.append((x, y, -.231))
        flowers.polygon(pad, RNG.choice(LEAVES[1:4]))
        if RNG.random() < .40:
            lathe(flowers, x - .032, y, -.233, [(.014, 0), (.027, .018), (.024, .041),
                                                (.009, .045)], LIME[1], 6)
    willow(.62, -6.52, 1.77, (-.090, -.069), "West bank")
    willow(11.62, -6.92, 1.58, (.122, -.147), "Reed bank")
    stones.finish()
    greens.finish()
    flowers.finish()


def preview_rig():
    def aim(obj, point):
        obj.rotation_euler = (Vector(point) - obj.location).to_track_quat("-Z", "Y").to_euler()

    subject = (5.72, -4.02, .57)
    camera = bpy.data.objects.new("Orthographic play camera", bpy.data.cameras.new("Ferry orthographic"))
    STUDIO.objects.link(camera)
    camera.location = Vector(subject) + Vector((.63, -1, .738)) * 12
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = 16.20
    aim(camera, subject)
    SCENE.camera = camera

    lights = (
        ("Soft sun over west bank", "SUN", (-3, -4, 10), (6, -4, 0), "fff2d7", 2.15, .145),
        ("Pale jade fill from river", "AREA", (8, -10, 7), (6, -3, 0), "c2e3df", 620, 11),
        ("Cool reflection behind roofs", "AREA", (6, 4, 8), (6, -4, 0), "dfedcd", 470, 8),
    )
    for name, kind, pos, target, color, energy, dimensions in lights:
        lamp = bpy.data.lights.new(name, type=kind)
        lamp.energy = energy
        lamp.color = rgb(color)
        if kind == "SUN":
            lamp.angle = dimensions
        else:
            lamp.shape = "DISK"
            lamp.size = dimensions
        obj = bpy.data.objects.new(name, lamp)
        STUDIO.objects.link(obj)
        obj.location = pos
        aim(obj, target)

    SCENE.world = bpy.data.worlds.new("Soft jade ambience")
    SCENE.world.use_nodes = True
    background = SCENE.world.node_tree.nodes.get("Background")
    background.inputs["Color"].default_value = (*rgb("819d88"), 1)
    background.inputs["Strength"].default_value = .58
    SCENE.render.engine = "BLENDER_EEVEE_NEXT"
    SCENE.eevee.taa_render_samples = 24
    SCENE.render.resolution_x = 1400
    SCENE.render.resolution_y = 850
    SCENE.render.resolution_percentage = 100
    SCENE.render.film_transparent = True
    SCENE.render.image_settings.file_format = "PNG"
    SCENE.view_settings.view_transform = "AgX"
    SCENE.view_settings.look = "AgX - Medium High Contrast"
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                space = area.spaces.active
                space.overlay.show_floor = False
                space.overlay.show_axis_x = False
                space.overlay.show_axis_y = False
                space.shading.color_type = "MATERIAL"
                space.region_3d.view_distance = 17.5
                space.region_3d.view_location = Vector(subject)
                space.region_3d.view_rotation = camera.rotation_euler.to_quaternion()
                space.region_3d.view_perspective = "ORTHO"


def main():
    bank()
    stone_path()
    flats()
    inn()
    boathouse()
    landing()
    medicine_chest()
    landscape()
    preview_rig()
    SCENE["Tile rule"] = "Blender center: (column - 0.5, 0.5 - row, 0)."
    SCENE["Texture source"] = "Original project art at client/assets/ferry-materials.png, packed as three material crops."
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE), compress=True)
    for obj in SCENE.objects:
        obj.select_set(obj.type == "MESH" and STUDIO not in obj.users_collection)
    EXPORT.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(EXPORT),
        export_format="GLB",
        export_yup=True,
        use_selection=True,
        export_lights=False,
        export_cameras=False,
        export_animations=False,
    )
    if "--preview" in sys.argv:
        SCENE.render.filepath = str(Path(os.environ["TEMP"]) / "ferry-blender-preview.png")
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()

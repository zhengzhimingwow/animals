extends RefCounted
## The server uses one-based coordinates. Project tile corners from zero-based edges.

const COLUMN := Vector2(1.0, 0.3276)
const ROW := Vector2(-0.63, 0.52)
const OUTSIDE := Vector2i(-1, -1)

static func fit(viewport: Vector2, dimensions: Vector2i) -> Transform2D:
    var extent := Vector2(dimensions) * Vector2(COLUMN.x, ROW.y)
    extent.x -= ROW.x * dimensions.y
    extent.y += COLUMN.y * dimensions.x
    var padded := extent + Vector2(0.50, 2.50)
    var unit := maxf(1.0, minf((viewport.x - 26.0) / padded.x, (viewport.y - 14.0) / padded.y))
    var start := (viewport - extent * unit) * 0.5 + Vector2(-ROW.x * dimensions.y, 0.87) * unit
    return Transform2D(COLUMN * unit, ROW * unit, start)

static func center(projection: Transform2D, cell: Vector2i) -> Vector2:
    return projection * (Vector2(cell) - Vector2(0.5, 0.5))

static func pick(projection: Transform2D, dimensions: Vector2i, point: Vector2) -> Vector2i:
    var cell := Vector2i((projection.affine_inverse() * point).floor()) + Vector2i.ONE
    if cell.x < 1 or cell.y < 1 or cell.x > dimensions.x or cell.y > dimensions.y:
        return OUTSIDE
    return cell

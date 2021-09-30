//! A piece in Teris game. This class is only used by PieceSet. Other classes
//! access Piece through PieceSet.
//!
//! Every piece is composed by 4 POINTs, using Cartesian coordinate system.
//! That is, the most bottom left point is (0, 0), the values on x-axis
//! increase to the right, and values on y-axis increase to the top.
//!
//! To represent a piece, it is snapped to the bottom-left corner. For example,
//! when the 'I' piece stands vertically, the point array stores:
//! (0,0) (0,1) (0,2) (0,3)
//!
const Piece = @This();

const std = @import("std");
const win32 = struct {
    // TODO: this is a win32 macro, this should probably go somewhere in zigwin32
    fn RGB(red: u8, green: u8, blue: u8) u32 {
        return red | (@intCast(u32, green) << 8) | (@intCast(u32, blue) << 16);
    }
};
const math = @import("math.zig");

const IntPieceCoord = math.Int(0, 3);
pub const PiecePoint = struct { x: IntPieceCoord, y: IntPieceCoord };
pub const PieceBodyIndex = math.Int(0, piece_body_table.len - 1);

body_index: PieceBodyIndex,

// Piece type ID and rotation
//id: i32,
//rotation: i32,

// Piece color in RGB
color: u32,

// pieceId: piece type ID
// pieceRotation: how many time is the piece rotated (0-3)
// pieceColor: piece color in RGB
// apt: array of points of which the piece is composed. This constructor
//      moves these points automatically to snap the piece to bottom-left
//      corner (0,0)
// numPoints: number of points in apt
//pub fn init(id: i32, rotation: i32, color: u32, body: [4]PiecePoint) Piece {
pub fn init(body_index: PieceBodyIndex, color: u32) Piece {
    return Piece {
        //.id = id,
        //.rotation = rotation,
        .body_index = body_index,
        .color = color,
    };
}

pub fn getBody(self: Piece) *const [4]PiecePoint {
    return &piece_body_table[self.body_index.as(usize)].points;
}
pub fn getWidth(self: Piece) math.Int(1, 4) {
    return piece_body_table[self.body_index.as(usize)].width;
}

pub fn getSkirt(self: Piece, apt: *[4]PiecePoint) u3 {
    var result_count: u3 = 0;
    for (self.body) |pt| {
        const matched = blk: for (apt[0..result_count]) |result_pt, i| {
            if (result_pt.x == pt.x) {
                std.debug.assert(pt.y != result_pt.y);
                if (pt.y < result_pt.y) {
                    apt[i] = pt;
                }
                break :blk true;
            }
        };
        if (!matched) {
            apt[result_count] = pt;
            result_count += 1;
        }
    }
    return result_count;
}

const Side = enum { left, right };
pub fn getSide(self: Piece, apt: *[4]PiecePoint, side: Side) u3 {
    var result_count: u3 = 0;
    for (self.body) |pt| {
        const matched = blk: for (apt[0..result_count]) |result_pt, i| {
            if (result_pt.y == pt.y) {
                std.debug.assert(pt.x != result_pt.x);
                if (switch (side) {
                    .left => pt.x < result_pt.x,
                    .right => pt.x > result_pt.x,
                }) {
                    apt[i] = pt;
                }
                break :blk true;
            }
        };
        if (!matched) {
            apt[result_count] = pt;
            result_count += 1;
        }
    }
    return result_count;
}

//int Piece::getRightSide(POINT *apt) const
//{
//    int i = 0;
//    for (int y = 0; y < height; y++)
//    {
//        for (int x = width - 1; x >= 0; x--)
//        {
//            if (isPointExists(x, y))
//            {
//                apt[i].x = x;
//                apt[i].y = y;
//                i++;
//                break;
//            }
//        }
//    }
//    return i;
//}
//
//void Piece::print() const
//{
//    cout << "width = " << width << endl;
//    cout << "height = " << height << endl;
//    cout << "nPoints = " << nPoints << endl;
//    cout << "color = " << hex << color << endl;
//    for (int y = height - 1; y >= 0; y--)
//    {
//        for (int x = 0; x < width; x++)
//        {
//            if (isPointExists(x, y))
//				cout << "#";
//            else
//                cout << " ";
//        }
//        cout << endl;
//    }
//}
//
//bool Piece::isPointExists(int x, int y) const
//{
//    for (int i = 0; i < 4; i++)
//    {
//        if (body[i].x == x && body[i].y == y)
//            return true;
//    }
//    return false;
//}
pub fn getRandom(rand: *std.rand.Random) Piece {
    const body_index = rand.uintAtMost(PieceBodyIndex.UnderlyingInt, PieceBodyIndex.max);
    return Piece {
        .body_index = PieceBodyIndex.init(body_index),
        .color = colors[body_index / 4],
    };
}


// TODO: this could be done with a 4/4 grid of bits, i.e. a u32
const PieceBody = struct {
    points: [4]PiecePoint,
    width: math.Int(1, 4),
    height: math.Int(1, 4),

    pub fn init(points: [4]PiecePoint) PieceBody {
        var min = PiecePoint { .x = IntPieceCoord.typedMax, .y = IntPieceCoord.typedMax };
        var max = PiecePoint { .x = IntPieceCoord.typedMin, .y = IntPieceCoord.typedMin };
        for (points) |pt| {
            min.x = min.x.getMin(pt.x);
            min.y = min.y.getMin(pt.y);
            max.x = max.x.getMax(pt.x.val);
            max.y = max.y.getMax(pt.y.val);
        }
        std.debug.assert(min.x.val == 0);
        std.debug.assert(min.y.val == 0);
        return PieceBody {
            .points = points,
            .width = max.x.add(1),
            .height = max.y.add(1),
        };
    }
};

const piece_count = 7;
const colors = [piece_count]u32 {
    win32.RGB(255, 0, 0), // red
    win32.RGB(230, 130, 24), // orange
    win32.RGB(255, 255, 0), // yellow
    win32.RGB(120, 200, 80), // green
    win32.RGB(100, 180, 255), // blue
    win32.RGB(20, 100, 200), // dark blue
    win32.RGB(220, 180, 255), // purple
};
const piece_body_table = makePieces();
fn makePieces() [piece_count * 4]PieceBody {
    @setEvalBranchQuota(3000);
    var result: [piece_count * 4]PieceBody = undefined;

    // the tall I piece
    result[4 * 0] = PieceBody.init([_]PiecePoint {
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(1) },
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(2) },
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(3) },
    });
    // L piece
    result[4 * 1] = PieceBody.init([_]PiecePoint {
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(1) },
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(2) },
    });
    // counter-L piece
    result[4 * 2] = PieceBody.init([_]PiecePoint {
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(1) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(2) },
    });
    // S piece
    result[4 * 3] = PieceBody.init([_]PiecePoint {
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(1) },
        PiecePoint { .x = IntPieceCoord.init(2), .y = IntPieceCoord.init(1) },
    });
    // Z piece
    result[4 * 4] = PieceBody.init([_]PiecePoint {
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(2), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(1) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(1) },
    });
    // Square piece
    result[4 * 5] = PieceBody.init([_]PiecePoint {
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(1) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(1) },
    });
    // T piece
    result[4 * 6] = PieceBody.init([_]PiecePoint {
        PiecePoint { .x = IntPieceCoord.init(0), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(2), .y = IntPieceCoord.init(0) },
        PiecePoint { .x = IntPieceCoord.init(1), .y = IntPieceCoord.init(1) },
    });

    {
        var shape_offset: usize = 0;
        while (shape_offset + 3 < result.len) : (shape_offset += 4) {
            var rot_index : u3 = 1;
            while (rot_index < 4) : (rot_index += 1) {
                result[shape_offset + rot_index] = result[shape_offset];
                // TODO: perform the rotations
            }
        }
    }
    return result;
}

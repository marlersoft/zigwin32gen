//! Level stores current snapshot of the game, including the dropping piece,
//! the next piece, the piece generator (PieceSet), the position of the
//! dropping piece, the width and height of the level, the dropping speed,
//! and a two-dimentional color array that is used to represent the canvas.
//
const std = @import("std");
const win32 = struct {
    usingnamespace @import("win32").media.multimedia;
};
const Piece = @import("Piece.zig");

const Level = @This();

const tetris = @import("root");
const DrawEngine = @import("DrawEngine.zig");
const math = @import("math.zig");

const IntBoardColIndex = math.Int(0, tetris.block_width - 1);
const IntBoardRowIndex = math.Int(0, tetris.block_height - 1);
const IntBoardColCount = math.Int(0, tetris.block_width);
const IntBoardRowCount = math.Int(0, tetris.block_height);

const IntMillisPerStep = math.Int(1, 500);

prng: std.rand.DefaultPrng = std.rand.DefaultPrng.init(0),
board: [tetris.block_width][tetris.block_height] u32 =
    [_][tetris.block_height]u32 { ([_]u32 {0} ** tetris.block_height) } ** tetris.block_width,    // The cavnas, the drawing board
de: *DrawEngine,       // Does graphics stuffs
//PieceSet pieceSet;   // Piece generator
current: ?Piece = null,
next: ?Piece = null,   // Next piece
posX: IntBoardColIndex = IntBoardColIndex.init(0),     // X coordinate of dropping piece (Cartesian system)
posY: IntBoardRowIndex = IntBoardRowIndex.init(0),     // Y coordinate of dropping piece
millis_per_step: IntMillisPerStep = IntMillisPerStep.init(500),   // Drop a cell every _speed_ millisecs
lastTime: u32 = 0,     // Last time updated
//double currentTime;  // Current update time
score: u16 = 0,            // Player's score

//// de: used to draw the level
//// width & height: level size in cells
//Level(DrawEngine &de, int width = 10, int height = 20);
//~Level();
//
//
//// Rotates the dropping piece, returns true if successful
//bool rotate();
//
//// Moves the dropping piece, returns true if successful
//// cxDistance is horizontal movement, positive value is right
//// cyDistance is vertical movement, positive value is up (normally it's
//// negaive)
//bool move(int cxDistance, int cyDistance);
//
//bool isGameOver();
//
//// Draw different kinds of info
//void drawSpeed() const;
//void drawScore() const;
//void drawNextPiece() const;
//
//// Places a piece somewhere
//// If there isn't enough space, does nothing and returns false
//bool place(int x, int y, const Piece &piece);
//
//// Clears a piece on the canvas
//void clear(const Piece& piece);
//
//// Releases the next dropping piece
//void dropRandomPiece();
//
//// Checks if the piece hits the boundary
//bool isHitBottom() const;
//bool isHitLeft() const;
//bool isHitRight() const;
//
//// Checks if a piece can move to a position
//bool isCovered(const Piece &piece, int x, int y) const;


//pub fn init(drawengine: DrawEngine) Level {
////Level::Level(DrawEngine &de, int width, int height) :
////de(de), width(width), height(height), lastTime(0.0), speed(500), score(-1)
//
//    //srand(time(0));
//
//    //self.lastTime = 0.0;
//    //self.speed = 500;
//    //self.score = -1;
//
//    //current = 0;
//    //next = pieceSet.getRandomPiece();
//    return Level { };
//}

pub fn drawBoard(self: Level) void {
    var i: u31 = 0;
    while (i < tetris.block_width) : (i += 1) {
        var j: u31 = 0;
        while (j < tetris.block_height) : (j += 1) {
            self.de.drawBlock(i, j, self.board[i][j]);
        }
    }
}

const MoveX = math.Int(-1, 1);
const MoveY = math.Int(-1, 0);

pub fn timerUpdate(self: *Level) void {
    // If the time isn't up, don't drop nor update
    const currentTime = win32.timeGetTime();
    if (currentTime - self.lastTime < self.millis_per_step.val)
        return;

    // Time's up, drop
    // If the piece hits the bottom, check if player gets score, drop the next
    // piece, increase speed, redraw info
    // If player gets score, increase more speed
    if (self.current == null or !self.move(MoveX.init(0), MoveY.init(-1))) {
        const lines = self.clearCompletedRows();
        self.millis_per_step = self.millis_per_step.sub(lines.mult(2)).getMax(100).as(IntMillisPerStep);
        self.score += lines.mult(lines).mult(5).add(1).val;
        self.dropRandomPiece();
        self.drawScore();
        self.drawSpeed();
        //drawNextPiece();
    }

    self.lastTime = currentTime;
}

fn place(self: *Level, x: IntBoardColIndex, y: IntBoardRowIndex, piece: Piece) void {
    std.debug.assert(x.add(piece.getWidth()).lte(tetris.block_width));

    self.posX = x;
    self.posY = y;
    for (piece.getBody()) |pt| {
        const block_y = y.add(pt.y);
        if (block_y.gte(tetris.block_height))
            continue;
        std.debug.assert(self.board[x.add(pt.x).as(usize)][block_y.as(usize)] == 0);
        self.board[x.add(pt.x).as(usize)][block_y.as(usize)] = piece.color;
    }
}

//bool Level::rotate()
//{
//    Piece *tmp = current;
//
//    // Move the piece if it needs some space to rotate
//    int disX = max(posX + current->getHeight() - width, 0);
//
//    // Go to next rotation state (0-3)
//    int rotation = (current->getRotation() + 1) % PieceSet::NUM_ROTATIONS;
//
//    clear(*current);
//    current = pieceSet.getPiece(current->getId(), rotation);
//
//    // Rotate successfully
//    if (place(posX - disX, posY, *current))
//        return true;
//
//    // If the piece cannot rotate due to insufficient space, undo it
//    current = tmp;
//    place(posX, posY, *current);
//    return false;
//}
//
fn move(self: *Level, cxDistance: MoveX, cyDistance: MoveY) bool {
    std.debug.assert(self.current != null);

    const new_y = self.posY.add(cyDistance).tryWithMin(0) orelse {
        std.log.debug("y hit bottom", .{});
        return false;
    };
    const new_non_negative_x = self.posX.add(cxDistance).tryWithMin(0) orelse {
        std.log.debug("x hit left wall", .{});
        return false;
    };
    if (new_non_negative_x.add(self.current.?.getWidth()).gt(tetris.block_width)) {
        std.log.debug("x width hit right wall", .{});
        return false;
    }
    // we know new_non_negative_x.val <= tetris.block_width - 1 because of the if condition above
    const new_x = math.Int(0, tetris.block_width - 1).initNoCheck(new_non_negative_x.val);

    if (self.posX.add(self.current.?.getWidth()).add(cxDistance).gt(tetris.block_width)) {
        std.log.debug("x width hit right wall", .{});
        return false;
    }

    // need to remove the piece before calling canPlace so the piece doesn't collide with itself
    self.clear(self.current.?);
    if (!self.isCovered(self.current.?, new_x, new_y)) {
        self.place(new_x, new_y, self.current.?);
        return true;
    }

    self.place(self.posX, self.posY, self.current.?);
    return false;
}

fn canMoveCurrent(self: Level, cxDistance: MoveX, cyDistance: MoveY) bool {
    if (cxDistance.lt(0) and self.isHitLeft()) {
        std.log.debug("x hit left wall", .{});
        return false;
    }
    if (cxDistance.gt(0) and self.isHitRight()) {
        std.log.debug("x hit right wall", .{});
        return false;
    }
    if (cyDistance.lt(0) and self.isHitBottom()) {
        std.log.debug("hit bottom", .{});
        return false;
    }
    return true;
}

// TODO: rename to clearPiece
fn clear(self: *Level, piece: Piece) void {
    for (piece.getBody()) |pt| {
        const x = self.posX.add(pt.x);
        const y = self.posY.add(pt.y);
        if (x.lt(tetris.block_width) and y.lt(tetris.block_height)) {
            std.debug.assert(self.board[x.as(usize)][y.as(usize)] != 0);
            self.board[x.as(usize)][y.as(usize)] = 0;
        }
    }
}

fn dropRandomPiece(self: *Level) void {
    self.current = self.next;
    self.next = Piece.getRandom(&self.prng.random);
    if (self.current) |current| {
        _ = self.place(IntBoardColIndex.init(3), IntBoardRowIndex.init(tetris.block_height - 1), current);
    }
}

fn isHitBottom(self: Level) bool {
    for (self.current.?.getBody()) |pt| {
        const x = self.posX.add(pt.x);
        const y = self.posY.add(pt.y);
        if (y.lt(tetris.block_height) and (y.val == 0 or self.board[x.as(usize)][y.as(usize)-1] != 0)) {
            std.log.debug("y = {}, below color = {}", .{y.val, self.board[x.as(usize)][y.as(usize)-1]});
            return true;
        }
    }
    return false;
}

fn isHitLeft(self: Level) bool {
    for (self.current.?.getBody()) |pt| {
        const x = self.posX.add(pt.x);
        const y = self.posY.add(pt.y);
        if (y.gte(tetris.block_height))
            continue;
        if (x.val == 0 or self.board[x.as(usize)-1][y.as(usize)] != 0)
            return true;
    }
    return false;
}

fn isHitRight(self: Level) bool {
    for (self.current.?.getBody()) |pt| {
        const x = self.posX.add(pt.x);
        const y = self.posY.add(pt.y);
        if (y.gte(tetris.block_height))
            continue;
        if (x.val == tetris.block_width - 1 or self.board[x.as(usize)+1][y.as(usize)] != 0)
            return true;
    }
    return false;
}

fn isCovered(self: Level, piece: Piece, x: IntBoardColIndex, y: IntBoardRowIndex) bool {
    for (piece.getBody()) |pt| {
        const tmpX = x.add(pt.x);
        const tmpY = y.add(pt.y);
        if (tmpX.gte(tetris.block_width) or tmpY.gte(tetris.block_height))
            continue;
        if (self.board[tmpX.as(usize)][tmpY.as(usize)] != 0)
            return true;
    }
    return false;
}

fn clearCompletedRows(self: *Level) math.Int(0, 4) {
    var rows_cleared = math.Int(0, 4).init(0);

    var row = IntBoardRowCount.init(0);
    while (row.lt(tetris.block_height)) {
        var isComplete = true;
        {
            var col = IntBoardColCount.init(0);
            while (col.lt(tetris.block_width)) : (col.plusEqual(1)) {
                if (self.board[col.as(usize)][row.as(usize)] == 0) {
                    isComplete = false;
                    break;
                }
            }
        }
        // If the row is full, clear it (fill with black)
        if (isComplete)
        {
            {
                var col: u31 = 0;
                while (col < tetris.block_width) : (col += 1) {
                    self.board[col][row.as(usize)] = 0;
                }
            }
            // Move rows down
            {
                var move_row = row;
                while (move_row.lt(tetris.block_height - 1)) : (move_row.plusEqual(1)) {
                    var move_col = IntBoardColCount.init(0);
                    while (move_col.lt(tetris.block_width)) : (move_col.plusEqual(1)) {
                        self.board[move_col.as(usize)][move_row.as(usize)] =
                            self.board[move_col.as(usize)][move_row.as(usize) + 1];
                    }
                }

            }
            rows_cleared.plusEqual(1);
        } else {
            row.plusEqual(1);
        }
    }
    return rows_cleared;
}

pub fn isGameOver(self: Level) bool {
    _ = self;
//    // Exclude the current piece
//    if (current)
//        clear(*current);
//
//    // If there's a piece on the top, game over
//    for (int i = 0; i < width; i++) {
//        if (board[i][height-1]) {
//            if (current)
//                place(posX, posY, *current);
//            return true;
//        }
//    }
//
//    // Put the current piece back
//    if (current != 0)
//        place(posX, posY, *current);
    return false;
}

pub fn drawSpeed(self: Level) void {
    self.de.drawSpeed((500 - self.millis_per_step.val) / 2, tetris.block_width + 1, 12);
}

pub fn drawScore(self: Level) void {
    self.de.drawScore(self.score, tetris.block_width + 1, 13);
}

//void Level::drawNextPiece() const
//{
//    de.drawNextPiece(*next, width + 1, 14);
//}
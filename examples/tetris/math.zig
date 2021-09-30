const std = @import("std");
const testing = std.testing;

pub usingnamespace ops;
const ops = struct {
    pub fn getVal(comptime T: type, x: anytype) T {
        switch (@typeInfo(@TypeOf(x))) {
            .ComptimeInt => return x,
            .Int => return @intCast(T, x),
            .Struct => |info| {
                if (comptime info.fields.len == 1 and std.mem.eql(u8, info.fields[0].name, "val"))
                    return x.as(T);
            },
            else => {},
        }
        @compileError("unsupported getVal: " ++ @typeName(@TypeOf(x)));
    }
    pub fn minInt(comptime T: type) comptime_int {
        switch (@typeInfo(T)) {
            .ComptimeInt => @compileError("cannot use comptime_int here"),
            .Int => return std.math.minInt(T),
            .Struct => {
                if (@hasDecl(T, "min")) return T.min;
            },
            else => {},
        }
        @compileError("unsupported minInt: " ++ @typeName(T));
    }
    pub fn maxInt(comptime T: type) comptime_int {
        switch (@typeInfo(T)) {
            .ComptimeInt => @compileError("cannot use comptime_int here"),
            .Int => return std.math.maxInt(T),
            .Struct => {
                if (@hasDecl(T, "max")) return T.max;
            },
            else => {},
        }
        @compileError("unsupported maxInt: " ++ @typeName(T));
    }
};

pub fn minProduct(
    comptime min1: comptime_int,
    comptime max1: comptime_int,
    comptime min2: comptime_int,
    comptime max2: comptime_int,
) comptime_int {
    if (min1 < 0) @compileError("not implemented");
    if (min2 < 0) @compileError("not implemented");
    _ = max1;
    _ = max2;
    return min1 * min2;
}
pub fn maxProduct(
    comptime min1: comptime_int,
    comptime max1: comptime_int,
    comptime min2: comptime_int,
    comptime max2: comptime_int,
) comptime_int {
    if (min1 < 0) @compileError("not implemented");
    if (min2 < 0) @compileError("not implemented");
    return max1 * max2;
}


//const IntInfo = struct {
//    min: comptime_int,
//    max: comptime_int,
//};
//pub fn getIntInfo(x: anytype) IntInfo {
//}

pub fn IntUnion(comptime A: type, comptime B: type) type {
    return Int(std.math.min(A.min, B.min), std.math.max(A.max, B.max));
}

pub fn Int(comptime min: comptime_int, comptime max: comptime_int) type {
    return struct {
        pub const min = min;
        pub const max = max;
        pub const typedMin = @This() { .val = min };
        pub const typedMax = @This() { .val = max };
        pub const UnderlyingInt = std.math.IntFittingRange(min, max);

        val: UnderlyingInt,

        pub fn init(val: UnderlyingInt) @This() {
            if (std.math.maxInt(UnderlyingInt) > max) {
                std.debug.assert(val <= max);
            }
            return .{ .val = val };
        }

        pub fn initNoCheck(val: anytype) @This() {
            return .{ .val = @intCast(UnderlyingInt, val) };
        }

        // NOTE: this is equivalent to an implicit cast to a super type
        //       it cannot fail, it only allows conversion to types that can hold all
        //       values from the source type
        pub fn as(self: @This(), comptime T: type) T {
            switch (@typeInfo(T)) {
                .Int => {
                    std.debug.assert(min >= std.math.minInt(T));
                    std.debug.assert(max <= std.math.maxInt(T));
                    return self.val;
                },
                .Struct => {
                    std.debug.assert(@hasDecl(T, "min"));
                    std.debug.assert(@hasDecl(T, "max"));
                    std.debug.assert(min >= T.min);
                    std.debug.assert(max <= T.max);
                    return T { .val = self.val };
                },
                else => {},
            }
            @compileError("unsupported as: " ++ @typeName(T));
        }

        pub fn tryCoerce(self: @This(), comptime T: type) ?T {
            if (comptime min < T.min) {
                if (self.val < T.min) return null;
            }
            if (comptime max > T.max) {
                if (self.val > T.max) return null;
            }
            return T { .val = @intCast(T.UnderlyingInt, self.val) };
        }
        pub fn tryWithMin(self: @This(), comptime new_min: comptime_int) ?Int(new_min, max) {
            std.debug.assert(new_min > min);
            if (self.val < new_min) return null;
            const Result = Int(new_min, max);
            return Result.init(@intCast(Result.UnderlyingInt, self.val));
        }

        pub fn getMin(self: @This(), other: anytype) Int(
            std.math.min(min, ops.minInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other))),
            std.math.min(max, ops.maxInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other))),
        ) {
            const OtherT = if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other);
            const other_min = ops.minInt(OtherT);
            const other_max = ops.maxInt(OtherT);
            const Result = Int(std.math.min(min, other_min), std.math.min(max, other_max));
            return Result {
                .val = @intCast(Result.UnderlyingInt, std.math.min(
                    @intCast(IntUnion(Result, @This()).UnderlyingInt, self.val),
                    ops.getVal(IntUnion(Result, Int(other_min, other_max)).UnderlyingInt, other)
                )),
            };
        }

        pub fn getMax(self: @This(), other: anytype) Int(
            std.math.max(min, ops.minInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other))),
            std.math.max(max, ops.maxInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other))),
        ) {
            const OtherT = if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other);
            const other_min = ops.minInt(OtherT);
            const other_max = ops.maxInt(OtherT);
            const Result = Int(std.math.max(min, other_min), std.math.max(max, other_max));
            return Result {
                .val = @intCast(Result.UnderlyingInt, std.math.max(
                    @intCast(IntUnion(Result, @This()).UnderlyingInt, self.val),
                    ops.getVal(IntUnion(Result, Int(other_min, other_max)).UnderlyingInt, other)
                )),
            };
        }

        pub fn plusEqual(self: *@This(), other: anytype) void {
            self.val += ops.getVal(UnderlyingInt, other);
        }

        pub fn add(self: @This(), other: anytype) Int(
            min + ops.minInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other)),
            max + ops.maxInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other)),
        ) {
            const OtherT = if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other);
            const other_min = ops.minInt(OtherT);
            const other_max = ops.maxInt(OtherT);
            const Result = Int(min + other_min, max + other_max);
            return Result {
                .val = @intCast(Result.UnderlyingInt,
                    @intCast(IntUnion(Result, @This()).UnderlyingInt, self.val) +
                    ops.getVal(IntUnion(Result, Int(other_min, other_max)).UnderlyingInt, other)
                ),
            };
        }

        pub fn sub(self: @This(), other: anytype) Int(
            min - ops.maxInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other)),
            max - ops.minInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other)),
        ) {
            const OtherT = if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other);
            const other_min = ops.minInt(OtherT);
            const other_max = ops.maxInt(OtherT);
            const Result = Int(min - other_max, max - other_min);
            return Result {
                .val = @intCast(Result.UnderlyingInt,
                    @intCast(IntUnion(Result, @This()).UnderlyingInt, self.val) -
                    ops.getVal(IntUnion(Result, Int(other_min, other_max)).UnderlyingInt, other)
                ),
            };
        }

        pub fn mult(self: @This(), other: anytype) Int(
            minProduct(min, max,
                ops.minInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other)),
                ops.maxInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other)),
            ),
            maxProduct(min, max,
                ops.minInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other)),
                ops.maxInt(if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other)),
            ),
        ) {
            const OtherT = if (@TypeOf(other) == comptime_int) Int(other, other) else @TypeOf(other);
            const other_min = ops.minInt(OtherT);
            const other_max = ops.maxInt(OtherT);
            const Result = Int(
                minProduct(min, max, other_min, other_max),
                maxProduct(min, max, other_min, other_max),
            );
            return Result {
                .val = @intCast(Result.UnderlyingInt,
                    @intCast(IntUnion(Result, @This()).UnderlyingInt, self.val) *
                    ops.getVal(IntUnion(Result, Int(other_min, other_max)).UnderlyingInt, other)
                ),
            };
        }

        pub fn lt(self: @This(), other: anytype) bool {
            return self.val < other;
        }
        pub fn lte(self: @This(), other: anytype) bool {
            return self.val <= other;
        }
        pub fn gt(self: @This(), other: anytype) bool {
            return self.val > other;
        }
        pub fn gte(self: @This(), other: anytype) bool {
            return self.val >= other;
        }
    };
}

test {
    try testing.expectEqual(0, Int(0, 0).init(0).val);
    try testing.expectEqual(@as(u1,  1), Int(0, 0).init(0).add(1).val);
    try testing.expectEqual(@as(i1, -1), Int(0, 0).init(0).sub(1).val);
    try testing.expectEqual(0, Int(0, 0).init(0).mult(1).val);

    {
        var i: u4 = 0;
        while (i < 10) : (i += 1){
            const I = Int(0, 9);
            try testing.expectEqual(i, I.init(i).val);
            try testing.expectEqual(std.math.min(i, 4), I.init(i).getMin(4).val);
            try testing.expectEqual(std.math.max(i, 4), I.init(i).getMax(4).val);
            try testing.expectEqual(i + 1, I.init(i).add(1).val);
            try testing.expectEqual(@intCast(u5, i) * 2, I.init(i).add(i).val);
            try testing.expectEqual(@intCast(i5, i) - 1, I.init(i).sub(1).val);
            try testing.expectEqual(@intCast(i5, 0), I.init(i).sub(i).val);
            try testing.expectEqual(i, I.init(i).mult(1).val);
            try testing.expectEqual(@intCast(u32, i) * 100, I.init(i).mult(100).val);
            try testing.expectEqual(@intCast(u8, i) * @intCast(u8, i), I.init(i).mult(i).val);
        }
    }
}

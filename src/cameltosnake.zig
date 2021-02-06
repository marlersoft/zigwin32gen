const std = @import("std");

// TODO: should this be in std lib?
pub fn camelToSnakeAlloc(a: *std.mem.Allocator, camel: []const u8) ![]const u8 {
    var snake = try a.alloc(u8, camelToSnakeLen(camel));
    errdefer a.free(snake);
    camelToSnake(snake, camel);
    return snake;
}

pub fn camelToSnakeLen(camel: []const u8) usize {
    var snake_len = camel.len;
    {var i : usize = 1; while (i < camel.len) : (i += 1) {
        if (std.ascii.isUpper(camel[i]) and std.ascii.isLower(camel[i-1])) {
            snake_len += 1;
        }
    }}
    return snake_len;
}

pub fn camelToSnake(snake: []u8, camel: []const u8) void {
    if (camel.len == 0) return;

    snake[0] = asciiCharToLower(camel[0]);

    var snake_index : usize = 1;
    {var i: usize = 1; while (i < camel.len) : (i += 1) {
        const is_upper = std.ascii.isUpper(camel[i]);
        if (is_upper and std.ascii.isLower(camel[i-1])) {
            snake[snake_index] = '_';
            snake_index += 1;
        }
        snake[snake_index] = asciiCharToLower(camel[i]);
        snake_index += 1;
    }}
    std.debug.assert(snake_index == snake.len);
}

fn testCamelToSnake(camel: []const u8, expected_snake: []const u8) void {
    const actual_snake = camelToSnakeAlloc(std.testing.allocator, camel) catch @panic("out of memory");
    defer std.testing.allocator.free(actual_snake);
    std.debug.print("test '{s}' expect '{s}'\n", .{camel, expected_snake});
    std.debug.print("actual '{s}'\n", .{actual_snake});
    std.testing.expect(std.mem.eql(u8, expected_snake, actual_snake));
}

test "cameltosnake" {
    testCamelToSnake("", "");
    testCamelToSnake("a", "a");
    testCamelToSnake("A", "a");

    testCamelToSnake("abc", "abc");

    testCamelToSnake("Abc", "abc");
    testCamelToSnake("aBc", "a_bc");
    testCamelToSnake("abC", "ab_c");
    
    testCamelToSnake("AbC", "ab_c");
    testCamelToSnake("aBC", "a_bc");

    testCamelToSnake("ABC", "abc");
}

// TODO: this should already exist somewhere?
fn asciiCharToLower(c: u8) u8 {
    return c + (if (std.ascii.isUpper(c)) @as(u8, 'a'-'A') else 0);
}

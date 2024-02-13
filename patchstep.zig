const builtin = @import("builtin");
const std = @import("std");
const Step = std.Build.Step;

pub const MakeFn = switch (builtin.zig_backend) {
    .stage1 => fn (self: *Step, prog_node: *std.Progress.Node) anyerror!void,
    else => *const fn (self: *Step, prog_node: *std.Progress.Node) anyerror!void,
};
const PatchFn = switch (builtin.zig_backend) {
    .stage1 => fn (step: *Step, prog_node: *std.Progress.Node, original_make_fn: MakeFn) anyerror!void,
    else => *const fn (step: *Step, prog_node: *std.Progress.Node, original_make_fn: MakeFn) anyerror!void,
};

const Patch = struct {
    original_make_fn: MakeFn,
    patch_make_fn: PatchFn,
};
const Map = std.AutoHashMap(*Step, Patch);

// We need a global map to retrieve the original make function from a *Step.
// NOTE: does this need to be synchronized?  Will Zig Build every be parallel?
var global_step_map: ?Map = null;

pub fn init(allocator: std.mem.Allocator) void {
    std.debug.assert(global_step_map == null);
    global_step_map = Map.init(allocator);
}

pub fn patch(step: *Step, patch_fn: PatchFn) void {
    const map = &(global_step_map orelse @panic("patchstep.init has not been called"));
    if (map.get(step)) |_|
        std.debug.panic("patchstep does not currently support multiple patches on the same step step={s}", .{step.name});
    map.put(step, Patch{
        .original_make_fn = step.makeFn,
        .patch_make_fn = patch_fn,
    }) catch @panic("Out Of Memory");
    step.makeFn = patchMake;
}

fn patchMake(step: *Step, prog_node: *std.Progress.Node) anyerror!void {
    const p = global_step_map.?.get(step) orelse
        std.debug.panic("patchMake was used on a step ({s}) that wasn't in the global step map???", .{step.name});
    return p.patch_make_fn(step, prog_node, p.original_make_fn);
}

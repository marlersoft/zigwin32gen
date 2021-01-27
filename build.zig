const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    //const clone_win32json = try b.allocator.create(CloneRepoStep);
    //clone_win32json.* = CloneRepoStep.init(b, .{
    //    .repo_url = "github.com/marlersoft/win32json",
    //    .sha = "cc76f88be151084e1c218adf00bc758628a90fef",
    //});
    //const clone_win32json_top_level = b.step("clone-win32json", "Clone the win32json repository");
    //clone_win32json_top_level.dependOn(&clone_win32json.step);

    const genzig_exe = b.addExecutable("genzig", "src/genzig.zig");
    genzig_exe.setTarget(target);
    genzig_exe.setBuildMode(mode);
    genzig_exe.install();

    const run_genzig_exe = genzig_exe.run();
    run_genzig_exe.step.dependOn(b.getInstallStep());

    const run_genzig = b.step("genzig", "Generate Zig bindings from the win32json JSON files");
    run_genzig.dependOn(&run_genzig_exe.step);
}

//const CloneRepoStep = struct {
//    step: Step,
//    repo_url: []const u8,
//    sha: []const u8,
//    local_name: []const u8,
//    pub fn init(b: *Builder, named: struct { repo_url: []const u8, sha: []const u8, local_name: ?[]const u8 = null,}) CloneRepoStep {
//        const local_name_resolved = if (local_name) |l| l else std.fs.path.basename(repo_url);
//        return .{
//            .step = Step.init(.Custom, b.fmt("clone {}", .{local_name_resolved}), b.allocator, make),
//            .repo_url = repo_url,
//            .sha = sha,
//            .local_name = local_name,
//        };
//    }
//    fn make(self: *Step) anyerror!void {
//        std.debug.warn("ERROR: CloneRepoStep not implemented", .{});
//    }
//};

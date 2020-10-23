const std = @import("std");
const Builder = std.build.Builder;
const Step = std.build.Step;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const sdkdata_exe = b.addExecutable("sdkdata", "src/sdkdata.zig");
    sdkdata_exe.setTarget(target);
    sdkdata_exe.setBuildMode(mode);
    sdkdata_exe.install();

    const run_sdkdata_exe = sdkdata_exe.run();
    run_sdkdata_exe.step.dependOn(b.getInstallStep());

    const run_sdk_data = b.step("run-sdk-data", "Run the windows_sdk_data repo code generator");
    run_sdk_data.dependOn(&run_sdkdata_exe.step);

    //const clone_sdkdata = try b.allocator.create(CloneRepoStep);
    //clone_sdkdata.* = CloneRepoStep.init(b, .{
    //    .repo_url = "github.com/ohjeongwook/windows_sdk_data",
    //    .sha = "5d79e67f33da5f87c61b8970f4ff4c480daf8cc3",
    //});
    //const clone_sdkdata_top_level = b.step("clone-sdkdata", "Clone the windows_sdk_data repository");
    //clone_sdkdata_top_level.dependOn(&clone_sdkdata.step);
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

const std = @import("std");
const sdk_build = @import("flowdata_sdk");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk_dep = b.dependency("flowdata_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const libs_dep = b.dependency("flowdata_libs", .{
        .target = target,
        .optimize = optimize,
    });

    const sqlite_c = b.addTranslateC(.{
        .root_source_file = libs_dep.path("sqlite/c/sqlite3_c.h"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_c.linkSystemLibrary("sqlite3", .{});

    const drivers = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "memory", .path = "memory/src/plugin.zig" },
        .{ .name = "file_store", .path = "file_store/src/plugin.zig" },
        .{ .name = "sqlite", .path = "sqlite/src/plugin.zig" },
        .{ .name = "yaml", .path = "yaml/src/plugin.zig" },
        .{ .name = "ssh_store", .path = "ssh_store/src/plugin.zig" },
    };

    const test_step = b.step("test", "Run all driver C-ABI conformance tests");
    for (drivers) |drv| {
        const drv_so = sdk_build.addDriverPlugin(b, sdk_dep, .{
            .name = drv.name,
            .root_source_file = b.path(drv.path),
            .target = target,
            .optimize = optimize,
        });
        if (std.mem.eql(u8, drv.name, "sqlite")) {
            drv_so.root_module.addImport("sqlite3_c", sqlite_c.createModule());
            drv_so.root_module.linkSystemLibrary("sqlite3", .{});
        }
        b.installArtifact(drv_so);
        const run_t = b.addRunArtifact(b.addTest(.{ .root_module = drv_so.root_module }));
        test_step.dependOn(&run_t.step);
    }
}


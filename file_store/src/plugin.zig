const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

/// Standalone C-ABI FileStore Driver (zero dependency on `parabellum` core source).
pub const FileStoreDriver = struct {
    allocator: std.mem.Allocator,

    pub fn create(_: []const abi.ConfigParam_ABI) !*FileStoreDriver {
        const self = try std.heap.c_allocator.create(FileStoreDriver);
        self.* = .{ .allocator = std.heap.c_allocator };
        return self;
    }

    pub fn deinit(self: *FileStoreDriver) void {
        self.allocator.destroy(self);
    }

    pub fn recordCount(_: *const FileStoreDriver, _: []const u8) usize {
        return 0;
    }

    pub fn capabilities(_: *const FileStoreDriver) abi.DriverCapabilities_ABI {
        return .{
            .read = true,
            .write = true,
            .streaming_read = true,
            .streaming_write = true,
        };
    }
};

pub const manifest = sdk.sdk.defineDriver(FileStoreDriver, .{
    .name = "file_store",
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "file_store driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

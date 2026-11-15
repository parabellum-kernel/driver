const std = @import("std");
const sdk = @import("flowdata_sdk");
const abi = sdk.abi;

/// Standalone C-ABI SSH Store Driver (zero dependency on `flowdata` core source).
pub const SshStoreDriver = struct {
    allocator: std.mem.Allocator,

    pub fn create(_: []const abi.ConfigParam_ABI) !*SshStoreDriver {
        const self = try std.heap.c_allocator.create(SshStoreDriver);
        self.* = .{ .allocator = std.heap.c_allocator };
        return self;
    }

    pub fn deinit(self: *SshStoreDriver) void {
        self.allocator.destroy(self);
    }

    pub fn recordCount(_: *const SshStoreDriver, _: []const u8) usize {
        return 0;
    }

    pub fn capabilities(_: *const SshStoreDriver) abi.DriverCapabilities_ABI {
        return .{
            .read = true,
            .write = true,
            .streaming_read = true,
            .streaming_write = true,
        };
    }
};

pub const manifest = sdk.sdk.defineDriver(SshStoreDriver, .{
    .name = "ssh_store",
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "ssh_store driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

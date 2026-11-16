const std = @import("std");
const sdk = @import("parabellum_sdk");
const gdrive_vfs = @import("gdrive_vfs");
const abi = sdk.abi;

const gdrive = gdrive_vfs.gdrive;
const vfs = gdrive_vfs.vfs;

/// Standalone C-ABI Google Drive VFS Store Driver (`ARCH-037`).
/// Bridges Flowdata `Driver` C-ABI to `lib-gdrive-vfs` (`GDriveBlobStore`) + `lib/vfs`.
pub const GDriveStoreDriver = struct {
    allocator: std.mem.Allocator,
    vault_id: []u8,
    node_id: []u8,
    http_client: gdrive.StdHttpClient,
    blob_store: gdrive_vfs.GDriveBlobStore,
    catalog: vfs.InMemoryCatalog,

    pub fn create(params: []const abi.ConfigParam_ABI) !*GDriveStoreDriver {
        const alloc = std.heap.c_allocator;
        var vault_id: []const u8 = "default-vault";
        var node_id: []const u8 = "sa-primary";

        for (params) |p| {
            const k_ptr = p.key.ptr orelse continue;
            const v_ptr = p.value.ptr orelse continue;
            const k = k_ptr[0..p.key.len];
            const v = v_ptr[0..p.value.len];
            if (std.mem.eql(u8, k, "vault_id")) vault_id = v;
            if (std.mem.eql(u8, k, "node_id")) node_id = v;
        }

        const self = try alloc.create(GDriveStoreDriver);
        errdefer alloc.destroy(self);

        const owned_vid = try alloc.dupe(u8, vault_id);
        errdefer alloc.free(owned_vid);
        const owned_nid = try alloc.dupe(u8, node_id);
        errdefer alloc.free(owned_nid);

        const io = std.Io.Threaded.global_single_threaded.io();
        var http_client = gdrive.StdHttpClient.init(alloc, io);
        errdefer http_client.deinit();

        self.* = .{
            .allocator = alloc,
            .vault_id = owned_vid,
            .node_id = owned_nid,
            .http_client = http_client,
            .blob_store = undefined,
            .catalog = vfs.InMemoryCatalog.init(alloc),
        };
        self.blob_store = gdrive_vfs.GDriveBlobStore.init(
            alloc,
            self.http_client.port(),
            .compatible_major,
            0,
        );
        return self;
    }

    pub fn deinit(self: *GDriveStoreDriver) void {
        self.blob_store.deinit();
        self.http_client.deinit();
        self.catalog.deinit();
        self.allocator.free(self.vault_id);
        self.allocator.free(self.node_id);
        self.allocator.destroy(self);
    }

    pub fn recordCount(self: *const GDriveStoreDriver, _: []const u8) usize {
        return self.catalog.inodes.items.len;
    }

    pub fn capabilities(_: *const GDriveStoreDriver) abi.DriverCapabilities_ABI {
        return .{
            .read = true,
            .write = true,
            .streaming_read = true,
            .streaming_write = true,
        };
    }
};

pub const manifest = sdk.sdk.defineDriver(GDriveStoreDriver, .{
    .name = "gdrive_store",
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "gdrive_store driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

test "gdrive_store driver parses vault_id and node_id config params" {
    const k1 = "vault_id";
    const v1 = "vault-42";
    const k2 = "node_id";
    const v2 = "sa-02";
    const params = [_]abi.ConfigParam_ABI{
        .{
            .key = .{ .ptr = k1.ptr, .len = k1.len },
            .value = .{ .ptr = v1.ptr, .len = v1.len },
        },
        .{
            .key = .{ .ptr = k2.ptr, .len = k2.len },
            .value = .{ .ptr = v2.ptr, .len = v2.len },
        },
    };
    const drv = try GDriveStoreDriver.create(&params);
    defer drv.deinit();
    try std.testing.expectEqualStrings("vault-42", drv.vault_id);
    try std.testing.expectEqualStrings("sa-02", drv.node_id);
    try std.testing.expectEqual(@as(usize, 0), drv.recordCount(""));
}

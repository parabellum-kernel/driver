const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

const FileRowIterator = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    done: bool = false,
    field: abi.NamedField_ABI = undefined,

    fn nextImpl(handle: *abi.driver.RowIteratorHandle_ABI, out_row: *abi.RowView_ABI) callconv(.c) abi.HostError_ABI {
        const self: *FileRowIterator = @ptrCast(@alignCast(handle));
        if (self.done) return .end_of_stream;
        self.done = true;

        self.field = .{
            .name = "data",
            .value = .{
                .tag = .bytes_val,
                .payload = .{ .bytes = abi.Slice_ABI.from(self.data) },
            },
        };
        out_row.* = .{
            .fields_ptr = @ptrCast(&self.field),
            .fields_len = 1,
        };
        return .ok;
    }

    fn deinitImpl(handle: *abi.driver.RowIteratorHandle_ABI) callconv(.c) void {
        const self: *FileRowIterator = @ptrCast(@alignCast(handle));
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    const vtable = abi.driver.RowIteratorVTable_ABI{
        .next = nextImpl,
        .deinit = deinitImpl,
    };
};

/// Standalone C-ABI FileStore Driver (zero dependency on `parabellum` core source).
pub const FileStoreDriver = struct {
    allocator: std.mem.Allocator,
    base_dir: []u8,

    pub fn create(params: []const abi.ConfigParam_ABI) !*FileStoreDriver {
        const alloc = std.heap.c_allocator;
        var base: []const u8 = "";
        for (params) |p| {
            const k = p.key.toSlice();
            if (std.mem.eql(u8, k, "path") or std.mem.eql(u8, k, "base_dir") or std.mem.eql(u8, k, "directory")) {
                base = p.value.toSlice();
            }
        }
        const self = try alloc.create(FileStoreDriver);
        errdefer alloc.destroy(self);
        self.* = .{
            .allocator = alloc,
            .base_dir = try alloc.dupe(u8, base),
        };
        return self;
    }

    pub fn deinit(self: *FileStoreDriver) void {
        self.allocator.free(self.base_dir);
        self.allocator.destroy(self);
    }

    pub fn readStream(self: *FileStoreDriver, spec: abi.driver.ReadSpec_ABI) !abi.driver.RowIterator_ABI {
        const raw_path = if (spec.filter_sql_or_expr.len > 0) spec.filter_sql_or_expr.toSlice() else spec.table.toSlice();
        if (raw_path.len == 0) return error.InvalidPath;

        const target_path = if (self.base_dir.len > 0 and !std.fs.path.isAbsolute(raw_path) and !std.mem.startsWith(u8, raw_path, self.base_dir))
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_dir, raw_path })
        else
            try self.allocator.dupe(u8, raw_path);
        defer self.allocator.free(target_path);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, target_path, .{});
        defer file.close(io);
        const st = try file.stat(io);
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        errdefer self.allocator.free(buf);
        var reader = file.reader(io, &.{});
        try reader.interface.readSliceAll(buf);

        const iter = try self.allocator.create(FileRowIterator);
        iter.* = .{ .allocator = self.allocator, .data = buf };
        return .{
            .handle = @ptrCast(iter),
            .vtable = &FileRowIterator.vtable,
        };
    }

    pub fn writeRow(self: *FileStoreDriver, spec: abi.driver.WriteSpec_ABI) !void {
        const fields = spec.fieldsSlice();
        var data: []const u8 = if (spec.raw_bytes.len > 0) spec.raw_bytes.toSlice() else "";
        var filename: []const u8 = "";
        var series: []const u8 = "";
        var library: []const u8 = "";
        var archive_path: []const u8 = "";

        for (fields) |f| {
            const k = std.mem.span(f.name);
            if (f.value.tag != .bytes_val) continue;
            const v = f.value.payload.bytes.toSlice();
            if (std.mem.eql(u8, k, "data") or std.mem.eql(u8, k, "bytes") or std.mem.eql(u8, k, "content")) {
                if (data.len == 0) data = v;
            } else if (std.mem.eql(u8, k, "filename")) {
                filename = v;
            } else if (std.mem.eql(u8, k, "series")) {
                series = v;
            } else if (std.mem.eql(u8, k, "library")) {
                library = v;
            } else if (std.mem.eql(u8, k, "archive_path")) {
                archive_path = v;
            }
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        const base = std.mem.trimEnd(u8, self.base_dir, "/");
        const table = spec.table.toSlice();
        const target_path = if (filename.len > 0) blk: {
            if (library.len > 0 and series.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}/{s}", .{ if (base.len > 0) base else ".", library, series, filename });
            } else if (series.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ if (base.len > 0) base else ".", series, filename });
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ if (base.len > 0) base else ".", filename });
            }
        } else if (archive_path.len > 0) blk: {
            break :blk try self.allocator.dupe(u8, archive_path);
        } else blk: {
            break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}.bin", .{ if (base.len > 0) base else ".", if (table.len > 0) table else "output" });
        };
        defer self.allocator.free(target_path);

        if (std.fs.path.dirname(target_path)) |parent| {
            if (parent.len > 0) {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }
        }
        const file = try std.Io.Dir.cwd().createFile(io, target_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, data);
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
    .version = .{ .major = 2, .minor = 0, .patch = 1 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "file_store driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

/// Standalone C-ABI SSH Store Driver (zero dependency on `parabellum` core source).
pub const SshStoreDriver = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    port: []u8,
    user: []u8,
    identity_file: []u8,
    directory: []u8,

    pub fn create(params: []const abi.ConfigParam_ABI) !*SshStoreDriver {
        const alloc = std.heap.c_allocator;
        var host: []const u8 = "";
        var port: []const u8 = "";
        var user: []const u8 = "";
        var identity_file: []const u8 = "";
        var directory: []const u8 = "/tmp";
        for (params) |p| {
            const k = p.key.toSlice();
            const v = p.value.toSlice();
            if (std.mem.eql(u8, k, "host")) host = v
            else if (std.mem.eql(u8, k, "port")) port = v
            else if (std.mem.eql(u8, k, "user")) user = v
            else if (std.mem.eql(u8, k, "identity_file")) identity_file = v
            else if (std.mem.eql(u8, k, "directory") or std.mem.eql(u8, k, "remote_dir") or std.mem.eql(u8, k, "path")) directory = v;
        }
        const self = try alloc.create(SshStoreDriver);
        errdefer alloc.destroy(self);
        self.* = .{
            .allocator = alloc,
            .host = try alloc.dupe(u8, host),
            .port = try alloc.dupe(u8, port),
            .user = try alloc.dupe(u8, user),
            .identity_file = try alloc.dupe(u8, identity_file),
            .directory = try alloc.dupe(u8, directory),
        };
        return self;
    }

    pub fn deinit(self: *SshStoreDriver) void {
        self.allocator.free(self.host);
        self.allocator.free(self.port);
        self.allocator.free(self.user);
        self.allocator.free(self.identity_file);
        self.allocator.free(self.directory);
        self.allocator.destroy(self);
    }

    fn shellQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.append(alloc, '\'');
        for (s) |ch| {
            if (ch == '\'') {
                try out.appendSlice(alloc, "'\"'\"'");
            } else {
                try out.append(alloc, ch);
            }
        }
        try out.append(alloc, '\'');
        return out.toOwnedSlice(alloc);
    }

    pub fn writeRow(self: *SshStoreDriver, spec: abi.driver.WriteSpec_ABI) !void {
        if (self.host.len == 0) return error.MissingSshHost;
        const fields = spec.fieldsSlice();
        var data: []const u8 = if (spec.raw_bytes.len > 0) spec.raw_bytes.toSlice() else "";
        var filename: []const u8 = "";
        var series: []const u8 = "";
        var library: []const u8 = "";
        var chapter_number: []const u8 = "";
        var ext: []const u8 = "";

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
            } else if (std.mem.eql(u8, k, "chapter_number")) {
                chapter_number = v;
            } else if (std.mem.eql(u8, k, "ext")) {
                ext = v;
            }
        }
        if (data.len == 0) return error.MissingUploadPayload;

        var arena_impl = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_impl.deinit();
        const arena = arena_impl.allocator();

        const table = spec.table.toSlice();
        const resolved_name = if (filename.len > 0) filename else if (std.mem.eql(u8, table, "series_cover"))
            try std.fmt.allocPrint(arena, "cover.{s}", .{if (ext.len > 0) ext else "jpg"})
        else if (std.mem.eql(u8, table, "chapter_cover"))
            try std.fmt.allocPrint(arena, "chapter_{s}.{s}", .{ if (chapter_number.len > 0) chapter_number else "1", if (ext.len > 0) ext else "jpg" })
        else
            try std.fmt.allocPrint(arena, "{s}.bin", .{if (table.len > 0) table else "output"});

        const base = std.mem.trimEnd(u8, self.directory, "/");
        const remote_path = if (library.len > 0 and series.len > 0)
            try std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}", .{ base, library, series, resolved_name })
        else if (series.len > 0)
            try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ base, series, resolved_name })
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, resolved_name });

        const parent_dir = std.fs.path.dirname(remote_path) orelse base;
        const q_parent = try shellQuote(arena, parent_dir);
        const q_remote = try shellQuote(arena, remote_path);
        const remote_cmd = try std.fmt.allocPrint(arena, "mkdir -p {s} && cat > {s}", .{ q_parent, q_remote });

        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(arena, "ssh");
        if (self.port.len > 0) {
            try argv.appendSlice(arena, &.{ "-p", self.port });
        }
        if (self.identity_file.len > 0) {
            try argv.appendSlice(arena, &.{ "-i", self.identity_file });
        }
        try argv.appendSlice(arena, &.{ "-o", "BatchMode=yes" });
        const target = if (self.user.len > 0)
            try std.fmt.allocPrint(arena, "{s}@{s}", .{ self.user, self.host })
        else
            self.host;
        try argv.append(arena, target);
        try argv.append(arena, remote_cmd);

        var threaded = std.Io.Threaded.init(arena, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        if (child.stdin) |*stdin_file| {
            try stdin_file.writeStreamingAll(io, data);
            stdin_file.close(io);
            child.stdin = null;
        }
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return error.SshCommandFailed,
            else => return error.SshCommandFailed,
        }
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
    .version = .{ .major = 2, .minor = 0, .patch = 0 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "ssh_store driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

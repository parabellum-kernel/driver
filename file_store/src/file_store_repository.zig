const std = @import("std");
const Allocator = std.mem.Allocator;
const parabellum = @import("parabellum");
const PayloadHandle = parabellum.dataflow.PayloadHandle;
const repository = parabellum.repository;
const StorageRepository = repository.StorageRepository;
const ConfigParam = repository.ConfigParam;

const c = struct {
    const FILE = opaque {};
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern "c" fn fclose(stream: *FILE) c_int;
    extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern "c" fn remove(path: [*:0]const u8) c_int;
    extern "c" fn rename(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
    extern "c" fn mkdir(path: [*:0]const u8, mode: std.c.mode_t) c_int;
};

/// Physical disk directory repository for carved payloads, quarantined samples, and exported artifacts.
pub const FileStoreRepository = struct {
    comptime {
        StorageRepository.assertImplements(@This());
    }

    allocator: Allocator,
    directory: []const u8,
    file_count: usize = 0,

    pub fn init(allocator: Allocator, directory: []const u8) !FileStoreRepository {
        const owned_dir = try allocator.dupe(u8, directory);
        return .{
            .allocator = allocator,
            .directory = owned_dir,
            .file_count = 0,
        };
    }

    pub fn deinit(self: *FileStoreRepository) void {
        self.allocator.free(self.directory);
    }

    fn ensureParentDirs(alloc: Allocator, path: []const u8) void {
        const slash_idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
        if (slash_idx == 0) return;
        const parent = path[0..slash_idx];

        var it = std.mem.splitScalar(u8, parent, '/');
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        if (parent[0] == '/') {
            buf.append(alloc, '/') catch return;
        }

        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
                if (seg.len > 0) {
                    buf.appendSlice(alloc, seg) catch return;
                    buf.append(alloc, '/') catch return;
                }
                continue;
            }
            buf.appendSlice(alloc, seg) catch return;
            if (alloc.dupeSentinel(u8, buf.items, 0)) |dir_z| {
                defer alloc.free(dir_z);
                _ = c.mkdir(dir_z.ptr, 0o755);
            } else |_| return;
            buf.append(alloc, '/') catch return;
        }
    }

    fn getParam(params: []const ConfigParam, key: []const u8) ?[]const u8 {
        for (params) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    fn extractBytes(payload: PayloadHandle) []const u8 {
        if (payload.repr == .bytes and payload.len > 0) {
            const ptr: [*]const u8 = @ptrCast(payload.ptr);
            return ptr[0..payload.len];
        }
        const candidate_fields = [_][]const u8{ "data", "bytes", "content" };
        for (candidate_fields) |field| {
            if (payload.getReflected(field)) |rv| {
                if (rv.asString()) |s| {
                    if (s.len > 0) return s;
                }
            }
        }
        if (payload.len > 0 and payload.repr == .bytes) {
            const ptr: [*]const u8 = @ptrCast(payload.ptr);
            return ptr[0..payload.len];
        }
        return "";
    }

    const STREAM_CHUNK_SIZE: usize = 256 * 1024;

    fn writeStreamToPath(self: *FileStoreRepository, file_path: []const u8, payload: PayloadHandle) !void {
        ensureParentDirs(self.allocator, file_path);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{file_path});
        defer self.allocator.free(tmp_path);

        const tmp_z = try self.allocator.dupeSentinel(u8, tmp_path, 0);
        defer self.allocator.free(tmp_z);

        const path_z = try self.allocator.dupeSentinel(u8, file_path, 0);
        defer self.allocator.free(path_z);

        {
            const fp = c.fopen(tmp_z.ptr, "wb") orelse return error.FileOpenFailed;
            errdefer {
                _ = c.fclose(fp);
                _ = c.remove(tmp_z.ptr);
            }

            if (payload.stream_backing) |backing| {
                const total = backing.size();
                if (total > 0) {
                    const chunk_buf = try self.allocator.alloc(u8, STREAM_CHUNK_SIZE);
                    defer self.allocator.free(chunk_buf);
                    var offset: u64 = 0;
                    while (offset < total) {
                        const want: usize = @intCast(@min(@as(u64, STREAM_CHUNK_SIZE), total - offset));
                        try backing.readAt(offset, chunk_buf[0..want]);
                        const written = c.fwrite(chunk_buf.ptr, 1, want, fp);
                        if (written != want) return error.DiskWriteFailed;
                        offset += want;
                    }
                }
            } else {
                const bytes = extractBytes(payload);
                if (bytes.len > 0) {
                    const written = c.fwrite(bytes.ptr, 1, bytes.len, fp);
                    if (written != bytes.len) return error.DiskWriteFailed;
                }
            }

            if (c.fclose(fp) != 0) return error.DiskWriteFailed;
        }

        if (c.rename(tmp_z.ptr, path_z.ptr) != 0) {
            _ = c.remove(tmp_z.ptr);
            return error.DiskWriteFailed;
        }
        self.file_count += 1;
    }

    pub fn writePayload(self: *FileStoreRepository, channel: []const u8, payload: PayloadHandle) !void {
        var path_buf: [1024]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.bin", .{ self.directory, channel });
        try self.writeStreamToPath(file_path, payload);
    }

    pub fn writePayloadWithParams(
        self: *FileStoreRepository,
        channel: []const u8,
        payload: PayloadHandle,
        params: []const ConfigParam,
    ) !void {
        if (params.len == 0) {
            try self.writePayload(channel, payload);
            return;
        }

        const sub_dir = std.mem.trim(u8, getParam(params, "remote_dir") orelse getParam(params, "directory") orelse "", "/");
        const filename = getParam(params, "filename") orelse blk: {
            if (payload.getReflected("filename")) |rv| {
                if (rv.asString()) |s| {
                    if (s.len > 0) break :blk s;
                }
            }
            break :blk null;
        };

        const base = std.mem.trimEnd(u8, self.directory, "/");
        const file_path = if (filename) |fname| blk: {
            if (sub_dir.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ base, sub_dir, fname });
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, fname });
            }
        } else blk: {
            if (sub_dir.len > 0) {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}.bin", .{ base, sub_dir, channel });
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}.bin", .{ base, channel });
            }
        };
        defer self.allocator.free(file_path);

        try self.writeStreamToPath(file_path, payload);
    }

    pub fn readPayload(self: *const FileStoreRepository, channel: []const u8) ?PayloadHandle {
        _ = self;
        _ = channel;
        return null;
    }

    pub fn recordCount(self: *const FileStoreRepository, channel: []const u8) usize {
        _ = channel;
        return self.file_count;
    }

    pub fn storageRepository(self: *FileStoreRepository) StorageRepository {
        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const self_ptr: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                try self_ptr.writePayload(channel, payload);
            }

            fn doWritePayloadWithParams(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle, params: []const ConfigParam) anyerror!void {
                const self_ptr: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                try self_ptr.writePayloadWithParams(channel, payload, params);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const self_ptr: *const FileStoreRepository = @ptrCast(@alignCast(ctx));
                return self_ptr.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const self_ptr: *const FileStoreRepository = @ptrCast(@alignCast(ctx));
                return self_ptr.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const self_ptr: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                self_ptr.deinit();
            }

            const vtable = StorageRepository.VTable{
                .writePayload = &doWritePayload,
                .writePayloadWithParams = &doWritePayloadWithParams,
                .readPayload = &doReadPayload,
                .recordCount = &doRecordCount,
                .deinit = &doDeinit,
            };
        };

        return .{
            .ptr = self,
            .vtable = &Trampoline.vtable,
        };
    }

    pub fn createHeap(allocator: Allocator, params: []const repository.ConfigParam) anyerror!StorageRepository {
        var dir: []const u8 = "./artifacts";
        for (params) |p| {
            if (std.mem.eql(u8, p.key, "directory") or std.mem.eql(u8, p.key, "path")) {
                dir = p.value;
            }
        }

        const self_ptr = try allocator.create(FileStoreRepository);
        self_ptr.* = try FileStoreRepository.init(allocator, dir);

        const Trampoline = struct {
            fn doWritePayload(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle) anyerror!void {
                const s: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                try s.writePayload(channel, payload);
            }

            fn doWritePayloadWithParams(ctx: *anyopaque, channel: []const u8, payload: PayloadHandle, write_params: []const ConfigParam) anyerror!void {
                const s: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                try s.writePayloadWithParams(channel, payload, write_params);
            }

            fn doReadPayload(ctx: *anyopaque, channel: []const u8) ?PayloadHandle {
                const s: *const FileStoreRepository = @ptrCast(@alignCast(ctx));
                return s.readPayload(channel);
            }

            fn doRecordCount(ctx: *anyopaque, channel: []const u8) usize {
                const s: *const FileStoreRepository = @ptrCast(@alignCast(ctx));
                return s.recordCount(channel);
            }

            fn doDeinit(ctx: *anyopaque) void {
                const s: *FileStoreRepository = @ptrCast(@alignCast(ctx));
                const alloc = s.allocator;
                s.deinit();
                alloc.destroy(s);
            }

            const vtable = StorageRepository.VTable{
                .writePayload = &doWritePayload,
                .writePayloadWithParams = &doWritePayloadWithParams,
                .readPayload = &doReadPayload,
                .recordCount = &doRecordCount,
                .deinit = &doDeinit,
            };
        };

        return .{
            .ptr = self_ptr,
            .vtable = &Trampoline.vtable,
        };
    }
};

fn sha256OfFile(alloc: Allocator, path: []const u8) ![32]u8 {
    const path_z = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(path_z);
    const fp = c.fopen(path_z.ptr, "rb") orelse return error.FileOpenFailed;
    defer _ = c.fclose(fp);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    return hasher.finalResult();
}

test "ARCH-036 TASK-036.5: FileStoreRepository streams piece_table and spilled_file with SHA-256 parity" {
    const alloc = std.testing.allocator;
    const out_dir = "zig-out/test_file_store_stream_036_5";
    defer {
        _ = c.remove("zig-out/test_file_store_stream_036_5/pt_out.bin");
        _ = c.remove("zig-out/test_file_store_stream_036_5/spill_src.bin");
        _ = c.remove("zig-out/test_file_store_stream_036_5/spill_out.bin");
    }

    var repo = try FileStoreRepository.init(alloc, out_dir);
    defer repo.deinit();

    // 1. Multi-chunk (> 256 KiB) piece_table stream
    const src_len: usize = 300 * 1024;
    const src_buf = try alloc.alloc(u8, src_len);
    defer alloc.free(src_buf);
    for (src_buf, 0..) |*b, i| b.* = @truncate((i *% 31) ^ 0x5A);

    const src_backing = parabellum.dataflow.StreamBacking{ .memory = src_buf };
    const pieces = [_]parabellum.dataflow.StreamPiece{
        .{ .inline_bytes = "FTYP_HDR" },
        .{ .source_slice = .{ .offset = 100, .len = 270 * 1024 } },
        .{ .zero_fill = 512 },
    };
    const pt_backing = try parabellum.dataflow.StreamBacking.buildPieceTable(alloc, &src_backing, &pieces);
    defer {
        alloc.free(pt_backing.piece_table.pieces);
        alloc.free(pt_backing.piece_table.cumulative_ends);
    }

    try repo.writePayload("pt_out", PayloadHandle.fromStreamBacking(&pt_backing));

    var expected_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    expected_hasher.update("FTYP_HDR");
    expected_hasher.update(src_buf[100 .. 100 + 270 * 1024]);
    var zeroes: [512]u8 = @splat(0);
    expected_hasher.update(&zeroes);
    const expected_pt_hash = expected_hasher.finalResult();
    const actual_pt_hash = try sha256OfFile(alloc, "zig-out/test_file_store_stream_036_5/pt_out.bin");
    try std.testing.expectEqualSlices(u8, &expected_pt_hash, &actual_pt_hash);

    // 2. Spilled file stream
    const spill_src = "zig-out/test_file_store_stream_036_5/spill_src.bin";
    const spill_z = try alloc.dupeSentinel(u8, spill_src, 0);
    defer alloc.free(spill_z);
    {
        const fp = c.fopen(spill_z.ptr, "wb") orelse return error.FileOpenFailed;
        defer _ = c.fclose(fp);
        const data = "SPILLED_STREAM_CONTENT_0123456789";
        _ = c.fwrite(data.ptr, 1, data.len, fp);
    }
    const spill_backing = parabellum.dataflow.StreamBacking{
        .spilled_file = .{ .path = spill_src, .size = 33 },
    };
    try repo.writePayload("spill_out", PayloadHandle.fromStreamBacking(&spill_backing));

    var spill_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    spill_hasher.update("SPILLED_STREAM_CONTENT_0123456789");
    const expected_spill_hash = spill_hasher.finalResult();
    const actual_spill_hash = try sha256OfFile(alloc, "zig-out/test_file_store_stream_036_5/spill_out.bin");
    try std.testing.expectEqualSlices(u8, &expected_spill_hash, &actual_spill_hash);
}

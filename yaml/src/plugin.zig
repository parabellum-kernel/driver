const std = @import("std");
const sdk = @import("flowdata_sdk");
const abi = sdk.abi;

const c_stdio = struct {
    const FILE = opaque {};
    const SEEK_SET: c_int = 0;
    const SEEK_END: c_int = 2;
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern "c" fn fclose(stream: *FILE) c_int;
    extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
    extern "c" fn ftell(stream: *FILE) c_long;
    extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
};

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    const fp = c_stdio.fopen(path_z.ptr, "rb") orelse return error.FileOpenFailed;
    defer _ = c_stdio.fclose(fp);

    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_END) != 0) return error.FileReadFailed;
    const raw_pos = c_stdio.ftell(fp);
    if (raw_pos < 0) return error.FileReadFailed;
    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_SET) != 0) return error.FileReadFailed;

    const len: usize = @intCast(raw_pos);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    if (len > 0) {
        if (c_stdio.fread(buf.ptr, 1, len, fp) != len) return error.FileReadFailed;
    }
    return buf;
}

fn stripComment(raw: []const u8) []const u8 {
    var in_quotes: ?u8 = null;
    for (raw, 0..) |ch, i| {
        if (in_quotes) |q| {
            if (ch == q) in_quotes = null;
        } else {
            if (ch == '"' or ch == '\'') {
                in_quotes = ch;
            } else if (ch == '#') {
                return std.mem.trimEnd(u8, raw[0..i], " \t\r");
            }
        }
    }
    return std.mem.trimEnd(u8, raw, " \t\r");
}

fn cleanScalarValue(allocator: std.mem.Allocator, raw_val: []const u8) ![]const u8 {
    var v = std.mem.trim(u8, raw_val, " \t\r");
    if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') {
        // Flatten inline YAML string list like `["es", "en"]` -> `"es,en"`
        const inner = v[1 .. v.len - 1];
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        var it = std.mem.splitScalar(u8, inner, ',');
        var first = true;
        while (it.next()) |elem| {
            var e = std.mem.trim(u8, elem, " \t");
            if (e.len >= 2 and ((e[0] == '"' and e[e.len - 1] == '"') or (e[0] == '\'' and e[e.len - 1] == '\''))) {
                e = e[1 .. e.len - 1];
            }
            if (e.len == 0) continue;
            if (!first) try out.append(allocator, ',');
            try out.appendSlice(allocator, e);
            first = false;
        }
        return try out.toOwnedSlice(allocator);
    }
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
        v = v[1 .. v.len - 1];
    }
    return try allocator.dupe(u8, v);
}

const ParsedRow = struct {
    fields: []abi.NamedField_ABI,
    enabled: bool = true,
};

/// Standalone C-ABI YAML File Driver (zero dependency on `flowdata` core source).
pub const YamlDriver = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const ParsedRow = &.{},

    pub fn create(params: []const abi.ConfigParam_ABI) !*YamlDriver {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var path: ?[]const u8 = null;
        for (params) |p| {
            if (std.mem.eql(u8, p.key.toSlice(), "path")) {
                path = p.value.toSlice();
                break;
            }
        }

        var rows_list = std.ArrayListUnmanaged(ParsedRow).empty;
        if (path) |p| {
            if (p.len > 0) {
                const bytes = readFileAlloc(alloc, p) catch &.{};
                if (bytes.len > 0) {
                    try parseYamlRows(alloc, bytes, &rows_list);
                }
            }
        }

        const self = try std.heap.c_allocator.create(YamlDriver);
        self.* = .{
            .arena = arena,
            .rows = try rows_list.toOwnedSlice(alloc),
        };
        return self;
    }

    fn parseYamlRows(
        alloc: std.mem.Allocator,
        bytes: []const u8,
        out_rows: *std.ArrayListUnmanaged(ParsedRow),
    ) !void {
        var cur_fields = std.ArrayListUnmanaged(abi.NamedField_ABI).empty;
        var cur_enabled = true;
        var in_item = false;

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const line = stripComment(raw_line);
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            if (std.mem.startsWith(u8, trimmed, "- ")) {
                if (in_item and cur_enabled and cur_fields.items.len > 0) {
                    try out_rows.append(alloc, .{
                        .fields = try cur_fields.toOwnedSlice(alloc),
                        .enabled = true,
                    });
                }
                cur_fields = .empty;
                cur_enabled = true;
                in_item = true;

                const rest = std.mem.trimStart(u8, trimmed[2..], " \t");
                if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
                    try appendKv(alloc, rest[0..colon], rest[colon + 1 ..], &cur_fields, &cur_enabled);
                }
            } else if (in_item) {
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                    try appendKv(alloc, trimmed[0..colon], trimmed[colon + 1 ..], &cur_fields, &cur_enabled);
                }
            }
        }

        if (in_item and cur_enabled and cur_fields.items.len > 0) {
            try out_rows.append(alloc, .{
                .fields = try cur_fields.toOwnedSlice(alloc),
                .enabled = true,
            });
        }
    }

    fn appendKv(
        alloc: std.mem.Allocator,
        raw_k: []const u8,
        raw_v: []const u8,
        fields: *std.ArrayListUnmanaged(abi.NamedField_ABI),
        enabled: *bool,
    ) !void {
        const k = std.mem.trim(u8, raw_k, " \t");
        if (k.len == 0) return;
        const val_str = try cleanScalarValue(alloc, raw_v);

        if (std.mem.eql(u8, k, "enabled")) {
            if (std.mem.eql(u8, val_str, "false")) {
                enabled.* = false;
            }
            const k_z = try alloc.dupeSentinel(u8, k, 0);
            try fields.append(alloc, .{
                .name = k_z,
                .value = abi.Value_ABI.fromBool(enabled.*),
            });
            return;
        }

        const k_z = try alloc.dupeSentinel(u8, k, 0);
        try fields.append(alloc, .{
            .name = k_z,
            .value = abi.Value_ABI.fromBytes(val_str),
        });
    }

    pub fn deinit(self: *YamlDriver) void {
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }

    pub fn recordCount(self: *const YamlDriver, _: []const u8) usize {
        return self.rows.len;
    }

    pub fn capabilities(_: *const YamlDriver) abi.DriverCapabilities_ABI {
        return .{
            .read = true,
            .write = true,
            .batch_emitter = true,
            .streaming_read = true,
        };
    }

    const YamlIter = struct {
        rows: []const ParsedRow,
        idx: usize = 0,

        fn next(handle: *abi.driver.RowIteratorHandle_ABI, out_row: *abi.RowView_ABI) callconv(.c) abi.HostError_ABI {
            const iter: *YamlIter = @ptrCast(@alignCast(handle));
            if (iter.idx >= iter.rows.len) return .end_of_stream;
            const row = iter.rows[iter.idx];
            iter.idx += 1;
            out_row.* = .{
                .fields_ptr = row.fields.ptr,
                .fields_len = row.fields.len,
            };
            return .ok;
        }

        fn deinitIter(handle: *abi.driver.RowIteratorHandle_ABI) callconv(.c) void {
            const iter: *YamlIter = @ptrCast(@alignCast(handle));
            std.heap.c_allocator.destroy(iter);
        }

        const vtable = abi.driver.RowIteratorVTable_ABI{
            .next = next,
            .deinit = deinitIter,
        };
    };

    pub fn readStream(self: *YamlDriver, _: abi.driver.ReadSpec_ABI) !abi.driver.RowIterator_ABI {
        const iter = try std.heap.c_allocator.create(YamlIter);
        iter.* = .{ .rows = self.rows };
        return .{
            .handle = @ptrCast(iter),
            .vtable = &YamlIter.vtable,
        };
    }
};

pub const manifest = sdk.sdk.defineDriver(YamlDriver, .{
    .name = "yaml",
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "yaml driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

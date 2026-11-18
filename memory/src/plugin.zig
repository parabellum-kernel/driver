const std = @import("std");
const sdk = @import("parabellum_sdk");
const abi = sdk.abi;

const StoredField = struct {
    name_z: [:0]const u8,
    value: abi.Value_ABI,
    owned_bytes: ?[]u8 = null,
};

const StoredRow = struct {
    fields: []StoredField,
    abi_fields: []abi.NamedField_ABI,
};

const TableStore = struct {
    rows: std.ArrayListUnmanaged(StoredRow) = .empty,

    fn deinit(self: *TableStore, allocator: std.mem.Allocator) void {
        for (self.rows.items) |row| {
            for (row.fields) |f| {
                allocator.free(f.name_z);
                if (f.owned_bytes) |b| allocator.free(b);
            }
            allocator.free(row.fields);
            allocator.free(row.abi_fields);
        }
        self.rows.deinit(allocator);
    }
};

const MemoryRowIterator = struct {
    allocator: std.mem.Allocator,
    rows: []const StoredRow,
    index: usize = 0,

    fn next(handle: *abi.driver.RowIteratorHandle_ABI, out_row: *abi.RowView_ABI) callconv(.c) abi.HostError_ABI {
        const self: *MemoryRowIterator = @ptrCast(@alignCast(handle));
        if (self.index >= self.rows.len) return .end_of_stream;
        const row = self.rows[self.index];
        self.index += 1;
        out_row.* = .{
            .fields_ptr = if (row.abi_fields.len > 0) row.abi_fields.ptr else null,
            .fields_len = row.abi_fields.len,
        };
        return .ok;
    }

    fn deinit(handle: *abi.driver.RowIteratorHandle_ABI) callconv(.c) void {
        const self: *MemoryRowIterator = @ptrCast(@alignCast(handle));
        self.allocator.destroy(self);
    }

    const vtable = abi.driver.RowIteratorVTable_ABI{
        .next = next,
        .deinit = deinit,
    };
};

/// Standalone C-ABI Memory Driver (zero dependency on `parabellum` core source).
pub const MemoryDriver = struct {
    allocator: std.mem.Allocator,
    tables: std.StringHashMapUnmanaged(TableStore) = .{},

    pub fn create(_: []const abi.ConfigParam_ABI) !*MemoryDriver {
        const self = try std.heap.c_allocator.create(MemoryDriver);
        self.* = .{ .allocator = std.heap.c_allocator };
        return self;
    }

    pub fn deinit(self: *MemoryDriver) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn recordCount(self: *const MemoryDriver, table: []const u8) usize {
        if (self.tables.get(table)) |store| {
            return store.rows.items.len;
        }
        return 0;
    }

    pub fn writeRow(self: *MemoryDriver, spec: abi.driver.WriteSpec_ABI) !void {
        const table_name = spec.table.toSlice();
        const gop = try self.tables.getOrPut(self.allocator, table_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, table_name);
            gop.value_ptr.* = .{};
        }

        const in_fields = spec.fieldsSlice();
        if (in_fields.len > 0) {
            const fields = try self.allocator.alloc(StoredField, in_fields.len);
            errdefer self.allocator.free(fields);
            const abi_fields = try self.allocator.alloc(abi.NamedField_ABI, in_fields.len);
            errdefer self.allocator.free(abi_fields);

            var init_count: usize = 0;
            errdefer {
                for (fields[0..init_count]) |f| {
                    self.allocator.free(f.name_z);
                    if (f.owned_bytes) |b| self.allocator.free(b);
                }
            }

            for (in_fields, 0..) |f, i| {
                const name_z = try self.allocator.dupeSentinel(u8, std.mem.span(f.name), 0);
                var owned_bytes: ?[]u8 = null;
                var val = f.value;
                if (val.tag == .bytes_val) {
                    const duped = try self.allocator.dupe(u8, val.payload.bytes.toSlice());
                    owned_bytes = duped;
                    val.payload = .{ .bytes = abi.Slice_ABI.from(duped) };
                }
                fields[i] = .{
                    .name_z = name_z,
                    .value = val,
                    .owned_bytes = owned_bytes,
                };
                abi_fields[i] = .{
                    .name = name_z.ptr,
                    .value = val,
                };
                init_count += 1;
            }
            try gop.value_ptr.rows.append(self.allocator, .{
                .fields = fields,
                .abi_fields = abi_fields,
            });
        } else if (spec.raw_bytes.len > 0) {
            const fields = try self.allocator.alloc(StoredField, 1);
            errdefer self.allocator.free(fields);
            const abi_fields = try self.allocator.alloc(abi.NamedField_ABI, 1);
            errdefer self.allocator.free(abi_fields);

            const name_z = try self.allocator.dupeSentinel(u8, "data", 0);
            errdefer self.allocator.free(name_z);
            const duped = try self.allocator.dupe(u8, spec.raw_bytes.toSlice());
            const val = abi.Value_ABI{
                .tag = .bytes_val,
                .payload = .{ .bytes = abi.Slice_ABI.from(duped) },
            };
            fields[0] = .{ .name_z = name_z, .value = val, .owned_bytes = duped };
            abi_fields[0] = .{ .name = name_z.ptr, .value = val };
            try gop.value_ptr.rows.append(self.allocator, .{
                .fields = fields,
                .abi_fields = abi_fields,
            });
        }
    }

    pub fn readStream(self: *MemoryDriver, spec: abi.driver.ReadSpec_ABI) !abi.driver.RowIterator_ABI {
        const table_name = spec.table.toSlice();
        const rows: []const StoredRow = if (self.tables.get(table_name)) |store|
            store.rows.items
        else
            &.{};
        const iter = try self.allocator.create(MemoryRowIterator);
        iter.* = .{
            .allocator = self.allocator,
            .rows = rows,
        };
        return .{
            .handle = @ptrCast(iter),
            .vtable = &MemoryRowIterator.vtable,
        };
    }

    pub fn capabilities(_: *const MemoryDriver) abi.DriverCapabilities_ABI {
        return .{
            .read = true,
            .write = true,
            .streaming_read = true,
            .streaming_write = true,
            .transactions = false,
        };
    }
};

pub const manifest = sdk.sdk.defineDriver(MemoryDriver, .{
    .name = "memory",
    .version = .{ .major = 1, .minor = 3, .patch = 1 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "memory driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

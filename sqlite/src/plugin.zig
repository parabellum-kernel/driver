const std = @import("std");
const sdk = @import("flowdata_sdk");
const abi = sdk.abi;

const c = @import("sqlite3_c");

const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

fn ensureParentDirs(path: []const u8) void {
    if (std.mem.eql(u8, path, ":memory:")) return;
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (last_slash == 0) return;
    const dir_path = path[0..last_slash];

    var buf: [4096]u8 = undefined;
    if (dir_path.len >= buf.len) return;

    var i: usize = 0;
    while (i <= dir_path.len) : (i += 1) {
        if (i == dir_path.len or dir_path[i] == '/') {
            if (i > 0) {
                @memcpy(buf[0..i], dir_path[0..i]);
                buf[i] = 0;
                _ = std.c.mkdir(@ptrCast(&buf[0]), 0o755);
            }
        }
    }
}

fn sqlTypeForAbiTag(tag: abi.ValueTag_ABI) []const u8 {
    return switch (tag) {
        .int_val, .uint_val, .bool_val => "INTEGER",
        .float_val => "REAL",
        .bytes_val, .null_val => "TEXT",
    };
}

fn appendQuotedIdent(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, ident: []const u8) !void {
    try buf.append(allocator, '"');
    for (ident) |ch| {
        if (ch == '"') {
            try buf.appendSlice(allocator, "\"\"");
        } else {
            try buf.append(allocator, ch);
        }
    }
    try buf.append(allocator, '"');
}

const SqliteRowIterator = struct {
    allocator: std.mem.Allocator,
    stmt: ?*c.sqlite3_stmt,
    row_arena: std.heap.ArenaAllocator,
    fields_buf: []abi.NamedField_ABI = &.{},

    fn next(handle: *abi.driver.RowIteratorHandle_ABI, out_row: *abi.RowView_ABI) callconv(.c) abi.HostError_ABI {
        const self: *SqliteRowIterator = @ptrCast(@alignCast(handle));
        const stmt = self.stmt orelse return .end_of_stream;

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return .end_of_stream;
        if (rc != c.SQLITE_ROW) return .internal_error;

        _ = self.row_arena.reset(.retain_capacity);
        const arena = self.row_arena.allocator();

        const col_count_i = c.sqlite3_column_count(stmt);
        if (col_count_i <= 0) {
            out_row.* = .{ .fields_ptr = null, .fields_len = 0 };
            return .ok;
        }
        const col_count: usize = @intCast(col_count_i);
        const fields = arena.alloc(abi.NamedField_ABI, col_count) catch return .out_of_memory;

        for (0..col_count) |idx| {
            const col_idx: c_int = @intCast(idx);
            const raw_name = c.sqlite3_column_name(stmt, col_idx);
            const name_slice = if (raw_name != null) std.mem.span(raw_name) else "col";
            const name_z = arena.dupeSentinel(u8, name_slice, 0) catch return .out_of_memory;

            const col_type = c.sqlite3_column_type(stmt, col_idx);
            const val: abi.Value_ABI = switch (col_type) {
                c.SQLITE_INTEGER => .{
                    .tag = .int_val,
                    .payload = .{ .i = c.sqlite3_column_int64(stmt, col_idx) },
                },
                c.SQLITE_FLOAT => .{
                    .tag = .float_val,
                    .payload = .{ .f = c.sqlite3_column_double(stmt, col_idx) },
                },
                c.SQLITE_TEXT => blk: {
                    const ptr = c.sqlite3_column_text(stmt, col_idx);
                    const len_i = c.sqlite3_column_bytes(stmt, col_idx);
                    const len: usize = if (len_i > 0) @intCast(len_i) else 0;
                    const duped = if (ptr != null and len > 0)
                        arena.dupe(u8, @as([*]const u8, @ptrCast(ptr))[0..len]) catch return .out_of_memory
                    else
                        "";
                    break :blk .{
                        .tag = .bytes_val,
                        .payload = .{ .bytes = abi.Slice_ABI.from(duped) },
                    };
                },
                c.SQLITE_BLOB => blk: {
                    const ptr = c.sqlite3_column_blob(stmt, col_idx);
                    const len_i = c.sqlite3_column_bytes(stmt, col_idx);
                    const len: usize = if (len_i > 0) @intCast(len_i) else 0;
                    const duped = if (ptr != null and len > 0)
                        arena.dupe(u8, @as([*]const u8, @ptrCast(ptr))[0..len]) catch return .out_of_memory
                    else
                        &.{};
                    break :blk .{
                        .tag = .bytes_val,
                        .payload = .{ .bytes = abi.Slice_ABI.from(duped) },
                    };
                },
                else => .{
                    .tag = .null_val,
                    .payload = .{ .i = 0 },
                },
            };

            fields[idx] = .{
                .name = name_z.ptr,
                .value = val,
            };
        }

        out_row.* = .{
            .fields_ptr = fields.ptr,
            .fields_len = fields.len,
        };
        return .ok;
    }

    fn deinit(handle: *abi.driver.RowIteratorHandle_ABI) callconv(.c) void {
        const self: *SqliteRowIterator = @ptrCast(@alignCast(handle));
        if (self.stmt) |s| _ = c.sqlite3_finalize(s);
        self.row_arena.deinit();
        self.allocator.destroy(self);
    }

    const vtable = abi.driver.RowIteratorVTable_ABI{
        .next = next,
        .deinit = deinit,
    };
};

/// Standalone C-ABI SQLite Driver (zero dependency on `flowdata` core source).
pub const SqliteDriver = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,

    pub fn create(params: []const abi.ConfigParam_ABI) !*SqliteDriver {
        const alloc = std.heap.c_allocator;
        var path: []const u8 = ":memory:";
        for (params) |p| {
            if (std.mem.eql(u8, p.key.toSlice(), "path")) {
                const v = p.value.toSlice();
                if (v.len > 0) path = v;
            }
        }

        ensureParentDirs(path);
        const path_z = try alloc.dupeSentinel(u8, path, 0);
        defer alloc.free(path_z);

        var db_opt: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path_z.ptr, &db_opt) != c.SQLITE_OK) {
            if (db_opt) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        const db = db_opt orelse return error.SqliteOpenFailed;
        errdefer _ = c.sqlite3_close(db);

        _ = c.sqlite3_busy_timeout(db, 5000);
        if (!std.mem.eql(u8, path, ":memory:")) {
            _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);
        }

        const self = try alloc.create(SqliteDriver);
        self.* = .{
            .allocator = alloc,
            .db = db,
        };
        return self;
    }

    pub fn deinit(self: *SqliteDriver) void {
        _ = c.sqlite3_close(self.db);
        self.allocator.destroy(self);
    }

    fn execZ(self: *SqliteDriver, sql_z: [:0]const u8) !void {
        if (c.sqlite3_exec(self.db, sql_z.ptr, null, null, null) != c.SQLITE_OK) {
            return error.SqliteExecFailed;
        }
    }

    fn ensureTableAndColumns(self: *SqliteDriver, table: []const u8, fields: []const abi.NamedField_ABI) !void {
        var sql: std.ArrayListUnmanaged(u8) = .empty;
        defer sql.deinit(self.allocator);

        try sql.appendSlice(self.allocator, "CREATE TABLE IF NOT EXISTS ");
        try appendQuotedIdent(&sql, self.allocator, table);
        try sql.appendSlice(self.allocator, " (");
        for (fields, 0..) |f, i| {
            if (i > 0) try sql.appendSlice(self.allocator, ", ");
            try appendQuotedIdent(&sql, self.allocator, std.mem.span(f.name));
            try sql.append(self.allocator, ' ');
            try sql.appendSlice(self.allocator, sqlTypeForAbiTag(f.value.tag));
        }
        try sql.appendSlice(self.allocator, ");");
        try sql.append(self.allocator, 0);

        const sql_z: [:0]const u8 = sql.items[0 .. sql.items.len - 1 :0];
        try self.execZ(sql_z);
    }

    fn addMissingColumns(self: *SqliteDriver, table: []const u8, fields: []const abi.NamedField_ABI) !void {
        for (fields) |f| {
            var sql: std.ArrayListUnmanaged(u8) = .empty;
            defer sql.deinit(self.allocator);

            try sql.appendSlice(self.allocator, "ALTER TABLE ");
            try appendQuotedIdent(&sql, self.allocator, table);
            try sql.appendSlice(self.allocator, " ADD COLUMN ");
            try appendQuotedIdent(&sql, self.allocator, std.mem.span(f.name));
            try sql.append(self.allocator, ' ');
            try sql.appendSlice(self.allocator, sqlTypeForAbiTag(f.value.tag));
            try sql.appendSlice(self.allocator, ";");
            try sql.append(self.allocator, 0);

            const sql_z: [:0]const u8 = sql.items[0 .. sql.items.len - 1 :0];
            _ = c.sqlite3_exec(self.db, sql_z.ptr, null, null, null);
        }
    }

    pub fn writeRow(self: *SqliteDriver, spec: abi.driver.WriteSpec_ABI) !void {
        const table = spec.table.toSlice();
        if (table.len == 0) return error.InvalidTableName;

        const fields = spec.fieldsSlice();
        if (fields.len > 0) {
            try self.ensureTableAndColumns(table, fields);

            var sql: std.ArrayListUnmanaged(u8) = .empty;
            defer sql.deinit(self.allocator);

            const verb = switch (spec.mode) {
                .upsert, .replace => "INSERT OR REPLACE INTO ",
                .insert, .append => "INSERT INTO ",
            };
            try sql.appendSlice(self.allocator, verb);
            try appendQuotedIdent(&sql, self.allocator, table);
            try sql.appendSlice(self.allocator, " (");
            for (fields, 0..) |f, i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                try appendQuotedIdent(&sql, self.allocator, std.mem.span(f.name));
            }
            try sql.appendSlice(self.allocator, ") VALUES (");
            for (0..fields.len) |i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                try sql.append(self.allocator, '?');
            }
            try sql.appendSlice(self.allocator, ");");
            try sql.append(self.allocator, 0);

            const sql_z: [:0]const u8 = sql.items[0 .. sql.items.len - 1 :0];
            var stmt_opt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, @intCast(sql_z.len), &stmt_opt, null) != c.SQLITE_OK) {
                try self.addMissingColumns(table, fields);
                if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, @intCast(sql_z.len), &stmt_opt, null) != c.SQLITE_OK) {
                    return error.SqlitePrepareFailed;
                }
            }
            const stmt = stmt_opt orelse return error.SqlitePrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);

            for (fields, 0..) |f, i| {
                const bind_idx: c_int = @intCast(i + 1);
                const rc = switch (f.value.tag) {
                    .null_val => c.sqlite3_bind_null(stmt, bind_idx),
                    .int_val => c.sqlite3_bind_int64(stmt, bind_idx, f.value.payload.i),
                    .uint_val => c.sqlite3_bind_int64(stmt, bind_idx, @bitCast(f.value.payload.u)),
                    .bool_val => c.sqlite3_bind_int64(stmt, bind_idx, if (f.value.payload.b) 1 else 0),
                    .float_val => c.sqlite3_bind_double(stmt, bind_idx, f.value.payload.f),
                    .bytes_val => blk: {
                        const s = f.value.payload.bytes.toSlice();
                        if (s.len == 0) {
                            break :blk c.sqlite3_bind_text(stmt, bind_idx, "", 0, SQLITE_TRANSIENT);
                        }
                        break :blk c.sqlite3_bind_text(stmt, bind_idx, s.ptr, @intCast(s.len), SQLITE_TRANSIENT);
                    },
                };
                if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
            }

            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
                return error.SqliteStepFailed;
            }
            return;
        }

        if (spec.raw_bytes.len > 0) {
            var create_sql: std.ArrayListUnmanaged(u8) = .empty;
            defer create_sql.deinit(self.allocator);
            try create_sql.appendSlice(self.allocator, "CREATE TABLE IF NOT EXISTS ");
            try appendQuotedIdent(&create_sql, self.allocator, table);
            try create_sql.appendSlice(self.allocator, " (\"data\" BLOB);\x00");
            try self.execZ(create_sql.items[0 .. create_sql.items.len - 1 :0]);

            var ins_sql: std.ArrayListUnmanaged(u8) = .empty;
            defer ins_sql.deinit(self.allocator);
            try ins_sql.appendSlice(self.allocator, "INSERT INTO ");
            try appendQuotedIdent(&ins_sql, self.allocator, table);
            try ins_sql.appendSlice(self.allocator, " (\"data\") VALUES (?1);\x00");
            const ins_z: [:0]const u8 = ins_sql.items[0 .. ins_sql.items.len - 1 :0];

            var stmt_opt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, ins_z.ptr, @intCast(ins_z.len), &stmt_opt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            const stmt = stmt_opt orelse return error.SqlitePrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);

            const raw = spec.raw_bytes.toSlice();
            if (c.sqlite3_bind_blob(stmt, 1, raw.ptr, @intCast(raw.len), SQLITE_TRANSIENT) != c.SQLITE_OK) {
                return error.SqliteBindFailed;
            }
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
                return error.SqliteStepFailed;
            }
        }
    }

    pub fn readStream(self: *SqliteDriver, spec: abi.driver.ReadSpec_ABI) !abi.driver.RowIterator_ABI {
        const table = spec.table.toSlice();
        var sql: std.ArrayListUnmanaged(u8) = .empty;
        defer sql.deinit(self.allocator);

        try sql.appendSlice(self.allocator, "SELECT * FROM ");
        try appendQuotedIdent(&sql, self.allocator, table);
        if (spec.limit > 0) {
            try sql.print(self.allocator, " LIMIT {d} OFFSET {d}", .{ spec.limit, spec.offset });
        }
        try sql.appendSlice(self.allocator, ";\x00");
        const sql_z: [:0]const u8 = sql.items[0 .. sql.items.len - 1 :0];

        var stmt_opt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, @intCast(sql_z.len), &stmt_opt, null) != c.SQLITE_OK) {
            // Table may not exist yet; return empty iterator.
            stmt_opt = null;
        }

        const iter = try self.allocator.create(SqliteRowIterator);
        iter.* = .{
            .allocator = self.allocator,
            .stmt = stmt_opt,
            .row_arena = std.heap.ArenaAllocator.init(self.allocator),
        };
        return .{
            .handle = @ptrCast(iter),
            .vtable = &SqliteRowIterator.vtable,
        };
    }

    pub fn recordCount(self: *const SqliteDriver, table: []const u8) usize {
        var sql: std.ArrayListUnmanaged(u8) = .empty;
        defer sql.deinit(self.allocator);

        sql.appendSlice(self.allocator, "SELECT COUNT(*) FROM ") catch return 0;
        appendQuotedIdent(&sql, self.allocator, table) catch return 0;
        sql.appendSlice(self.allocator, ";\x00") catch return 0;
        const sql_z: [:0]const u8 = sql.items[0 .. sql.items.len - 1 :0];

        var stmt_opt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, @intCast(sql_z.len), &stmt_opt, null) != c.SQLITE_OK) {
            return 0;
        }
        const stmt = stmt_opt orelse return 0;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        const cnt = c.sqlite3_column_int64(stmt, 0);
        return if (cnt < 0) 0 else @intCast(cnt);
    }

    pub fn beginTx(self: *SqliteDriver) !void {
        try self.execZ("BEGIN IMMEDIATE;");
    }

    pub fn commit(self: *SqliteDriver) !void {
        try self.execZ("COMMIT;");
    }

    pub fn rollback(self: *SqliteDriver) !void {
        try self.execZ("ROLLBACK;");
    }

    pub fn capabilities(_: *const SqliteDriver) abi.DriverCapabilities_ABI {
        return .{
            .read = true,
            .write = true,
            .streaming_read = true,
            .streaming_write = true,
            .schema_ddl = true,
            .transactions = true,
            .savepoints = true,
            .partial_update = true,
            .filter_pushdown = true,
            .order_pushdown = true,
            .relational_constraints = true,
        };
    }
};

pub const manifest = sdk.sdk.defineDriver(SqliteDriver, .{
    .name = "sqlite",
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "sqlite driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

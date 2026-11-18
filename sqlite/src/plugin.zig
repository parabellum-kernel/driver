const std = @import("std");
const sdk = @import("parabellum_sdk");
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

/// Standalone C-ABI SQLite Driver (zero dependency on `parabellum` core source).
pub const SqliteDriver = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    blob_columns: std.StringHashMapUnmanaged(void) = .empty,

    pub fn create(params: []const abi.ConfigParam_ABI) !*SqliteDriver {
        const alloc = std.heap.c_allocator;
        var path: []const u8 = ":memory:";
        var schema_path: []const u8 = "";
        for (params) |p| {
            const k = p.key.toSlice();
            const v = p.value.toSlice();
            if (std.mem.eql(u8, k, "path")) {
                if (v.len > 0) path = v;
            } else if (std.mem.eql(u8, k, "schema")) {
                if (v.len > 0) schema_path = v;
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
        _ = c.sqlite3_exec(db, "PRAGMA foreign_keys = ON;", null, null, null);
        if (!std.mem.eql(u8, path, ":memory:")) {
            _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);
        }

        const self = try alloc.create(SqliteDriver);
        self.* = .{
            .allocator = alloc,
            .db = db,
        };
        errdefer self.deinit();

        if (schema_path.len > 0) {
            try self.provisionSchemaFromFile(schema_path);
        }
        return self;
    }

    pub fn deinit(self: *SqliteDriver) void {
        var it = self.blob_columns.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.blob_columns.deinit(self.allocator);
        _ = c.sqlite3_close(self.db);
        self.allocator.destroy(self);
    }

    fn execZ(self: *SqliteDriver, sql_z: [:0]const u8) !void {
        if (c.sqlite3_exec(self.db, sql_z.ptr, null, null, null) != c.SQLITE_OK) {
            return error.SqliteExecFailed;
        }
    }

    fn markBlobColumn(self: *SqliteDriver, table: []const u8, col: []const u8) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ table, col });
        errdefer self.allocator.free(key);
        const gop = try self.blob_columns.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
        }
    }

    fn isBlobColumn(self: *const SqliteDriver, table: []const u8, col: []const u8) bool {
        var buf: [256]u8 = undefined;
        if (table.len + 1 + col.len <= buf.len) {
            @memcpy(buf[0..table.len], table);
            buf[table.len] = 0;
            @memcpy(buf[table.len + 1 .. table.len + 1 + col.len], col);
            return self.blob_columns.contains(buf[0 .. table.len + 1 + col.len]);
        }
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ table, col }) catch return false;
        defer self.allocator.free(key);
        return self.blob_columns.contains(key);
    }

    fn mapYamlSqlType(t: []const u8) []const u8 {
        if (std.mem.eql(u8, t, "int64") or std.mem.eql(u8, t, "uint64") or std.mem.eql(u8, t, "bool")) {
            return "INTEGER";
        }
        if (std.mem.eql(u8, t, "float64")) return "REAL";
        if (std.mem.eql(u8, t, "blob") or std.mem.eql(u8, t, "bytes")) return "BLOB";
        return "TEXT";
    }

    fn recreateIfIncompatiblePk(self: *SqliteDriver, table: []const u8, pk_col: ?[]const u8) !void {
        const expected_pk = pk_col orelse return;
        var sql: std.ArrayListUnmanaged(u8) = .empty;
        defer sql.deinit(self.allocator);

        try sql.appendSlice(self.allocator, "PRAGMA table_info(");
        try appendQuotedIdent(&sql, self.allocator, table);
        try sql.appendSlice(self.allocator, ");\x00");
        const sql_z: [:0]const u8 = sql.items[0 .. sql.items.len - 1 :0];

        var stmt_opt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, @intCast(sql_z.len), &stmt_opt, null) != c.SQLITE_OK) {
            return;
        }
        const stmt = stmt_opt orelse return;
        defer _ = c.sqlite3_finalize(stmt);

        var has_rows = false;
        var pk_matches = false;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            has_rows = true;
            const name_ptr = c.sqlite3_column_text(stmt, 1) orelse continue;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));
            const pk_flag = c.sqlite3_column_int(stmt, 5);
            if (pk_flag > 0 and std.mem.eql(u8, name, expected_pk)) {
                pk_matches = true;
            }
        }

        if (has_rows and !pk_matches) {
            var drop_sql: std.ArrayListUnmanaged(u8) = .empty;
            defer drop_sql.deinit(self.allocator);
            try drop_sql.appendSlice(self.allocator, "DROP TABLE IF EXISTS ");
            try appendQuotedIdent(&drop_sql, self.allocator, table);
            try drop_sql.appendSlice(self.allocator, ";\x00");
            try self.execZ(drop_sql.items[0 .. drop_sql.items.len - 1 :0]);
        }
    }

    const YamlColDef = struct {
        name: []const u8,
        sql_type: []const u8 = "TEXT",
        is_blob: bool = false,
        pk: bool = false,
        nullable: bool = false,
        default_val: ?[]const u8 = null,
        ref: ?[]const u8 = null,
        on_delete: ?[]const u8 = null,
    };

    fn flushTableDdl(
        self: *SqliteDriver,
        table: []const u8,
        cols: []const YamlColDef,
        indexes: []const []const u8,
        primary_keys: []const []const u8,
    ) !void {
        if (table.len == 0 or cols.len == 0) return;

        var pk_col: ?[]const u8 = null;
        for (cols) |col| {
            if (col.pk) {
                pk_col = col.name;
                break;
            }
        }
        try self.recreateIfIncompatiblePk(table, pk_col);

        var sql: std.ArrayListUnmanaged(u8) = .empty;
        defer sql.deinit(self.allocator);

        try sql.appendSlice(self.allocator, "CREATE TABLE IF NOT EXISTS ");
        try appendQuotedIdent(&sql, self.allocator, table);
        try sql.appendSlice(self.allocator, " (");

        for (cols, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(self.allocator, ", ");
            try appendQuotedIdent(&sql, self.allocator, col.name);
            try sql.append(self.allocator, ' ');
            try sql.appendSlice(self.allocator, col.sql_type);
            if (col.pk) {
                try sql.appendSlice(self.allocator, " PRIMARY KEY");
            } else if (!col.nullable) {
                try sql.appendSlice(self.allocator, " NOT NULL");
            }
            if (col.default_val) |dv| {
                try sql.appendSlice(self.allocator, " DEFAULT ");
                try sql.appendSlice(self.allocator, dv);
            }
            if (col.ref) |ref_str| {
                if (std.mem.indexOfScalar(u8, ref_str, '.')) |dot_idx| {
                    const ref_tbl = ref_str[0..dot_idx];
                    const ref_col = ref_str[dot_idx + 1 ..];
                    try sql.appendSlice(self.allocator, " REFERENCES ");
                    try appendQuotedIdent(&sql, self.allocator, ref_tbl);
                    try sql.append(self.allocator, '(');
                    try appendQuotedIdent(&sql, self.allocator, ref_col);
                    try sql.append(self.allocator, ')');
                    if (col.on_delete) |od| {
                        if (std.ascii.eqlIgnoreCase(od, "cascade")) {
                            try sql.appendSlice(self.allocator, " ON DELETE CASCADE");
                        }
                    }
                }
            }
            if (col.is_blob) {
                try self.markBlobColumn(table, col.name);
            }
        }
        if (primary_keys.len > 0) {
            try sql.appendSlice(self.allocator, ", PRIMARY KEY (");
            for (primary_keys, 0..) |pk_name, i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                try appendQuotedIdent(&sql, self.allocator, pk_name);
            }
            try sql.append(self.allocator, ')');
        }
        try sql.appendSlice(self.allocator, ");\x00");
        try self.execZ(sql.items[0 .. sql.items.len - 1 :0]);

        for (indexes) |idx_col| {
            var idx_sql: std.ArrayListUnmanaged(u8) = .empty;
            defer idx_sql.deinit(self.allocator);
            const idx_name = try std.fmt.allocPrint(self.allocator, "idx_{s}_{s}", .{ table, idx_col });
            defer self.allocator.free(idx_name);

            try idx_sql.appendSlice(self.allocator, "CREATE INDEX IF NOT EXISTS ");
            try appendQuotedIdent(&idx_sql, self.allocator, idx_name);
            try idx_sql.appendSlice(self.allocator, " ON ");
            try appendQuotedIdent(&idx_sql, self.allocator, table);
            try idx_sql.appendSlice(self.allocator, " (");
            try appendQuotedIdent(&idx_sql, self.allocator, idx_col);
            try idx_sql.appendSlice(self.allocator, ");\x00");
            try self.execZ(idx_sql.items[0 .. idx_sql.items.len - 1 :0]);
        }
    }

    fn stripYamlQuotes(v: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, v, " \t\r");
        if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
            return trimmed[1 .. trimmed.len - 1];
        }
        return trimmed;
    }

    fn parseInlineColAttrs(name: []const u8, rhs: []const u8) YamlColDef {
        var col = YamlColDef{ .name = name };
        const inner = std.mem.trim(u8, rhs, " \t\r{}");
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |raw_kv| {
            const kv = std.mem.trim(u8, raw_kv, " \t");
            const colon = std.mem.indexOfScalar(u8, kv, ':') orelse continue;
            const k = std.mem.trim(u8, kv[0..colon], " \t");
            const v_raw = std.mem.trim(u8, kv[colon + 1 ..], " \t");
            const v = stripYamlQuotes(v_raw);
            if (std.mem.eql(u8, k, "type")) {
                col.sql_type = mapYamlSqlType(v);
                col.is_blob = std.mem.eql(u8, v, "blob") or std.mem.eql(u8, v, "bytes");
            } else if (std.mem.eql(u8, k, "pk")) {
                col.pk = std.mem.eql(u8, v, "true");
            } else if (std.mem.eql(u8, k, "nullable")) {
                col.nullable = std.mem.eql(u8, v, "true");
            } else if (std.mem.eql(u8, k, "default")) {
                col.default_val = v;
            } else if (std.mem.eql(u8, k, "ref")) {
                col.ref = v;
            } else if (std.mem.eql(u8, k, "on_delete")) {
                col.on_delete = v;
            }
        }
        return col;
    }

    fn provisionSchemaFromFile(self: *SqliteDriver, schema_path: []const u8) !void {
        const path_z = try self.allocator.dupeSentinel(u8, schema_path, 0);
        defer self.allocator.free(path_z);

        const fp = std.c.fopen(path_z.ptr, "rb") orelse return error.SchemaFileNotFound;
        defer _ = std.c.fclose(fp);

        var content_list: std.ArrayListUnmanaged(u8) = .empty;
        defer content_list.deinit(self.allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.c.fread(&buf, 1, buf.len, fp);
            if (n == 0) break;
            try content_list.appendSlice(self.allocator, buf[0..n]);
        }
        const content = content_list.items;

        var in_schemas = false;
        var table_indent: ?usize = null;
        var current_table: []const u8 = "";
        var section: enum { none, columns, indexes, primary_key } = .none;

        var cols: std.ArrayListUnmanaged(YamlColDef) = .empty;
        defer cols.deinit(self.allocator);
        var indexes: std.ArrayListUnmanaged([]const u8) = .empty;
        defer indexes.deinit(self.allocator);
        var pks: std.ArrayListUnmanaged([]const u8) = .empty;
        defer pks.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const no_cr = std.mem.trimEnd(u8, raw_line, "\r");
            const trimmed = std.mem.trimStart(u8, no_cr, " ");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const indent = no_cr.len - trimmed.len;
            if (!in_schemas) {
                if (indent == 0 and std.mem.startsWith(u8, trimmed, "schemas:")) {
                    in_schemas = true;
                }
                continue;
            }
            if (indent == 0) break;

            // Detect table_indent: tables are 2 levels under `schemas:` (e.g. schemas -> catalog -> vfs_meta)
            // or 1 level if no namespace. We detect it when we see `columns:` at `table_indent + 2`.
            if (std.mem.eql(u8, trimmed, "columns:")) {
                if (table_indent == null and indent >= 2) {
                    table_indent = indent - 2;
                }
                section = .columns;
                continue;
            }
            if (std.mem.eql(u8, trimmed, "indexes:")) {
                section = .indexes;
                continue;
            }
            if (std.mem.eql(u8, trimmed, "primary_key:")) {
                section = .primary_key;
                continue;
            }

            if (table_indent) |ti| {
                if (indent == ti and std.mem.endsWith(u8, trimmed, ":")) {
                    try self.flushTableDdl(current_table, cols.items, indexes.items, pks.items);
                    cols.clearRetainingCapacity();
                    indexes.clearRetainingCapacity();
                    pks.clearRetainingCapacity();
                    current_table = trimmed[0 .. trimmed.len - 1];
                    section = .none;
                    continue;
                }
                if (indent < ti) {
                    try self.flushTableDdl(current_table, cols.items, indexes.items, pks.items);
                    cols.clearRetainingCapacity();
                    indexes.clearRetainingCapacity();
                    pks.clearRetainingCapacity();
                    current_table = "";
                    section = .none;
                    continue;
                }
            } else if (std.mem.endsWith(u8, trimmed, ":")) {
                // Track candidate table name until we see `columns:`
                current_table = trimmed[0 .. trimmed.len - 1];
                continue;
            }

            if (section == .columns) {
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                    const col_name = std.mem.trim(u8, trimmed[0..colon], " \t");
                    const rhs = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                    try cols.append(self.allocator, parseInlineColAttrs(col_name, rhs));
                }
            } else if (section == .indexes) {
                if (std.mem.startsWith(u8, trimmed, "- ")) {
                    const idx_col = std.mem.trim(u8, trimmed[2..], " \t");
                    if (idx_col.len > 0) {
                        try indexes.append(self.allocator, idx_col);
                    }
                }
            } else if (section == .primary_key) {
                if (std.mem.startsWith(u8, trimmed, "- ")) {
                    const pk_col = std.mem.trim(u8, trimmed[2..], " \t");
                    if (pk_col.len > 0) {
                        try pks.append(self.allocator, pk_col);
                    }
                }
            }
        }

        try self.flushTableDdl(current_table, cols.items, indexes.items, pks.items);
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
        if (fields.len > 0 and std.mem.eql(u8, table, "clear_table")) {
            if (fields[0].value.tag == .bytes_val) {
                const target_table = fields[0].value.payload.bytes.toSlice();
                var clr_sql: std.ArrayListUnmanaged(u8) = .empty;
                defer clr_sql.deinit(self.allocator);
                try clr_sql.appendSlice(self.allocator, "DELETE FROM ");
                try appendQuotedIdent(&clr_sql, self.allocator, target_table);
                try clr_sql.appendSlice(self.allocator, ";\x00");
                self.execZ(clr_sql.items[0 .. clr_sql.items.len - 1 :0]) catch {};
            }
            return;
        }
        if (fields.len > 0 and (std.mem.eql(u8, table, "delete_inode") or std.mem.eql(u8, table, "delete_pending_gc"))) {
            const target_table: []const u8 = if (std.mem.eql(u8, table, "delete_inode")) "inodes" else "pending_gc";
            const key_col = std.mem.span(fields[0].name);
            var del_sql: std.ArrayListUnmanaged(u8) = .empty;
            defer del_sql.deinit(self.allocator);
            try del_sql.appendSlice(self.allocator, "DELETE FROM ");
            try appendQuotedIdent(&del_sql, self.allocator, target_table);
            try del_sql.appendSlice(self.allocator, " WHERE ");
            try appendQuotedIdent(&del_sql, self.allocator, key_col);
            try del_sql.appendSlice(self.allocator, " = ?;\x00");
            const del_z: [:0]const u8 = del_sql.items[0 .. del_sql.items.len - 1 :0];

            var stmt_opt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, del_z.ptr, @intCast(del_z.len), &stmt_opt, null) != c.SQLITE_OK) {
                return error.PrepareFailed;
            }
            const stmt = stmt_opt.?;
            defer _ = c.sqlite3_finalize(stmt);

            const f = fields[0];
            switch (f.value.tag) {
                .bytes_val => {
                    const s = f.value.payload.bytes.toSlice();
                    _ = c.sqlite3_bind_text(stmt, 1, s.ptr, @intCast(s.len), null);
                },
                .int_val => _ = c.sqlite3_bind_int64(stmt, 1, f.value.payload.i),
                else => _ = c.sqlite3_bind_null(stmt, 1),
            }
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
            return;
        }

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
                        const col_name = std.mem.span(f.name);
                        const is_blob = self.isBlobColumn(table, col_name) or
                            !std.unicode.utf8ValidateSlice(s) or
                            std.mem.indexOfScalar(u8, s, 0) != null;
                        if (is_blob) {
                            break :blk c.sqlite3_bind_blob(stmt, bind_idx, s.ptr, @intCast(s.len), SQLITE_TRANSIENT);
                        }
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
        const filter = spec.filter_sql_or_expr.toSlice();
        if (filter.len > 0) {
            try sql.appendSlice(self.allocator, " WHERE ");
            try sql.appendSlice(self.allocator, filter);
        }
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
    .version = .{ .major = 1, .minor = 3, .patch = 1 },
});

comptime {
    @export(&manifest, .{ .name = abi.DRIVER_MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

test "sqlite driver C-ABI conformance" {
    try sdk.testing.runDriverConformanceSuite(&manifest, &.{});
}

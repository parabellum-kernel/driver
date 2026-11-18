const std = @import("std");
const sdk = @import("parabellum_sdk");
const gdrive_vfs = @import("gdrive_vfs");
const abi = sdk.abi;

const gdrive = gdrive_vfs.gdrive;
const vfs = gdrive_vfs.vfs;
const AuthTokenManager = gdrive.AuthTokenManager;
const BlobStorePort = vfs.BlobStorePort;

const SingleRowIterator = struct {
    allocator: std.mem.Allocator,
    emitted: bool = false,
    fields: []abi.NamedField_ABI,
    strings_to_free: [][]u8,

    fn next(handle: *abi.driver.RowIteratorHandle_ABI, out_row: *abi.RowView_ABI) callconv(.c) abi.HostError_ABI {
        const self: *SingleRowIterator = @ptrCast(@alignCast(handle));
        if (self.emitted) return .end_of_stream;
        self.emitted = true;
        out_row.* = .{
            .fields_ptr = if (self.fields.len > 0) self.fields.ptr else null,
            .fields_len = self.fields.len,
        };
        return .ok;
    }

    fn deinit(handle: *abi.driver.RowIteratorHandle_ABI) callconv(.c) void {
        const self: *SingleRowIterator = @ptrCast(@alignCast(handle));
        for (self.strings_to_free) |s| self.allocator.free(s);
        if (self.strings_to_free.len > 0) self.allocator.free(self.strings_to_free);
        for (self.fields) |f| {
            const name_slice = std.mem.span(f.name);
            self.allocator.free(name_slice.ptr[0 .. name_slice.len + 1]);
        }
        if (self.fields.len > 0) self.allocator.free(self.fields);
        self.allocator.destroy(self);
    }

    const vtable = abi.driver.RowIteratorVTable_ABI{
        .next = next,
        .deinit = deinit,
    };
};

fn currentUnixSeconds() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
        return @intCast(ts.sec);
    }
    return 1700000000;
}

/// Standalone C-ABI Google Drive VFS Store Driver (`ARCH-037`).
/// Bridges Flowdata `Driver` C-ABI to `lib-gdrive-vfs` (`GDriveBlobStore`) + `lib/vfs`.
pub const GDriveStoreDriver = struct {
    allocator: std.mem.Allocator,
    vault_id: []u8,
    node_id: []u8,
    owned_cred_strings: [][]u8 = &.{},
    http_client: gdrive.StdHttpClient,
    blob_store: gdrive_vfs.GDriveBlobStore,
    catalog: vfs.InMemoryCatalog,
    last_object_id: []u8 = &.{},
    last_etag: []u8 = &.{},

    pub fn create(params: []const abi.ConfigParam_ABI) !*GDriveStoreDriver {
        const alloc = std.heap.c_allocator;
        var vault_id: []const u8 = "default-vault";
        var node_id: []const u8 = "sa-primary";
        var cred_path: []const u8 = "";

        for (params) |p| {
            const k_ptr = p.key.ptr orelse continue;
            const v_ptr = p.value.ptr orelse continue;
            const k = k_ptr[0..p.key.len];
            const v = v_ptr[0..p.value.len];
            if (std.mem.eql(u8, k, "vault_id")) vault_id = v;
            if (std.mem.eql(u8, k, "node_id")) node_id = v;
            if (std.mem.eql(u8, k, "credentials") or std.mem.eql(u8, k, "user_key_path")) cred_path = v;
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
            currentUnixSeconds(),
        );
        errdefer self.blob_store.deinit();

        if (cred_path.len > 0) {
            self.loadAndRegisterCredentials(io, cred_path) catch |err| {
                std.debug.print("[gdrive_store] Warning: failed to load credentials from '{s}': {s}\n", .{ cred_path, @errorName(err) });
            };
        }

        return self;
    }

    fn loadAndRegisterCredentials(self: *GDriveStoreDriver, io: std.Io, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var read_buf: [16 * 1024]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const raw_json = try reader.interface.allocRemaining(self.allocator, .limited(256 * 1024));
        defer self.allocator.free(raw_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, raw_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCredentialsJson;
        const obj = parsed.value.object;

        var strs: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (strs.items) |s| self.allocator.free(s);
            strs.deinit(self.allocator);
        }

        // Check if Service Account vs OAuth2 User credential
        if (obj.get("private_key")) |pk_val| {
            if (pk_val == .string) {
                const email_s = if (obj.get("client_email")) |v| (if (v == .string) v.string else "") else "";
                const pk_id_s = if (obj.get("private_key_id")) |v| (if (v == .string) v.string else "") else "";
                const tok_uri_s = if (obj.get("token_uri")) |v| (if (v == .string) v.string else AuthTokenManager.DEFAULT_TOKEN_URI) else AuthTokenManager.DEFAULT_TOKEN_URI;

                const d_email = try self.allocator.dupe(u8, email_s);
                try strs.append(self.allocator, d_email);
                const d_pk_id = try self.allocator.dupe(u8, pk_id_s);
                try strs.append(self.allocator, d_pk_id);
                const d_pk = try self.allocator.dupe(u8, pk_val.string);
                try strs.append(self.allocator, d_pk);
                const d_uri = try self.allocator.dupe(u8, tok_uri_s);
                try strs.append(self.allocator, d_uri);

                self.owned_cred_strings = try strs.toOwnedSlice(self.allocator);
                try self.blob_store.registerNode(self.node_id, .{
                    .service_account = .{
                        .client_email = d_email,
                        .private_key_id = d_pk_id,
                        .private_key_pem = d_pk,
                        .token_uri = d_uri,
                    },
                });
                return;
            }
        }

        // OAuth2 User credential (supports top-level or nested "installed"/"web" + "refresh_token")
        var client_id_s: []const u8 = if (obj.get("client_id")) |v| (if (v == .string) v.string else "") else "";
        var client_secret_s: []const u8 = if (obj.get("client_secret")) |v| (if (v == .string) v.string else "") else "";
        var tok_uri_s: []const u8 = if (obj.get("token_uri")) |v| (if (v == .string) v.string else AuthTokenManager.DEFAULT_TOKEN_URI) else AuthTokenManager.DEFAULT_TOKEN_URI;
        const refresh_s: []const u8 = if (obj.get("refresh_token")) |v| (if (v == .string) v.string else "") else "";
        const email_s: []const u8 = if (obj.get("account_email")) |v| (if (v == .string) v.string else "") else "";

        if (client_id_s.len == 0) {
            const sub_opt = obj.get("installed") orelse obj.get("web");
            if (sub_opt) |sub| {
                if (sub == .object) {
                    if (sub.object.get("client_id")) |v| if (v == .string) {
                        client_id_s = v.string;
                    };
                    if (sub.object.get("client_secret")) |v| if (v == .string) {
                        client_secret_s = v.string;
                    };
                    if (sub.object.get("token_uri")) |v| if (v == .string) {
                        tok_uri_s = v.string;
                    };
                }
            }
        }

        if (client_id_s.len == 0 or refresh_s.len == 0) return error.MissingOAuthFields;

        const d_cid = try self.allocator.dupe(u8, client_id_s);
        try strs.append(self.allocator, d_cid);
        const d_csec = try self.allocator.dupe(u8, client_secret_s);
        try strs.append(self.allocator, d_csec);
        const d_ref = try self.allocator.dupe(u8, refresh_s);
        try strs.append(self.allocator, d_ref);
        const d_email = try self.allocator.dupe(u8, email_s);
        try strs.append(self.allocator, d_email);
        const d_uri = try self.allocator.dupe(u8, tok_uri_s);
        try strs.append(self.allocator, d_uri);

        self.owned_cred_strings = try strs.toOwnedSlice(self.allocator);
        try self.blob_store.registerNode(self.node_id, .{
            .user_oauth = .{
                .client_id = d_cid,
                .client_secret = d_csec,
                .refresh_token = d_ref,
                .account_email = d_email,
                .token_uri = d_uri,
            },
        });
    }

    pub fn deinit(self: *GDriveStoreDriver) void {
        self.blob_store.deinit();
        self.http_client.deinit();
        self.catalog.deinit();
        for (self.owned_cred_strings) |s| self.allocator.free(s);
        if (self.owned_cred_strings.len > 0) self.allocator.free(self.owned_cred_strings);
        if (self.last_object_id.len > 0) self.allocator.free(self.last_object_id);
        if (self.last_etag.len > 0) self.allocator.free(self.last_etag);
        self.allocator.free(self.vault_id);
        self.allocator.free(self.node_id);
        self.allocator.destroy(self);
    }

    fn setLastPutResult(self: *GDriveStoreDriver, obj_id: []u8, etag: ?[]u8) !void {
        if (self.last_object_id.len > 0) self.allocator.free(self.last_object_id);
        if (self.last_etag.len > 0) self.allocator.free(self.last_etag);
        self.last_object_id = obj_id;
        self.last_etag = etag orelse &.{};
    }

    fn getFieldSlice(fields: []const abi.NamedField_ABI, key: []const u8) ?[]const u8 {
        for (fields) |f| {
            if (std.mem.eql(u8, std.mem.span(f.name), key)) {
                if (f.value.tag == .bytes_val) return f.value.payload.bytes.toSlice();
            }
        }
        return null;
    }

    pub fn writeRow(self: *GDriveStoreDriver, spec: abi.driver.WriteSpec_ABI) !void {
        self.blob_store.now_unix_s = currentUnixSeconds();
        const op = spec.table.toSlice();
        const fields = spec.fieldsSlice();
        const node = getFieldSlice(fields, "node_id") orelse self.node_id;
        const p = self.blob_store.port();

        if (std.mem.eql(u8, op, "put_object")) {
            const name = getFieldSlice(fields, "name") orelse "blob.part";
            const data = if (spec.raw_bytes.len > 0)
                spec.raw_bytes.toSlice()
            else
                (getFieldSlice(fields, "data") orelse "");
            const res = try p.putObject(self.allocator, node, name, data);
            try self.setLastPutResult(res.object_id, res.etag);
            return;
        }

        if (std.mem.eql(u8, op, "put_catalog")) {
            const name = getFieldSlice(fields, "name") orelse "default.vfscat";
            const vid = getFieldSlice(fields, "vault_id") orelse self.vault_id;
            const data = if (spec.raw_bytes.len > 0)
                spec.raw_bytes.toSlice()
            else
                (getFieldSlice(fields, "data") orelse "");
            const res = try self.blob_store.putCatalogObject(self.allocator, node, vid, name, data);
            try self.setLastPutResult(res.object_id, res.etag);
            return;
        }

        if (std.mem.eql(u8, op, "update_object")) {
            const obj_id = getFieldSlice(fields, "object_id") orelse return error.MissingObjectId;
            const etag_raw = getFieldSlice(fields, "expected_etag");
            const expected_etag: ?[]const u8 = if (etag_raw) |e| (if (e.len > 0) e else null) else null;
            const data = if (spec.raw_bytes.len > 0)
                spec.raw_bytes.toSlice()
            else
                (getFieldSlice(fields, "data") orelse "");
            const new_etag = try p.updateObjectIfMatch(self.allocator, node, obj_id, expected_etag, data);
            const dup_id = try self.allocator.dupe(u8, obj_id);
            try self.setLastPutResult(dup_id, new_etag);
            return;
        }

        if (std.mem.eql(u8, op, "delete_object")) {
            const obj_id = getFieldSlice(fields, "object_id") orelse return error.MissingObjectId;
            try p.deleteObject(self.allocator, node, obj_id);
            return;
        }

        return error.UnsupportedOperation;
    }

    pub fn readStream(self: *GDriveStoreDriver, spec: abi.driver.ReadSpec_ABI) !abi.driver.RowIterator_ABI {
        self.blob_store.now_unix_s = currentUnixSeconds();
        const op = spec.table.toSlice();
        const expr = spec.filter_sql_or_expr.toSlice();
        const p = self.blob_store.port();

        // Parse optional "node_id:target_id" from filter_sql_or_expr, or use self.node_id
        var node: []const u8 = self.node_id;
        var target: []const u8 = expr;
        if (std.mem.indexOfScalar(u8, expr, ':')) |colon| {
            node = expr[0..colon];
            target = expr[colon + 1 ..];
        }

        if (std.mem.eql(u8, op, "last_put_result")) {
            return self.makeRowIterator(&.{
                .{ .name = "object_id", .val = .{ .bytes = self.last_object_id } },
                .{ .name = "etag", .val = .{ .bytes = self.last_etag } },
            });
        }

        if (std.mem.eql(u8, op, "get_quota")) {
            const q_node = if (target.len > 0) target else self.node_id;
            const q = try p.getQuota(self.allocator, q_node);
            return self.makeRowIterator(&.{
                .{ .name = "limit_bytes", .val = .{ .uint = q.limit_bytes } },
                .{ .name = "used_bytes", .val = .{ .uint = q.used_bytes } },
            });
        }

        if (std.mem.eql(u8, op, "discover_catalog")) {
            const vid = if (target.len > 0) target else self.vault_id;
            const obj_id = try self.blob_store.discoverCatalogObjectId(self.allocator, node, vid);
            defer self.allocator.free(obj_id);
            return self.makeRowIterator(&.{
                .{ .name = "object_id", .val = .{ .bytes = obj_id } },
            });
        }

        if (std.mem.eql(u8, op, "get_object")) {
            var res = try p.getObject(self.allocator, node, target);
            defer res.deinit(self.allocator);
            return self.makeRowIterator(&.{
                .{ .name = "data", .val = .{ .bytes = res.data } },
                .{ .name = "etag", .val = .{ .bytes = res.etag orelse "" } },
            });
        }

        if (std.mem.eql(u8, op, "get_range")) {
            const start = spec.offset;
            const end_inclusive = if (spec.limit > 0) start + spec.limit - 1 else start;
            const data = try p.getRange(self.allocator, node, target, start, end_inclusive);
            defer self.allocator.free(data);
            return self.makeRowIterator(&.{
                .{ .name = "data", .val = .{ .bytes = data } },
            });
        }

        return error.UnsupportedOperation;
    }

    const FieldSpec = struct {
        name: []const u8,
        val: union(enum) {
            bytes: []const u8,
            uint: u64,
        },
    };

    fn makeRowIterator(self: *GDriveStoreDriver, specs: []const FieldSpec) !abi.driver.RowIterator_ABI {
        const fields = try self.allocator.alloc(abi.NamedField_ABI, specs.len);
        errdefer self.allocator.free(fields);

        var strs: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (strs.items) |s| self.allocator.free(s);
            strs.deinit(self.allocator);
        }

        for (specs, 0..) |sp, i| {
            const name_z = try self.allocator.dupeSentinel(u8, sp.name, 0);
            switch (sp.val) {
                .bytes => |b| {
                    const dup_b = try self.allocator.dupe(u8, b);
                    try strs.append(self.allocator, dup_b);
                    fields[i] = .{
                        .name = name_z.ptr,
                        .value = .{
                            .tag = .bytes_val,
                            .payload = .{ .bytes = abi.Slice_ABI.from(dup_b) },
                        },
                    };
                },
                .uint => |u| {
                    fields[i] = .{
                        .name = name_z.ptr,
                        .value = .{
                            .tag = .uint_val,
                            .payload = .{ .u = u },
                        },
                    };
                },
            }
        }

        const iter = try self.allocator.create(SingleRowIterator);
        iter.* = .{
            .allocator = self.allocator,
            .fields = fields,
            .strings_to_free = try strs.toOwnedSlice(self.allocator),
        };
        return .{
            .handle = @ptrCast(iter),
            .vtable = &SingleRowIterator.vtable,
        };
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

const std = @import("std");

const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

pub const Database = struct {
    db: ?*sqlite3.sqlite3 = null,

    pub fn open(path: [*:0]const u8) anyerror!@This() {
        var ptr: ?*sqlite3.sqlite3 = null;

        var rc = sqlite3.sqlite3_open(path, &ptr);
        if (rc > 0) {
            std.log.err("Can't open database: {s}\n", .{sqlite3.sqlite3_errmsg(ptr)});
            return error.FailedToOpenDatabase;
        }

        return @This(){
            .db = ptr,
        };
    }

    pub fn close(self: *@This()) anyerror!void {
        var rc = sqlite3.sqlite3_close(self.db);
        if (rc > 0) {
            std.log.err("Can't close database: {s}\n", .{sqlite3.sqlite3_errmsg(self.db)});
        }

        self.db = null;
    }

    pub fn prepare(self: *@This(), query: []const u8) anyerror!Statement {
        var res: ?*sqlite3.sqlite3_stmt = null;
        var rc = sqlite3.sqlite3_prepare_v2(self.db, query.ptr, @intCast(c_int, query.len), &res, 0);

        if (rc != sqlite3.SQLITE_OK) {
            std.log.err("failed to fetch data: {s}\n", .{sqlite3.sqlite3_errmsg(self.db)});
            return error.FailedToFetchData;
        }

        if (res) |ptr| {
            return Statement{
                .db = self,
                .statement = ptr,
            };
        }
        return error.NullPtr;
    }

    pub fn exec(self: *@This(), queries: [:0]const u8) anyerror!void { // TODO ADD 0 IF NEEDED AT COMPILE TIME
        var errorMsg: ?[*:0]u8 = null;

        var rc = sqlite3.sqlite3_exec(self.db, queries, null, null, &errorMsg);
        if (rc != sqlite3.SQLITE_OK) {
            std.log.err("failed to execute queries: {s}\n", .{errorMsg}); // TODO
            sqlite3.sqlite3_free(errorMsg);
            return error.FailedToExecuteQueries;
        }
    }
};

pub const Statement = struct {
    db: *Database,
    statement: *sqlite3.sqlite3_stmt,

    pub fn bind(self: *@This(), index: isize, value: anytype) anyerror!void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Float, .ComptimeFloat => {
                var rc = sqlite3.sqlite3_bind_double(self.statement, @intCast(c_int, index), value);
                if (rc != sqlite3.SQLITE_OK) {
                    std.log.err("failed to bind parameter: {s}\n", .{sqlite3.sqlite3_errmsg(self.db.db)});
                    return error.FailedToBindParameter;
                }
            },
            .Int, .ComptimeInt => {
                var rc = sqlite3.sqlite3_bind_int(self.statement, @intCast(c_int, index), value);
                if (rc != sqlite3.SQLITE_OK) {
                    std.log.err("failed to bind parameter: {s}\n", .{sqlite3.sqlite3_errmsg(self.db.db)});
                    return error.FailedToBindParameter;
                }
            },
            .Union => {
                if (T == U8Array) {
                    switch (value) {
                        U8ArrayTypeTag.text => {
                            var rc = sqlite3.sqlite3_bind_text(self.statement, @intCast(c_int, index), value.text.ptr, @intCast(c_int, value.text.len), sqlite3.SQLITE_TRANSIENT);
                            if (rc != sqlite3.SQLITE_OK) {
                                std.log.err("failed to bind parameter: {s}\n", .{sqlite3.sqlite3_errmsg(self.db.db)});
                                return error.FailedToBindParameter;
                            }
                        },
                        U8ArrayTypeTag.bytes => {
                            var rc = sqlite3.sqlite3_bind_blob(self.statement, @intCast(c_int, index), value.bytes.ptr, @intCast(c_int, value.bytes.len), sqlite3.SQLITE_TRANSIENT);
                            if (rc != sqlite3.SQLITE_OK) {
                                std.log.err("failed to bind parameter: {s}\n", .{sqlite3.sqlite3_errmsg(self.db.db)});
                                return error.FailedToBindParameter;
                            }
                        },
                    }
                } else {
                    @compileError("Unable to bind type '" ++ @typeName(T) ++ "'");
                }
            },
            else => @compileError("Unable to bind type '" ++ @typeName(T) ++ "'"),
        }
    }

    pub fn next(self: *@This()) bool {
        var rc = sqlite3.sqlite3_step(self.statement);

        // TODO ERROR ?
        return rc == sqlite3.SQLITE_ROW;
    }

    pub fn exec(self: *@This()) anyerror!void {
        var rc = sqlite3.sqlite3_step(self.statement);

        if (rc == sqlite3.SQLITE_ROW) {
            return anyerror.ExecFailed;
        }
    }

    pub fn finalize(self: *@This()) void {
        _ = sqlite3.sqlite3_finalize(self.statement);
    }

    pub fn fetch(self: *@This(), args: anytype) anyerror!void {
        const ArgsType = @TypeOf(args);

        if (@typeInfo(ArgsType) != .Struct) {
            @compileError("Expected tuple or struct argument, found " ++ @typeName(ArgsType));
        }

        comptime var index = 0;
        inline while (index < args.len) : (index += 1) {
            const arg = args[index];

            comptime var T = @TypeOf(arg);

            switch (@typeInfo(T)) {
                .Pointer => |ptr_info| switch (ptr_info.size) {
                    .One => switch (@typeInfo(ptr_info.child)) {
                        .Float, .ComptimeFloat => {
                            arg.* = sqlite3.sqlite3_column_double(self.statement, @intCast(c_int, index));
                        },
                        .Int, .ComptimeInt => {
                            arg.* = sqlite3.sqlite3_column_int(self.statement, @intCast(c_int, index));
                        },
                        .Union => {
                            T = @TypeOf(arg.*);
                            if (T == U8Array) {
                                switch (arg.*) {
                                    U8ArrayTypeTag.text => {
                                        var text: [*c]const u8 = sqlite3.sqlite3_column_text(self.statement, @intCast(c_int, index));

                                        if (text != null) {
                                            var size = sqlite3.sqlite3_column_bytes(self.statement, @intCast(c_int, index));

                                            arg.text = text[0..@intCast(usize, size)];
                                        }
                                    },
                                    U8ArrayTypeTag.bytes => {
                                        var blob_ptr: ?*const anyopaque = sqlite3.sqlite3_column_blob(self.statement, @intCast(c_int, index));

                                        if (blob_ptr != null) {
                                            var blob = @ptrCast([*]const u8, blob_ptr);
                                            var size = sqlite3.sqlite3_column_bytes(self.statement, @intCast(c_int, index));

                                            arg.bytes = blob[0..@intCast(usize, size)]; // TODO TEST
                                        }
                                    },
                                }
                            } else {
                                @compileError("Unable to fetch type '" ++ @typeName(T) ++ "'");
                            }
                        },
                        else => @compileError("Unable to fetch type '" ++ @typeName(T) ++ "'"),
                    },

                    else => @compileError("Unable to fetch type '" ++ @typeName(T) ++ "'"),
                },
                else => @compileError("Unable to fetch type '" ++ @typeName(T) ++ "'"),
            }
        }
    }
};

const U8ArrayTypeTag = enum {
    text,
    bytes,
};

pub const U8Array = union(U8ArrayTypeTag) {
    text: []const u8,
    bytes: []const u8,

    pub fn text(value: []const u8) @This() {
        return @This(){ .text = value };
    }

    pub fn bytes(value: []const u8) @This() {
        return @This(){ .bytes = value };
    }
};

// For whatever reason this test make the compiler segfault.
fn testCreationBd() anyerror!void {
    const assert = std.debug.assert;

    var db = try Database.open(":memory:");

    defer {
        _ = db.close() catch |e| {
            std.log.err("Failed to close db : {}", .{e});
        };
    }

    try db.exec("CREATE TABLE A(A INTEGER, B TEXT, C REAL, D BLOB);");

    const first_blob_test = [_]u8{ 0, 1, 2 };
    const second_blob_test = [_]u8{0} ** 1000;

    {
        var st = try db.prepare("INSERT INTO A VALUES(?, ?, ?, ?)");
        try st.bind(1, 150);
        try st.bind(2, U8Array.text("This is the first test"));
        try st.bind(3, 3.45);
        try st.bind(4, U8Array.bytes(&first_blob_test));

        try st.exec();

        st.finalize();
    }

    {
        var st = try db.prepare("INSERT INTO A VALUES(?, ?, ?, ?)");
        try st.bind(1, 175);
        try st.bind(2, U8Array.text("This is another test"));
        try st.bind(3, 156.4);
        try st.bind(4, U8Array.bytes(&second_blob_test));

        try st.exec();

        st.finalize();
    }

    var query = try db.prepare("SELECT * FROM A");

    var a: isize = undefined;
    var b: U8Array = U8Array.text(undefined);
    var c: f64 = undefined;
    var d: U8Array = U8Array.bytes(undefined);

    {
        assert(query.next());
        try query.fetch(.{ &a, &b, &c, &d });

        assert(a == 150);
        assert(std.mem.eql(u8, "This is the first test", b.text));
        assert(c == 3.45);
        assert(std.mem.eql(u8, &first_blob_test, d.bytes));
    }

    {
        assert(query.next());
        try query.fetch(.{ &a, &b, &c, &d });

        assert(a == 175);
        assert(std.mem.eql(u8, "This is another test", b.text));
        assert(c == 156.4);
        assert(std.mem.eql(u8, &second_blob_test, d.bytes));
    }

    query.finalize();
}

test "test-creation-bd" {
    try testCreationBd();
}

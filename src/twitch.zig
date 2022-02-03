const std = @import("std");
const mem = std.mem;

pub const Stream = struct {
    id: []const u8,
    user_id: []const u8,
    user_login: []const u8,
    user_name: []const u8,
    game_id: []const u8,
    game_name: []const u8,
    type: []const u8,
    title: []const u8,
    viewer_count: u64,
    started_at: []const u8,
    language: []const u8,
    thumbnail_url: []const u8,
    tag_ids: ?[][]const u8,
    is_mature: bool,
};

pub const User = struct {
    id: []const u8,
    login: []const u8,
    display_name: []const u8,
    profile_image_url: []const u8,
};

pub const Pagination = struct { cursor: ?[]u8 = null };

pub fn TwitchRes(comptime T: type) type {
    return struct {
        data: T,
        pagination: ?Pagination = null,
        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            deinitVar(allocator, self.data);
            if (self.pagination) |p| {
                if (p.cursor) |cursor| {
                    allocator.free(cursor);
                }
            }
            self.* = undefined;
        }
    };
}

inline fn deinitVar(allocator: mem.Allocator, value: anytype) void {
    const T = @TypeOf(value);

    if (comptime std.meta.trait.hasFn("deinit")(T)) {
        value.deinit(); // TODO pass allocator if needed
    } else {
        switch (@typeInfo(T)) {
            .Optional => {
                if (value) |payload| {
                    deinitVar(allocator, payload);
                }
            },
            .Union => {
                const info = @typeInfo(T).Union;
                if (info.tag_type) |UnionTagType| {
                    inline for (info.fields) |u_field| {
                        if (value == @field(UnionTagType, u_field.name)) {
                            deinitVar(allocator, @field(value, u_field.name));
                        }
                    }
                }
            },
            .Struct => |S| {
                inline for (S.fields) |Field| {
                    deinitVar(allocator, @field(value, Field.name));
                }
            },
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .One => switch (@typeInfo(ptr_info.child)) {
                    .Array => {
                        const Slice = []const std.meta.Elem(ptr_info.child);
                        return deinitVar(allocator, @as(Slice, value));
                    },
                    else => {
                        deinitVar(allocator, value.*);
                        allocator.destroy(value);
                    },
                },
                .Slice => {
                    const elem = std.meta.Elem(T);
                    switch (@typeInfo(elem)) {
                        .Type, .Void, .Bool, .Int, .Float, .Enum => {
                            //AVOID USELESS LOOPING
                        },
                        else => {
                            var i: usize = 0;
                            while (i < value.len) : (i += 1) {
                                deinitVar(allocator, value[i]);
                            }
                        },
                    }

                    allocator.free(value);
                },
                else => @compileError("Unable to deinit type '" ++ @typeName(T) ++ "'"),
            },
            .Array => deinitVar(allocator, &value),
            .Type, .Void, .Bool, .Int, .Float, .Enum => {},
            else => @compileError("Unable to deinit type '" ++ @typeName(T) ++ "'"),
        }
    }
}

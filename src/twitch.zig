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

pub const Pagination = struct { cursor: ?[]u8 = null };

pub fn TwitchRes(comptime T: type) type {
    return struct { data: T, pagination: Pagination };
}

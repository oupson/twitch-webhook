pub const Webhook = struct {
    username: []const u8,
    avatar_url: ?[]const u8 = null,
    content: []const u8,
    embeds: ?[]Embed = null,
    tts: bool = false,
    // allowed_mentions
};

pub const Embed = struct {
    author: ?Author = null,
    title: []const u8,
    url: ?[]const u8 = null,
    description: ?[]const u8 = null,
    color: u32,
    fields: ?[]const Field = null,
    thumbnail: ?Image = null,
    image: ?Image = null,
    footer: ?Footer = null,
};

pub const Author = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    icon_url: ?[]const u8 = null,
};

pub const Field = struct {
    name: []const u8,
    value: []const u8,
    @"inline": bool,
};

pub const Image = struct {
    url: []const u8,
};

pub const Footer = struct {
    text: ?[]const u8 = null,
    icon_url: ?[]const u8 = null,
};

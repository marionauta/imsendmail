const std = @import("std");
const fs = std.fs;
const http = std.http;
const json = std.json;

/// Call `File.close` to release the resource.
pub fn open_configuration_file() ?fs.File {
    const cwd = fs.cwd();
    var file: ?fs.File = cwd.openFile("sendmailrc.json", .{}) catch null;
    if (file == null) {
        std.log.info("local file is null", .{});
        file = fs.openFileAbsolute("/etc/sendmailrc.json", .{}) catch null;
    }
    return file;
}

/// Call `Parsed.deinit` to release the resource.
pub fn read_configuration(allocator: std.mem.Allocator, file: fs.File) !json.Parsed(Configuration) {
    const raw_configuration = try file.readToEndAlloc(allocator, 1024);
    // defer allocator.free(raw_configuration);
    const parsed: json.Parsed(Configuration) = try json.parseFromSlice(
        Configuration,
        allocator,
        raw_configuration,
        .{
            .ignore_unknown_fields = true,
        },
    );
    return parsed;
}

const RecipientType = enum {
    telegram,
    hostname,
};

const TelegramRecipient = struct {
    chat_id: []const u8,
};

const Recipient = union(RecipientType) {
    telegram: TelegramRecipient,
    hostname: struct { []const u8, []const u8 },
};

pub fn parse_body_to(allocator: std.mem.Allocator, to: []const u8) !std.ArrayList([]const u8) {
    var res: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, to, ' ');
    while (it.next()) |r| try res.append(allocator, r);
    return res;
}

pub fn parse_recipient(address: []const u8) ?Recipient {
    const at_index = std.mem.indexOfScalar(u8, address, '@') orelse return null;
    const username = address[0..at_index];
    if (username.len == 0) return null;
    const hostname = address[(at_index + 1)..];
    if (std.mem.eql(u8, hostname, "telegram")) {
        return Recipient{ .telegram = .{ .chat_id = address[0..at_index] } };
    } else if (hostname.len > 0) {
        return Recipient{ .hostname = .{ username, hostname } };
    }
    return null;
}

pub const Aliases = std.StringHashMap([]const u8);

pub fn aliases_from_raw(allocator: std.mem.Allocator, raw: RawAliases) !Aliases {
    var aliases = Aliases.init(allocator);
    for (raw) |alias| {
        try aliases.put(alias[0], alias[1]);
    }
    return aliases;
}

pub fn resolve_recipient_alias(aliases: Aliases, recipient: []const u8) []const u8 {
    return aliases.get(recipient) orelse recipient;
}

pub const TelegramClient = struct {
    token: []const u8,
};

const TELEGRAM_BASE_URL = "https://api.telegram.org";

pub fn send_message_telegram(allocator: std.mem.Allocator, client: TelegramClient, recipient: TelegramRecipient, message: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/bot{s}/sendMessage", .{ TELEGRAM_BASE_URL, client.token });
    defer allocator.free(url);
    const data = try format_message_telegram(allocator, recipient.chat_id, message);
    defer allocator.free(data);
    var http_client = http.Client{ .allocator = allocator };
    defer http_client.deinit();
    const result = try http_client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .payload = data,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });
    if (result.status.class() != .success) {
        return error.ApiNoSuccess;
    }
}

pub fn format_message_telegram(allocator: std.mem.Allocator, chat_id: []const u8, message: []const u8) ![]const u8 {
    const TelegramMessage = struct {
        chat_id: []const u8,
        text: []const u8,
    };
    const tm = TelegramMessage{ .chat_id = chat_id, .text = message };
    var res = std.io.Writer.Allocating.init(allocator);
    try json.Stringify.value(tm, .{}, &res.writer);
    return res.toOwnedSlice();
}

pub const RawAlias = [2]([]const u8);
pub const RawAliases = []RawAlias;

pub const Configuration = struct {
    telegram_token: []const u8,
    aliases: RawAliases,
};

test "open configuration file" {
    const f = open_configuration_file();
    try std.testing.expect(f != null);
    f.?.close();
}

test "parse no username" {
    const r = parse_recipient("@telegram");
    try std.testing.expectEqual(r, null);
}

test "parse recipient" {
    const r = parse_recipient("1234@telegram");
    try std.testing.expectEqualStrings(r.?.telegram.chat_id, "1234");
}

test "parse hostname" {
    const r = parse_recipient("1234@example.com");
    try std.testing.expectEqualStrings(r.?.hostname[0], "1234");
    try std.testing.expectEqualStrings(r.?.hostname[1], "example.com");
}

test "send_message_telegram" {
    const conf_file = open_configuration_file().?;
    defer conf_file.close();
    const configuration = try read_configuration(std.testing.allocator, conf_file);
    std.debug.print("conf: {}", .{configuration.value});
    defer configuration.deinit();
    const client = TelegramClient{ .token = configuration.value.telegram_token };
    const rec = parse_recipient(configuration.value.aliases[0][1]);
    const recipient = TelegramRecipient{ .chat_id = rec.?.telegram.chat_id };
    try send_message_telegram(std.testing.allocator, client, recipient, "sendmail testing");
}

test "format_message_telegram" {
    const message = try format_message_telegram(std.testing.allocator, "1234", "hello, world");
    std.debug.print("message: {s}", .{message});
    std.testing.allocator.free(message);
}

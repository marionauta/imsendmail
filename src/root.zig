const std = @import("std");
const strings = @import("strings");
const fs = std.fs;
const io = std.io;
const http = std.http;
const json = std.json;

const Allocator = std.mem.Allocator;

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

pub const Header = struct {
    name: []const u8,
    body: []const u8,
};

pub fn parseHeader(raw: []const u8) ?Header {
    const colon_index: usize = std.mem.indexOfScalar(u8, raw, ':') orelse {
        return null;
    };
    const name = raw[0..colon_index];
    const body = strings.trimStart(raw[(colon_index + 1)..]);
    return Header{ .name = name, .body = body };
}

test "parse header" {
    const h1 = parseHeader("Name: something").?;
    try std.testing.expectEqualStrings("Name", h1.name);
    try std.testing.expectEqualStrings("something", h1.body);
    const h2 = parseHeader("Again:joined").?;
    try std.testing.expectEqualStrings("Again", h2.name);
    try std.testing.expectEqualStrings("joined", h2.body);
}

pub fn parse_header_to_collect(to: []const u8, recipients: *std.StringHashMap(bool)) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, to, ' ');
    while (it.next()) |r| try recipients.put(r, true);
}

pub const Message = struct {
    allocator: Allocator,
    headers: std.StringHashMapUnmanaged([]const u8),
    body: []const u8,

    pub fn init(allocator: Allocator) Message {
        return Message{ .allocator = allocator, .headers = .{}, .body = "" };
    }

    pub fn deinit(self: *Message, allocator: Allocator) void {
        self.headers.deinit(self.allocator);
        allocator.free(self.body);
    }
};

pub fn parseRawMessage(allocator: Allocator, reader: *io.Reader) !Message {
    var message = Message.init(allocator);
    var body = std.ArrayList(u8).empty;
    while (try reader.takeDelimiter('\n')) |line| {
        if (line.len == 0) {
            body.clearAndFree(allocator);
            break;
        }
        const header = parseHeader(line) orelse {
            try body.appendSlice(allocator, line);
            try body.append(allocator, '\n');
            continue;
        };
        try message.headers.put(message.allocator, header.name, header.body);
    }
    message.body = if (body.items.len > 0) try body.toOwnedSlice(allocator) else try reader.allocRemaining(message.allocator, .unlimited);
    return message;
}

test "parse raw message" {
    const a = std.testing.allocator;
    const raw = "Header: value\nAnother:something\n\nhello";
    var reader = io.Reader.fixed(raw);
    var message = try parseRawMessage(a, &reader);
    defer message.deinit(a);
    try std.testing.expectEqualStrings("value", message.headers.get("Header").?);
    try std.testing.expectEqualStrings("something", message.headers.get("Another").?);
    try std.testing.expectEqualStrings("hello", message.body);
}

test "parse raw message no headers" {
    const a = std.testing.allocator;
    const raw = "hello\njust some text and no headers\n";
    var reader = io.Reader.fixed(raw);
    var message = try parseRawMessage(a, &reader);
    defer message.deinit(a);
    try std.testing.expectEqual(0, message.headers.size);
    try std.testing.expectEqualStrings(strings.trimStart(raw), message.body);
}

pub fn parse_recipient(address: []const u8) ?Recipient {
    const at_index = std.mem.lastIndexOfScalar(u8, address, '@') orelse return null;
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

pub fn aliases_from_raw(allocator: Allocator, raw: RawAliases) Allocator.Error!Aliases {
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

pub fn send_message_telegram(allocator: std.mem.Allocator, client: TelegramClient, recipient: TelegramRecipient, message: Message) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/bot{s}/sendMessage", .{ TELEGRAM_BASE_URL, client.token });
    defer allocator.free(url);
    const composed = try compose_message(allocator, message);
    defer allocator.free(composed);
    const data = try format_message_telegram(allocator, recipient.chat_id, composed);
    defer allocator.free(data);
    var http_client = http.Client{ .allocator = allocator };
    defer http_client.deinit();

    var response_writer = io.Writer.Allocating.init(allocator);

    const result = try http_client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .payload = data,
        .response_writer = &response_writer.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });

    const response = try response_writer.toOwnedSlice();
    std.debug.print("response:\n{s}\n----\n", .{response});

    if (result.status.class() != .success) {
        return error.ApiNoSuccess;
    }
}

pub fn compose_message(allocator: Allocator, message: Message) !([]const u8) {
    var res = std.io.Writer.Allocating.init(allocator);
    var writer = &res.writer;
    if (message.headers.get("Subject")) |subject| {
        try writer.print("*{s}*\n", .{subject});
    }
    if (message.headers.get("From")) |from| {
        try writer.print("from `{s}`\n", .{from});
    }
    if (message.headers.get("To")) |to| {
        try writer.print("to `{s}`\n", .{to});
    }
    _ = try writer.write("```\n");
    _ = try writer.write(message.body);
    _ = try writer.write("```\n");
    return try res.toOwnedSlice();
}

pub fn format_message_telegram(allocator: Allocator, chat_id: []const u8, message: []const u8) ![]const u8 {
    const TelegramMessage = struct {
        chat_id: []const u8,
        text: []const u8,
        parse_mode: []const u8,
    };
    const tm = TelegramMessage{ .chat_id = chat_id, .text = message, .parse_mode = "MarkdownV2" };
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

test "parse username" {
    const r = parse_recipient("@username@telegram").?;
    try std.testing.expectEqualStrings(r.telegram.chat_id, "@username");
}

test "parse hostname" {
    const r = parse_recipient("1234@example.com");
    try std.testing.expectEqualStrings(r.?.hostname[0], "1234");
    try std.testing.expectEqualStrings(r.?.hostname[1], "example.com");
}

// test "send_message_telegram" {
//     const conf_file = open_configuration_file().?;
//     defer conf_file.close();
//     const configuration = try read_configuration(std.testing.allocator, conf_file);
//     std.debug.print("conf: {}", .{configuration.value});
//     defer configuration.deinit();
//     const client = TelegramClient{ .token = configuration.value.telegram_token };
//     const rec = parse_recipient(configuration.value.aliases[0][1]);
//     const recipient = TelegramRecipient{ .chat_id = rec.?.telegram.chat_id };
//     try send_message_telegram(std.testing.allocator, client, recipient, "sendmail testing");
// }

test "format_message_telegram" {
    const message = try format_message_telegram(std.testing.allocator, "1234", "hello, world");
    // std.debug.print("message: {s}", .{message});
    std.testing.allocator.free(message);
}

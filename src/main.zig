const std = @import("std");
const io = std.Io;
const sendmail = @import("sendmail");
const strings = @import("strings");
const rem = @import("rem");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const conf_file = sendmail.open_configuration_file() orelse {
        std.log.err("unable to open configuration file", .{});
        std.process.exit(1);
    };
    defer conf_file.close();
    const configuration: std.json.Parsed(sendmail.Configuration) = sendmail.read_configuration(allocator, conf_file) catch |err| {
        std.log.err("unable to read configuration file: {}", .{err});
        std.process.exit(1);
    };
    defer configuration.deinit();

    var recipients = std.StringHashMap(bool).init(allocator);

    var arguments = try std.process.argsWithAllocator(allocator);
    _ = arguments.skip(); // program name
    while (arguments.next()) |recipient| {
        // TODO: check recipient
        try recipients.put(recipient, true);
    }

    var stdin_buffer: [1024]u8 = undefined;
    var stdin = std.fs.File.stdin();
    var stdin_reader = stdin.reader(&stdin_buffer);

    var message = try sendmail.parseRawMessage(allocator, &stdin_reader.interface);
    defer message.deinit(allocator);

    if (message.headers.get("To")) |to| {
        try sendmail.parse_header_to_collect(to, &recipients);
    }

    if (recipients.unmanaged.size == 0) {
        std.log.err("no senders provided", .{});
        std.process.exit(1);
    }

    var aliases = try sendmail.aliases_from_raw(allocator, configuration.value.aliases);
    defer aliases.deinit();
    const client = sendmail.TelegramClient{ .token = configuration.value.telegram_token };

    var it = recipients.keyIterator();
    send_message: while (it.next()) |raw_recipient| {
        const aliased = sendmail.resolve_recipient_alias(aliases, raw_recipient.*);
        const recipient = sendmail.parse_recipient(aliased) orelse {
            continue :send_message;
        };

        if (message.headers.get("Content-Type")) |content_type| {
            if (strings.contains(content_type, "html")) {
                const body = try press_html(message.allocator, message.body);
                message.allocator.free(message.body);
                message.body = body;
            }
        }
        sendmail.send_message_telegram(allocator, client, recipient.telegram, message) catch |err| {
            std.log.err("failed to send message: {}", .{err});
        };
    }
}

fn press_html(allocator: std.mem.Allocator, html: []const u8) !([]const u8) {
    const decoded = try utf8DecodeString(allocator, html);
    defer allocator.free(decoded);
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();
    var parser = try rem.Parser.init(&dom, decoded, allocator, .report, false);
    defer parser.deinit();
    try parser.run();
    var stdout_writer = io.Writer.Allocating.init(allocator);
    const stdout = &stdout_writer.writer;
    const document = parser.getDocument();
    if (document.element) |element| try write_element(stdout, element);
    try stdout.flush();
    return stdout_writer.toOwnedSlice();
}

fn write_element(writer: *io.Writer, element: *rem.Dom.Element) !void {
    if (element.element_type == .html_style) return;
    for (element.children.items) |child| {
        switch (child) {
            .cdata => |cd| {
                if (cd.interface == .text) {
                    std.debug.print("{s}", .{cd.data.items});
                    _ = try writer.write(cd.data.items);
                }
            },
            .element => |e| try write_element(writer, e),
        }
    }
}

fn utf8DecodeString(allocator: std.mem.Allocator, string: []const u8) ![]const u21 {
    var result: std.ArrayList(u21) = .empty;
    var decoded = try std.unicode.Utf8View.init(string);
    var decoded_it = decoded.iterator();
    while (decoded_it.nextCodepoint()) |codepoint| {
        try result.append(allocator, codepoint);
    }
    return result.toOwnedSlice(allocator);
}

const std = @import("std");
const sendmail = @import("sendmail");
const strings = @import("strings");
const html = @import("html");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const conf_file = sendmail.open_configuration_file() orelse {
        std.log.err("unable to open configuration file", .{});
        std.process.exit(1);
    };
    defer conf_file.close();
    var conf_buffer: [1024]u8 = undefined;
    var reader = conf_file.reader(&conf_buffer);
    var configuration = sendmail.readConfiguration(allocator, &reader.interface) catch |err| {
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

    const client = sendmail.TelegramClient{ .token = configuration.telegram_token };

    var it = recipients.keyIterator();
    send_message: while (it.next()) |raw_recipient| {
        const aliased = sendmail.resolveRecipientAlias(configuration.aliases, raw_recipient.*);
        const recipient = sendmail.parse_recipient(aliased) orelse {
            continue :send_message;
        };
        if (message.headers.get("Content-Type")) |content_type| {
            if (strings.contains(content_type, "html")) {
                const body = try html.toPlainText(message.allocator, message.body);
                message.allocator.free(message.body);
                message.body = body;
            }
        }
        sendmail.send_message_telegram(allocator, client, recipient.telegram, message) catch |err| {
            std.log.err("failed to send message: {}", .{err});
        };
    }
}

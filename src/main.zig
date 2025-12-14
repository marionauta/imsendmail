const std = @import("std");
const io = std.Io;
const sendmail = @import("sendmail");

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

    var message_writer = io.Writer.Allocating.init(allocator);
    _ = try stdin_reader.interface.streamRemaining(&message_writer.writer);
    const message_body = try message_writer.toOwnedSlice();

    var message_reader = io.Reader.fixed(message_body);
    to: while (try message_reader.takeDelimiter('\n')) |line| {
        if (std.mem.eql(u8, line[0..3], "To:")) {
            var recs = try sendmail.parse_body_to(allocator, line[4..]);
            defer recs.deinit(allocator);
            for (recs.items) |r| try recipients.put(r, true);
            break :to;
        }
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

        sendmail.send_message_telegram(allocator, client, recipient.telegram, message_body) catch |err| {
            std.log.err("failed to send message: {}", .{err});
        };
    }
}

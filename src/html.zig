const std = @import("std");
const rem = @import("rem");

const Writer = std.io.Writer;

/// Converts HTML content to plain text for email fallback display.
/// Parses the HTML DOM and extracts text content, preserving basic structure
/// like line breaks for headings, lists, and block elements.
pub fn toPlainText(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    const decoded = try utf8DecodeString(allocator, html);
    defer allocator.free(decoded);
    var dom = rem.Dom{ .allocator = allocator };
    defer dom.deinit();
    var parser = try rem.Parser.init(&dom, decoded, allocator, .report, false);
    defer parser.deinit();
    try parser.run();
    var writer_allocating = Writer.Allocating.init(allocator);
    const writer = &writer_allocating.writer;
    const document = parser.getDocument();
    if (document.element) |element| try writeElement(writer, element, false);
    try writer.flush();
    return writer_allocating.toOwnedSlice();
}

/// Renders a single HTML element to plain text, dispatching based on element type.
fn writeElement(writer: *Writer, element: *rem.Dom.Element, in_pre: bool) Writer.Error!void {
    switch (element.element_type) {
        .html_style, .html_script, .html_head => return,
        .html_br => try writer.writeByte('\n'),
        .html_hr => _ = try writer.write("\n---\n"),
        .html_li => {
            _ = try writer.write("- ");
            try writeChildren(writer, element, in_pre, true);
            try writer.writeByte('\n');
        },
        .html_p, .html_div, .html_ul, .html_ol => {
            try writeChildren(writer, element, in_pre, true);
            try writer.writeByte('\n');
        },
        .html_h1, .html_h2, .html_h3, .html_h4, .html_h5, .html_h6 => {
            try writer.writeByte('\n');
            try writeChildren(writer, element, in_pre, true);
            try writer.writeByte('\n');
        },
        .html_blockquote => {
            _ = try writer.write("> ");
            try writeChildren(writer, element, in_pre, true);
            try writer.writeByte('\n');
        },
        .html_a => {
            try writeChildren(writer, element, in_pre, false);
            const href = element.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" });
            if (href) |url| try writer.print(" ({s})", .{url});
        },
        .html_pre => try writeChildren(writer, element, true, false),
        else => try writeChildren(writer, element, in_pre, false),
    }
}

/// Recursively processes child nodes, handling text and nested elements.
fn writeChildren(writer: *Writer, element: *rem.Dom.Element, in_pre: bool, at_block_start: bool) Writer.Error!void {
    var skip_ws = at_block_start;
    for (element.children.items) |child| {
        switch (child) {
            .cdata => |cd| {
                if (cd.interface == .text) {
                    if (in_pre) {
                        _ = try writer.write(cd.data.items);
                    } else {
                        try writeCollapsedText(writer, cd.data.items, skip_ws);
                        for (cd.data.items) |c| {
                            if (!std.ascii.isWhitespace(c)) {
                                skip_ws = false;
                                break;
                            }
                        }
                    }
                }
            },
            .element => |e| {
                try writeElement(writer, e, in_pre);
                skip_ws = isBlockElement(e.element_type);
            },
        }
    }
}

fn isBlockElement(element_type: rem.Dom.ElementType) bool {
    return switch (element_type) {
        .html_p,
        .html_div,
        .html_ul,
        .html_ol,
        .html_li,
        .html_h1,
        .html_h2,
        .html_h3,
        .html_h4,
        .html_h5,
        .html_h6,
        .html_blockquote,
        .html_hr,
        .html_br,
        .html_pre,
        .html_table,
        .html_tr,
        .html_td,
        .html_th,
        .html_header,
        .html_footer,
        .html_section,
        .html_article,
        .html_nav,
        .html_aside,
        .html_main,
        .html_figure,
        => true,
        else => false,
    };
}

/// Writes text with consecutive whitespace collapsed to single spaces (HTML behavior).
fn writeCollapsedText(writer: *Writer, text: []const u8, skip_leading: bool) Writer.Error!void {
    var in_whitespace = skip_leading;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!in_whitespace) {
                try writer.writeByte(' ');
                in_whitespace = true;
            }
        } else {
            try writer.writeByte(c);
            in_whitespace = false;
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

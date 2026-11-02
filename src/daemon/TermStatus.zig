//! A terminal buffer's title and program status, passed through to the Rex
//! pane of each window showing it, as if its program ran in that pane. Rex
//! names tabs from the title and shows progress and "needs you" from the
//! status (OSC 7501; https://www.superlogical.com/rex/docs/build/program-status).
//!
//! The Lua keeps each terminal's records and says what a window shows; a
//! pane's Surface keeps what was last sent, and `sync` writes the difference.
//! Everything here came from a program in a Neovim terminal, so only text
//! that can't end the sequence early is ever written.

const std = @import("std");
const Allocator = std.mem.Allocator;

const TermStatus = @This();

/// Owned.
title: []u8 = &.{},
/// Sorted by id; the root record's id is "". Owned.
records: std.ArrayList(Record) = .empty,

pub const Record = struct {
    id: []u8,
    /// The report after `OSC 7501 ;`, such as `state=working:app=claude-code`.
    body: []u8,
};

/// Longest title kept, in bytes: the spec's `title` limit.
pub const max_title = 256;
/// Longest report body: the spec's 4096 bytes less `OSC 7501 ;` and `ST`.
pub const max_body = 4096 - "\x1b]7501;".len - "\x1b\\".len;
/// Longest id: the spec's limit.
pub const max_id = 128;
/// Most records kept per terminal; the spec asks terminals for at least 64.
pub const max_records = 64;

pub fn deinit(self: *TermStatus, gpa: Allocator) void {
    gpa.free(self.title);
    for (self.records.items) |r| freeRecord(gpa, r);
    self.records.deinit(gpa);
    self.* = undefined;
}

fn freeRecord(gpa: Allocator, r: Record) void {
    gpa.free(r.id);
    gpa.free(r.body);
}

/// Shows nothing: no title of ours, no records.
pub fn isEmpty(self: *const TermStatus) bool {
    return self.title.len == 0 and self.records.items.len == 0;
}

/// Sets the title, without control characters and cut to `max_title`.
pub fn setTitle(self: *TermStatus, gpa: Allocator, title: []const u8) !void {
    var buf: [max_title]u8 = undefined;
    const clean = cleanTitle(title, &buf);
    const owned = try gpa.dupe(u8, clean);
    gpa.free(self.title);
    self.title = owned;
}

/// Adds a record, or replaces the one with its id. Skips a record that's
/// malformed or past `max_records`, as a terminal would.
pub fn putRecord(self: *TermStatus, gpa: Allocator, id: []const u8, body: []const u8) !void {
    if (!validId(id) or !validBody(body)) return;
    const at = self.find(id);
    if (at.found) {
        const owned = try gpa.dupe(u8, body);
        gpa.free(self.records.items[at.index].body);
        self.records.items[at.index].body = owned;
        return;
    }
    if (self.records.items.len >= max_records) return;
    const owned_id = try gpa.dupe(u8, id);
    errdefer gpa.free(owned_id);
    const owned_body = try gpa.dupe(u8, body);
    errdefer gpa.free(owned_body);
    try self.records.insert(gpa, at.index, .{ .id = owned_id, .body = owned_body });
}

fn find(self: *const TermStatus, id: []const u8) struct { index: usize, found: bool } {
    for (self.records.items, 0..) |r, i| switch (std.mem.order(u8, r.id, id)) {
        .lt => {},
        .eq => return .{ .index = i, .found = true },
        .gt => return .{ .index = i, .found = false },
    };
    return .{ .index = self.records.items.len, .found = false };
}

fn get(self: *const TermStatus, id: []const u8) ?[]const u8 {
    const at = self.find(id);
    return if (at.found) self.records.items[at.index].body else null;
}

/// Replaces `self` with a copy of `other`.
pub fn copyFrom(self: *TermStatus, gpa: Allocator, other: *const TermStatus) !void {
    var next: TermStatus = .{};
    errdefer next.deinit(gpa);
    try next.setTitle(gpa, other.title);
    try next.records.ensureTotalCapacity(gpa, other.records.items.len);
    for (other.records.items) |r| try next.putRecord(gpa, r.id, r.body);
    self.deinit(gpa);
    self.* = next;
}

/// Writes what Rex needs to go from showing `sent` to showing `want`, then
/// makes `sent` a copy of `want`. Returns whether it wrote anything.
pub fn sync(gpa: Allocator, w: *std.Io.Writer, sent: *TermStatus, want: *const TermStatus) !bool {
    var wrote = false;
    if (!std.mem.eql(u8, sent.title, want.title)) {
        try writeTitle(w, want.title);
        wrote = true;
    }

    // a clear without an id clears every record: then send them all again
    const all_cleared = sent.get("") != null and want.get("") == null;
    if (all_cleared) {
        try writeReport(w, "state=clear");
        wrote = true;
    } else for (sent.records.items) |r| {
        // clearing an ancestor already clears it
        if (r.id.len == 0 or want.get(r.id) != null or underClearedId(sent, want, r.id)) continue;
        try w.print("\x1b]7501;state=clear:id={s}\x1b\\", .{r.id});
        wrote = true;
    }
    for (want.records.items) |r| {
        const unchanged = if (sent.get(r.id)) |b| std.mem.eql(u8, b, r.body) else false;
        // a clear above also removed every record under it
        if (unchanged and !all_cleared and !underClearedId(sent, want, r.id)) continue;
        try writeReport(w, r.body);
        wrote = true;
    }
    if (wrote) try sent.copyFrom(gpa, want);
    return wrote;
}

/// Undoes what `sent` showed, for a pane going back to whatever ran before.
pub fn reset(w: *std.Io.Writer, sent: *const TermStatus) !void {
    if (sent.title.len != 0) try writeTitle(w, "");
    if (sent.records.items.len != 0) try writeReport(w, "state=clear");
}

/// Some record above `id` was in `sent` and not in `want`, so the clear
/// written for it took `id` with it.
fn underClearedId(sent: *const TermStatus, want: *const TermStatus, id: []const u8) bool {
    for (sent.records.items) |r| {
        if (r.id.len == 0 or want.get(r.id) != null) continue;
        if (isUnder(id, r.id)) return true;
    }
    return false;
}

/// `id` is `parent`'s child, grandchild, and so on.
fn isUnder(id: []const u8, parent: []const u8) bool {
    return id.len > parent.len and std.mem.startsWith(u8, id, parent) and id[parent.len] == '/';
}

fn writeTitle(w: *std.Io.Writer, title: []const u8) !void {
    try w.print("\x1b]2;{s}\x1b\\", .{title});
}

fn writeReport(w: *std.Io.Writer, body: []const u8) !void {
    try w.print("\x1b]7501;{s}\x1b\\", .{body});
}

/// Printable ASCII only, so it can't end the sequence or start another.
/// The spec's own characters are a subset of these.
pub fn validBody(body: []const u8) bool {
    if (body.len == 0 or body.len > max_body) return false;
    for (body) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

/// The spec's id grammar, or "" for the root record.
pub fn validId(id: []const u8) bool {
    if (id.len > max_id) return false;
    if (id.len == 0) return true;
    var it = std.mem.splitScalar(u8, id, '/');
    var depth: usize = 0;
    while (it.next()) |seg| {
        depth += 1;
        if (seg.len == 0 or seg.len > 32 or depth > 8) return false;
        for (seg) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '+', '-' => {},
            else => return false,
        };
    }
    return true;
}

/// `title` without C0 or C1 controls or DEL, cut to fit `buf` without
/// splitting a character. Invalid UTF-8 is dropped.
pub fn cleanTitle(title: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(title) catch return "";
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp| {
        const c = std.unicode.utf8Decode(cp) catch continue;
        if (c < 0x20 or (c >= 0x7f and c <= 0x9f)) continue;
        if (n + cp.len > buf.len) break;
        @memcpy(buf[n..][0..cp.len], cp);
        n += cp.len;
    }
    return buf[0..n];
}

const testing = std.testing;

fn status(records: []const [2][]const u8, title: []const u8) !TermStatus {
    var s: TermStatus = .{};
    errdefer s.deinit(testing.allocator);
    try s.setTitle(testing.allocator, title);
    for (records) |r| try s.putRecord(testing.allocator, r[0], r[1]);
    return s;
}

/// What `sync` writes from `from` to `to`, and that it leaves `sent` equal to `to`.
fn expectSync(from: []const [2][]const u8, to: []const [2][]const u8, title: [2][]const u8, want: []const u8) !void {
    const gpa = testing.allocator;
    var sent = try status(from, title[0]);
    defer sent.deinit(gpa);
    var target = try status(to, title[1]);
    defer target.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const wrote = try sync(gpa, &out.writer, &sent, &target);
    try testing.expectEqualStrings(want, out.written());
    try testing.expectEqual(want.len != 0, wrote);
    // a second sync has nothing to do
    out.clearRetainingCapacity();
    try testing.expect(!try sync(gpa, &out.writer, &sent, &target));
}

test "title and root report reach the pane once" {
    try expectSync(&.{}, &.{.{ "", "state=working:app=claude-code" }}, .{ "", "Fix login" }, "\x1b]2;Fix login\x1b\\\x1b]7501;state=working:app=claude-code\x1b\\");
}

test "only what changed is sent again" {
    try expectSync(
        &.{ .{ "", "state=working:app=claude-code" }, .{ "agent1", "state=working" } },
        &.{ .{ "", "state=blocked:kind=permission:app=claude-code" }, .{ "agent1", "state=working" } },
        .{ "T", "T" },
        "\x1b]7501;state=blocked:kind=permission:app=claude-code\x1b\\",
    );
}

test "a parent and child both gone: one clear covers both" {
    try expectSync(
        &.{ .{ "", "state=idle" }, .{ "a", "state=working" }, .{ "a/b", "state=working" } },
        &.{.{ "", "state=idle" }},
        .{ "", "" },
        "\x1b]7501;state=clear:id=a\x1b\\",
    );
}

test "a record that went away is cleared by its id" {
    try expectSync(
        &.{ .{ "", "state=working" }, .{ "agent1", "state=working" } },
        &.{.{ "", "state=working" }},
        .{ "", "" },
        "\x1b]7501;state=clear:id=agent1\x1b\\",
    );
}

test "clearing a parent takes its children, which are sent again if kept" {
    try expectSync(
        &.{ .{ "a", "state=working" }, .{ "a/b", "state=working" } },
        &.{.{ "a/b", "state=working" }},
        .{ "", "" },
        "\x1b]7501;state=clear:id=a\x1b\\\x1b]7501;state=working\x1b\\",
    );
}

test "losing the root clears everything, then the rest is sent again" {
    try expectSync(
        &.{ .{ "", "state=working" }, .{ "x", "state=done" } },
        &.{.{ "x", "state=done" }},
        .{ "", "" },
        "\x1b]7501;state=clear\x1b\\\x1b]7501;state=done\x1b\\",
    );
}

test "switching to a buffer that isn't a terminal clears title and status" {
    try expectSync(&.{.{ "", "state=idle:app=claude-code" }}, &.{}, .{ "Claude Code", "" }, "\x1b]2;\x1b\\\x1b]7501;state=clear\x1b\\");
}

test "reset undoes only what was shown" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var none: TermStatus = .{};
    try reset(&out.writer, &none);
    try testing.expectEqualStrings("", out.written());

    var s = try status(&.{.{ "", "state=done" }}, "T");
    defer s.deinit(testing.allocator);
    try reset(&out.writer, &s);
    try testing.expectEqualStrings("\x1b]2;\x1b\\\x1b]7501;state=clear\x1b\\", out.written());
}

test "nothing from the program can end the sequence early" {
    try testing.expect(validBody("state=working:app=claude-code:msg=SGk="));
    try testing.expect(!validBody("state=working\x1b\\\x1b]52;c;cHduZWQ="));
    try testing.expect(!validBody("state=working\x07"));
    try testing.expect(!validBody("state=\xc2\x9b"));
    try testing.expect(!validBody(""));
    const too_long: [max_body + 1]u8 = @splat('a');
    try testing.expect(!validBody(&too_long));

    var buf: [max_title]u8 = undefined;
    try testing.expectEqualStrings("Fix]52;c;x login", cleanTitle("Fix\x1b]52;c;x\x07 login", &buf));
    try testing.expectEqualStrings("ab", cleanTitle("a\x1b\x07\x7fb", &buf));
    // C1 controls as UTF-8: U+009B is a CSI in some terminals
    try testing.expectEqualStrings("ab", cleanTitle("a\xc2\x9bb", &buf));
    try testing.expectEqualStrings("✳ Fix", cleanTitle("✳ Fix", &buf));
    try testing.expectEqualStrings("", cleanTitle("\xff", &buf));
    // cut without splitting a character
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("ab", cleanTitle("ab✳", &small));
}

test "ids follow the spec; bad ones and extra records are skipped" {
    try testing.expect(validId(""));
    try testing.expect(validId("build/test.unit-1"));
    try testing.expect(!validId("a//b"));
    try testing.expect(!validId("a b"));
    const long_segment: [33]u8 = @splat('x');
    try testing.expect(!validId(&long_segment));
    try testing.expect(!validId("a/b/c/d/e/f/g/h/i"));

    var s: TermStatus = .{};
    defer s.deinit(testing.allocator);
    try s.putRecord(testing.allocator, "bad id", "state=working");
    try s.putRecord(testing.allocator, "", "state=working\x1b");
    try testing.expectEqual(@as(usize, 0), s.records.items.len);
    var id_buf: [8]u8 = undefined;
    for (0..max_records + 5) |i| try s.putRecord(testing.allocator, try std.fmt.bufPrint(&id_buf, "r{d}", .{i}), "state=idle");
    try testing.expectEqual(@as(usize, max_records), s.records.items.len);
}

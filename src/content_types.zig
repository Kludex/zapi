//! Content-Type and Accept header parsing.
//! Parsers borrow input and do not allocate.

const std = @import("std");

pub const AcceptMatch = struct {
    q: u16,
    specificity: u8,
    order: usize,
};

pub fn mediaTypeOnly(value: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, value, ';')) |idx|
        std.mem.trim(u8, value[0..idx], " \t")
    else
        std.mem.trim(u8, value, " \t");
}

pub fn contentTypeMatches(content_type: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(mediaTypeOnly(content_type), mediaTypeOnly(expected));
}

pub fn acceptMatch(header: []const u8, offered: []const u8) ?AcceptMatch {
    const offered_media = mediaTypeOnly(offered);
    if (offered_media.len == 0) return null;

    var best: ?AcceptMatch = null;
    var it = std.mem.splitScalar(u8, header, ',');
    var order: usize = 0;
    while (it.next()) |raw_range| : (order += 1) {
        const range = std.mem.trim(u8, raw_range, " \t");
        if (range.len == 0) continue;

        const range_media = mediaTypeOnly(range);
        const q = acceptQuality(range);
        if (q == 0) continue;

        const specificity = acceptSpecificity(range_media, offered_media) orelse continue;
        const candidate = AcceptMatch{ .q = q, .specificity = specificity, .order = order };
        if (best == null or acceptMatchBetter(candidate, best.?)) best = candidate;
    }
    return best;
}

pub fn preferredAcceptMatch(header: []const u8, offers: []const []const u8) ?[]const u8 {
    var best_offer: ?[]const u8 = null;
    var best_match: ?AcceptMatch = null;
    var best_offer_index: usize = 0;

    for (offers, 0..) |offer, offer_index| {
        const candidate = acceptMatch(header, offer) orelse continue;
        if (best_match == null or acceptPreferredBetter(candidate, offer_index, best_match.?, best_offer_index)) {
            best_offer = offer;
            best_match = candidate;
            best_offer_index = offer_index;
        }
    }

    return best_offer;
}

pub fn acceptSpecificity(range: []const u8, offered: []const u8) ?u8 {
    if (std.mem.eql(u8, range, "*/*")) return 0;

    const range_slash = std.mem.indexOfScalar(u8, range, '/') orelse return null;
    const offered_slash = std.mem.indexOfScalar(u8, offered, '/') orelse return null;
    const range_type = std.mem.trim(u8, range[0..range_slash], " \t");
    const range_subtype = std.mem.trim(u8, range[range_slash + 1 ..], " \t");
    const offered_type = std.mem.trim(u8, offered[0..offered_slash], " \t");
    const offered_subtype = std.mem.trim(u8, offered[offered_slash + 1 ..], " \t");

    if (std.ascii.eqlIgnoreCase(range_type, "*") and std.mem.eql(u8, range_subtype, "*")) return 0;
    if (!std.ascii.eqlIgnoreCase(range_type, offered_type)) return null;
    if (std.mem.eql(u8, range_subtype, "*")) return 1;
    if (std.ascii.startsWithIgnoreCase(range_subtype, "*+")) {
        const suffix = range_subtype[1..];
        if (offered_subtype.len > suffix.len and std.ascii.endsWithIgnoreCase(offered_subtype, suffix)) return 2;
    }
    if (std.ascii.eqlIgnoreCase(range_subtype, offered_subtype)) return 3;
    return null;
}

pub fn acceptQuality(range: []const u8) u16 {
    var it = std.mem.splitScalar(u8, range, ';');
    _ = it.next();
    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const name = std.mem.trim(u8, part[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "q")) continue;
        const value = std.mem.trim(u8, part[eq + 1 ..], " \t");
        return parseQuality(value) orelse 0;
    }
    return 1000;
}

pub fn parseQuality(value: []const u8) ?u16 {
    if (std.mem.eql(u8, value, "1")) return 1000;
    if (std.mem.eql(u8, value, "0")) return 0;

    if (std.mem.startsWith(u8, value, "1.")) {
        for (value[2..]) |ch| {
            if (ch != '0') return null;
        }
        return 1000;
    }

    if (!std.mem.startsWith(u8, value, "0.")) return null;

    var q: u16 = 0;
    var multiplier: u16 = 100;
    var digits: usize = 0;
    for (value[2..]) |ch| {
        if (ch < '0' or ch > '9') return null;
        if (digits < 3) {
            q += @as(u16, ch - '0') * multiplier;
            multiplier /= 10;
        }
        digits += 1;
    }
    return q;
}

pub fn acceptMatchBetter(candidate: AcceptMatch, current: AcceptMatch) bool {
    if (candidate.q != current.q) return candidate.q > current.q;
    if (candidate.specificity != current.specificity) return candidate.specificity > current.specificity;
    return candidate.order < current.order;
}

pub fn acceptPreferredBetter(candidate: AcceptMatch, candidate_offer_index: usize, current: AcceptMatch, current_offer_index: usize) bool {
    if (candidate.q != current.q) return candidate.q > current.q;
    if (candidate.specificity != current.specificity) return candidate.specificity > current.specificity;
    if (candidate.order != current.order) return candidate.order < current.order;
    return candidate_offer_index < current_offer_index;
}

pub fn contentTypeParam(content_type: []const u8, param_name: []const u8) ?[]const u8 {
    return headerParam(content_type, param_name);
}

pub fn headerParam(value: []const u8, param_name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, value, ';');
    _ = it.next();
    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const name = std.mem.trim(u8, part[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(name, param_name)) continue;

        const raw_value = std.mem.trim(u8, part[eq + 1 ..], " \t");
        if (raw_value.len >= 2 and raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"') {
            return raw_value[1 .. raw_value.len - 1];
        }
        return raw_value;
    }
    return null;
}

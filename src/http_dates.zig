//! IMF-fixdate formatting and parsing for HTTP headers.
//! Functions use Unix timestamps in seconds.

const std = @import("std");

pub fn timestampSeconds(timestamp: std.Io.Timestamp) i64 {
    return @as(i64, @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_s)));
}

pub fn format(allocator: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{
        .secs = if (unix_seconds < 0) 0 else @as(u64, @intCast(unix_seconds)),
    };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const weekday_index: usize = @intCast(@mod(epoch_day.day + 4, 7));

    return std.fmt.allocPrint(
        allocator,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            httpWeekdayName(weekday_index),
            month_day.day_index + 1,
            httpMonthName(month_day.month),
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

pub fn parse(value: []const u8) ?i64 {
    const date = std.mem.trim(u8, value, " \t");
    if (date.len != 29) return null;
    if (date[3] != ',' or date[4] != ' ' or date[7] != ' ' or date[11] != ' ' or date[16] != ' ' or date[19] != ':' or date[22] != ':' or date[25] != ' ') return null;
    if (!std.mem.eql(u8, date[26..29], "GMT")) return null;

    const day = std.fmt.parseInt(u5, date[5..7], 10) catch return null;
    const month_number = parseHttpMonth(date[8..11]) orelse return null;
    const year = std.fmt.parseInt(std.time.epoch.Year, date[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u5, date[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u6, date[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u6, date[23..25], 10) catch return null;

    if (year < std.time.epoch.epoch_year) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    const month: std.time.epoch.Month = @enumFromInt(month_number);
    const days_in_month = std.time.epoch.getDaysInMonth(year, month);
    if (day == 0 or day > days_in_month) return null;

    var days: u64 = 0;
    var current_year: std.time.epoch.Year = std.time.epoch.epoch_year;
    while (current_year < year) : (current_year += 1) {
        days += std.time.epoch.getDaysInYear(current_year);
    }

    var current_month: std.time.epoch.Month = .jan;
    while (@intFromEnum(current_month) < month_number) {
        days += std.time.epoch.getDaysInMonth(year, current_month);
        current_month = @enumFromInt(@intFromEnum(current_month) + 1);
    }

    days += day - 1;
    const seconds = days * std.time.epoch.secs_per_day + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
    return @intCast(seconds);
}

pub fn parseHttpMonth(value: []const u8) ?u4 {
    if (std.mem.eql(u8, value, "Jan")) return 1;
    if (std.mem.eql(u8, value, "Feb")) return 2;
    if (std.mem.eql(u8, value, "Mar")) return 3;
    if (std.mem.eql(u8, value, "Apr")) return 4;
    if (std.mem.eql(u8, value, "May")) return 5;
    if (std.mem.eql(u8, value, "Jun")) return 6;
    if (std.mem.eql(u8, value, "Jul")) return 7;
    if (std.mem.eql(u8, value, "Aug")) return 8;
    if (std.mem.eql(u8, value, "Sep")) return 9;
    if (std.mem.eql(u8, value, "Oct")) return 10;
    if (std.mem.eql(u8, value, "Nov")) return 11;
    if (std.mem.eql(u8, value, "Dec")) return 12;
    return null;
}

pub fn httpMonthName(month: std.time.epoch.Month) []const u8 {
    return switch (month) {
        .jan => "Jan",
        .feb => "Feb",
        .mar => "Mar",
        .apr => "Apr",
        .may => "May",
        .jun => "Jun",
        .jul => "Jul",
        .aug => "Aug",
        .sep => "Sep",
        .oct => "Oct",
        .nov => "Nov",
        .dec => "Dec",
    };
}

pub fn httpWeekdayName(index: usize) []const u8 {
    return switch (index) {
        0 => "Sun",
        1 => "Mon",
        2 => "Tue",
        3 => "Wed",
        4 => "Thu",
        5 => "Fri",
        6 => "Sat",
        else => unreachable,
    };
}

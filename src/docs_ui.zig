//! Swagger UI and ReDoc HTML rendering.
//! Rendering escapes application metadata before embedding it in HTML or JavaScript.

const std = @import("std");

pub fn writeSwaggerUiHtml(writer: *std.Io.Writer, title: []const u8, openapi_url: []const u8, oauth2_redirect_url: ?[]const u8) !void {
    try writer.writeAll("<!doctype html>\n<html>\n<head><title>");
    try writeHtmlText(writer, title);
    try writer.writeAll(" - Swagger UI</title><link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist/swagger-ui.css\"></head>\n<body>\n<div id=\"swagger-ui\"></div>\n<script src=\"https://cdn.jsdelivr.net/npm/swagger-ui-dist/swagger-ui-bundle.js\"></script>\n<script>\nwindow.ui = SwaggerUIBundle({url: \"");
    try writeJavaScriptStringContents(writer, openapi_url);
    try writer.writeAll("\", dom_id: \"#swagger-ui\"");
    if (oauth2_redirect_url) |url| {
        try writer.writeAll(", oauth2RedirectUrl: window.location.origin + \"");
        try writeJavaScriptStringContents(writer, url);
        try writer.writeAll("\"");
    }
    try writer.writeAll("});\n</script>\n</body>\n</html>");
}

pub fn writeSwaggerUiOAuth2RedirectHtml(writer: *std.Io.Writer, title: []const u8) !void {
    try writer.writeAll("<!doctype html>\n<html>\n<head><title>");
    try writeHtmlText(writer, title);
    try writer.writeAll(
        " - Swagger UI OAuth2 Redirect</title></head>\n" ++
            "<body>\n<script>\n" ++
            "(function () {\n" ++
            "  var oauth2 = window.opener && window.opener.swaggerUIRedirectOauth2;\n" ++
            "  if (!oauth2) { window.close(); return; }\n" ++
            "  var query = (window.location.hash || window.location.search || '').replace(/^[#?]/, '');\n" ++
            "  var params = {};\n" ++
            "  query.split('&').forEach(function (part) {\n" ++
            "    if (!part) return;\n" ++
            "    var pair = part.split('=');\n" ++
            "    params[decodeURIComponent(pair[0])] = decodeURIComponent((pair[1] || '').replace(/\\+/g, ' '));\n" ++
            "  });\n" ++
            "  if (params.state !== oauth2.state) {\n" ++
            "    oauth2.errCb({ authId: oauth2.auth && oauth2.auth.name, source: 'oauth2-redirect', level: 'warning', message: 'OAuth2 state mismatch' });\n" ++
            "  } else if (params.code) {\n" ++
            "    oauth2.callback({ auth: oauth2.auth, redirectUrl: oauth2.redirectUrl, code: params.code });\n" ++
            "  } else {\n" ++
            "    oauth2.callback({ auth: oauth2.auth, token: params, isValid: true, redirectUrl: oauth2.redirectUrl });\n" ++
            "  }\n" ++
            "  window.close();\n" ++
            "}());\n" ++
            "</script>\n</body>\n</html>",
    );
}

pub fn writeRedocHtml(writer: *std.Io.Writer, title: []const u8, openapi_url: []const u8) !void {
    try writer.writeAll("<!doctype html>\n<html>\n<head><title>");
    try writeHtmlText(writer, title);
    try writer.writeAll(" - ReDoc</title></head>\n<body>\n<redoc spec-url=\"");
    try writeHtmlAttribute(writer, openapi_url);
    try writer.writeAll("\"></redoc>\n<script src=\"https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js\"></script>\n</body>\n</html>");
}

pub fn writeHtmlText(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(ch),
        }
    }
}

pub fn writeHtmlAttribute(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(ch),
        }
    }
}

pub fn writeJavaScriptStringContents(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '<' => try writer.writeAll("\\u003c"),
            '>' => try writer.writeAll("\\u003e"),
            '&' => try writer.writeAll("\\u0026"),
            0x00...0x08 => try writer.print("\\u{x:0>4}", .{ch}),
            0x0b...0x0c => try writer.print("\\u{x:0>4}", .{ch}),
            0x0e...0x1f => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
}

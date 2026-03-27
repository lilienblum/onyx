const std = @import("std");

pub const PackageRef = struct {
    source: ?[]const u8 = null,
    name: []const u8,
    version: ?[]const u8 = null,

    pub fn parse(s: []const u8) PackageRef {
        // Split off @version from the end
        var main = s;
        var version: ?[]const u8 = null;

        if (std.mem.lastIndexOfScalar(u8, main, '@')) |at_pos| {
            // Only treat as version if after the package identifier
            // Avoid splitting email-like patterns
            if (at_pos > 0) {
                version = main[at_pos + 1 ..];
                main = main[0..at_pos];
            }
        }

        var source: ?[]const u8 = null;
        var name = main;

        // user:repo (GitHub shorthand)
        if (std.mem.indexOfScalar(u8, main, ':')) |_| {
            source = main;
            name = main;
        }
        // domain.com (domain resolution) — contains .
        else if (std.mem.indexOfScalar(u8, main, '.') != null) {
            source = main;
            name = main;
        }

        return .{ .source = source, .name = name, .version = version };
    }

};

pub const UpgradeArgs = struct {
    self_only: bool = false,
    package: ?[]const u8 = null,
};

pub const ExecArgs = struct {
    package: PackageRef,
    bin: ?[]const u8 = null,
    args: []const []const u8,
};

pub const Command = union(enum) {
    install: PackageRef,
    uninstall: PackageRef,
    info: PackageRef,
    list,
    exec: ExecArgs,
    use_cmd: PackageRef,
    upgrade: UpgradeArgs,
    gc,
    init_cmd: bool, // true = --exec
    implode: bool, // true = --exec
    help,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len < 2) return .help;

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .install = PackageRef.parse(args[2]) };
    } else if (std.mem.eql(u8, cmd, "uninstall") or std.mem.eql(u8, cmd, "remove") or std.mem.eql(u8, cmd, "rm")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .uninstall = PackageRef.parse(args[2]) };
    } else if (std.mem.eql(u8, cmd, "info")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .info = PackageRef.parse(args[2]) };
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        return .list;
    } else if (std.mem.eql(u8, cmd, "exec") or std.mem.eql(u8, cmd, "x") or std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) return error.MissingArgument;
        var exec_args: []const []const u8 = &.{};
        var bin_name: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--")) {
                if (i + 1 < args.len) {
                    exec_args = args[i + 1 ..];
                }
                break;
            }
            if ((std.mem.eql(u8, args[i], "--bin") or std.mem.eql(u8, args[i], "-b")) and i + 1 < args.len) {
                i += 1;
                bin_name = args[i];
            }
        }
        return .{ .exec = .{
            .package = PackageRef.parse(args[2]),
            .bin = bin_name,
            .args = exec_args,
        } };
    } else if (std.mem.eql(u8, cmd, "use")) {
        if (args.len < 3) return error.MissingArgument;
        return .{ .use_cmd = PackageRef.parse(args[2]) };
    } else if (std.mem.eql(u8, cmd, "upgrade") or std.mem.eql(u8, cmd, "update")) {
        var ua = UpgradeArgs{};
        if (args.len >= 3) {
            if (std.mem.eql(u8, args[2], "--self")) {
                ua.self_only = true;
            } else {
                ua.package = args[2];
            }
        }
        return .{ .upgrade = ua };
    } else if (std.mem.eql(u8, cmd, "gc") or std.mem.eql(u8, cmd, "cleanup")) {
        return .gc;
    } else if (std.mem.eql(u8, cmd, "init") or std.mem.eql(u8, cmd, "setup")) {
        const exec = args.len >= 3 and std.mem.eql(u8, args[2], "--exec");
        return .{ .init_cmd = exec };
    } else if (std.mem.eql(u8, cmd, "implode")) {
        const exec = args.len >= 3 and std.mem.eql(u8, args[2], "--exec");
        return .{ .implode = exec };
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return .help;
    } else {
        return .help;
    }
}

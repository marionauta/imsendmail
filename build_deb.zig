const std = @import("std");

/// Adds a "deb" build step that creates a Debian package from the given executable.
/// The executable must target Linux and be built in release mode, otherwise the step will fail.
pub fn addDebStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const deb_step = b.step("deb", "Build Debian package");

    const resolved_target = exe.root_module.resolved_target.?;
    const os_tag = resolved_target.result.os.tag;

    if (exe.root_module.optimize == .Debug) {
        const m = "Building in debug mode. Add --release=safe";
        const warn_step = b.addFail(m);
        deb_step.dependOn(&warn_step.step);
    }

    if (os_tag != .linux) {
        const fail_step = b.addFail("Debian packages require a Linux target. Use -Dtarget=x86_64-linux or -Dtarget=aarch64-linux");
        deb_step.dependOn(&fail_step.step);
        return;
    }

    const cpu_arch = resolved_target.result.cpu.arch;
    const deb_arch: []const u8 = switch (cpu_arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .x86 => "i386",
        else => @tagName(cpu_arch),
    };

    const metadata = @import("build.zig.zon");
    const name = @tagName(metadata.name);
    const version = metadata.version;
    const maintainer = metadata.maintainer.name ++ " <" ++ metadata.maintainer.email ++ ">";
    const deb_name = b.fmt("sendmail-im_{s}_{s}.deb", .{ version, deb_arch });

    // Create package directory structure using WriteFiles
    const wf = b.addWriteFiles();

    // Binary goes in data archive
    _ = wf.addCopyFile(exe.getEmittedBin(), "data/usr/sbin/sendmail");

    // Control file for the control archive
    _ = wf.add("control/control", b.fmt(
        \\Package: {s}
        \\Version: {s}
        \\Section: mail
        \\Priority: optional
        \\Architecture: {s}
        \\Maintainer: {s}
        \\Description: {s}
        \\
    , .{ name, version, deb_arch, maintainer, metadata.description }));

    // debian-binary version file
    _ = wf.add("debian-binary", "2.0\n");

    // Create control.tar.gz (control file must be at archive root)
    const control_tar = b.addSystemCommand(&.{
        "tar", "-czf", "control.tar.gz", "--owner=0", "--group=0", "-C", "control", "control",
    });
    control_tar.setCwd(wf.getDirectory());
    control_tar.step.dependOn(&wf.step);

    // Create data.tar.gz
    const data_tar = b.addSystemCommand(&.{
        "tar", "-czf", "data.tar.gz", "--owner=0", "--group=0", "-C", "data", ".",
    });
    data_tar.setCwd(wf.getDirectory());
    data_tar.step.dependOn(&wf.step);

    // Create the .deb archive using ar (remove first to ensure clean creation)
    const ar_cmd = b.addSystemCommand(&.{ "sh", "-c" });
    ar_cmd.addArg(b.fmt("rm -f {s} && ar -rcS {s} debian-binary control.tar.gz data.tar.gz", .{ deb_name, deb_name }));
    ar_cmd.setCwd(wf.getDirectory());
    ar_cmd.step.dependOn(&control_tar.step);
    ar_cmd.step.dependOn(&data_tar.step);

    // Install the .deb to zig-out
    const install_deb = b.addInstallFile(wf.getDirectory().path(b, deb_name), deb_name);
    install_deb.step.dependOn(&ar_cmd.step);

    deb_step.dependOn(&install_deb.step);
}

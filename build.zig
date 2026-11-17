const std = @import("std");

// zforest-examples: the example apps for the zforest framework. All
// framework code lives in the sibling `zforest` repo (a path
// dependency); this repo only carries `src/apps/<name>/` app dirs and
// the build wiring that turns each into an exe.
//
// Framework modules are consumed through `dep.module(name)` — the SAME
// *Module objects the dep's own build created — so type identity
// (History/Dom/zefx/forest) holds across the boundary exactly as it
// did when apps lived in-tree. `zdb` carries the vendored sqlite3
// amalgamation + C flags on the module itself, so importing it here
// links sqlite exactly once per sqlite-using exe.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zforest_dep = b.dependency("zforest", .{});

    const zefx_mod = zforest_dep.module("zefx");
    const forest_mod = zforest_dep.module("forest");
    const zserver_mod = zforest_dep.module("zserver");
    const zmeta_mod = zforest_dep.module("zmeta");
    const db_mod = zforest_dep.module("zdb");

    const app_imports = [_]std.Build.Module.Import{
        .{ .name = "zefx", .module = zefx_mod },
        .{ .name = "forest", .module = forest_mod },
        .{ .name = "zserver", .module = zserver_mod },
        .{ .name = "zmeta", .module = zmeta_mod },
    };

    const sqlite_imports = [_]std.Build.Module.Import{
        .{ .name = "zefx", .module = zefx_mod },
        .{ .name = "forest", .module = forest_mod },
        .{ .name = "zserver", .module = zserver_mod },
        .{ .name = "zmeta", .module = zmeta_mod },
        .{ .name = "zdb", .module = db_mod },
    };

    // The todo app: per-session view state, todos persisted to SQLite
    // keyed by a `ztd` client cookie (apps/todo/store.zig → zdb).
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/todo/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &sqlite_imports,
    });
    const exe = b.addExecutable(.{ .name = "zforest", .root_module = exe_mod });

    b.installArtifact(exe);

    // The board app: shares the zefx/forest modules plus sqlite via zdb.
    const zboard_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/board/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &sqlite_imports,
    });

    const zboard = b.addExecutable(.{ .name = "zboard", .root_module = zboard_mod });

    b.installArtifact(zboard);

    // The zmon dashboard: same zefx/forest modules, no sqlite — but libc
    // for time(3) (wall-clock uptime/start timestamps).
    const zmon_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/mon/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    zmon_mod.link_libc = true;
    const zmon = b.addExecutable(.{ .name = "zmon", .root_module = zmon_mod });

    b.installArtifact(zmon);

    // The zcar booking app: same zefx/forest modules, no sqlite, no libc.
    const zcar_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/car/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    const zcar = b.addExecutable(.{ .name = "zcar", .root_module = zcar_mod });

    b.installArtifact(zcar);

    // zmeta codegen/scaffold live in the framework repo (std-only
    // tools); root local modules at the dep's source files so `zig
    // build gen` / `zig build new-app` run against THIS repo's
    // src/apps/ (setCwd below).
    const gen_mod = b.createModule(.{
        .root_source_file = zforest_dep.path("src/zmeta/gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gen_tool = b.addExecutable(.{ .name = "zmeta-gen", .root_module = gen_mod });
    const gen_step = b.step("gen", "Regenerate zmeta app gen/ files (routes.zig, actions.zig)");
    const gen_run = b.addRunArtifact(gen_tool);
    gen_run.setCwd(b.path("."));
    gen_step.dependOn(&gen_run.step);

    // `zig build new-app -- <name>`: scaffold src/apps/<name>/ (incl.
    // main.zig), then regenerate gen/ for the new app in the same
    // invocation (the scaffold step must finish first).
    const scaffold_mod = b.createModule(.{
        .root_source_file = zforest_dep.path("src/zmeta/scaffold.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scaffold_tool = b.addExecutable(.{ .name = "zmeta-new", .root_module = scaffold_mod });
    const new_app_step = b.step("new-app", "Scaffold a new zmeta app: zig build new-app -- <name>");
    const new_app_run = b.addRunArtifact(scaffold_tool);
    new_app_run.setCwd(b.path("."));
    new_app_run.addPassthruArgs();
    new_app_step.dependOn(&new_app_run.step);
    const gen_for_new = b.addRunArtifact(gen_tool);
    gen_for_new.step.dependOn(&new_app_run.step);
    new_app_step.dependOn(&gen_for_new.step);

    // The zmeta demo app: file-based routes with typed params + the
    // comptime action table, served through the zmeta Session skeleton.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/apps/zmeta_demo/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    const demo = b.addExecutable(.{ .name = "zmeta-demo", .root_module = demo_mod });

    b.installArtifact(demo);

    const run_step = b.step("run", "Run the todo server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_board_step = b.step("run-board", "Run the board server");
    const run_board_cmd = b.addRunArtifact(zboard);
    run_board_step.dependOn(&run_board_cmd.step);
    run_board_cmd.step.dependOn(b.getInstallStep());

    const run_mon_step = b.step("run-mon", "Run the zmon dashboard");
    const run_mon_cmd = b.addRunArtifact(zmon);
    run_mon_step.dependOn(&run_mon_cmd.step);
    run_mon_cmd.step.dependOn(b.getInstallStep());

    const run_car_step = b.step("run-car", "Run the zcar booking app");
    const run_car_cmd = b.addRunArtifact(zcar);
    run_car_step.dependOn(&run_car_cmd.step);
    run_car_cmd.step.dependOn(b.getInstallStep());

    const run_demo_step = b.step("run-demo", "Run the zmeta demo app");
    const run_demo_cmd = b.addRunArtifact(demo);
    run_demo_step.dependOn(&run_demo_cmd.step);
    run_demo_cmd.step.dependOn(b.getInstallStep());

    // App test binaries: each app's main.zig test block pulls in its
    // whole module graph; sqlite is linked into the zforest/zboard
    // test binaries via the shared zdb module.
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const zboard_tests = b.addTest(.{ .root_module = zboard_mod });
    const run_zboard_tests = b.addRunArtifact(zboard_tests);

    const zmon_tests = b.addTest(.{ .root_module = zmon_mod });
    const run_zmon_tests = b.addRunArtifact(zmon_tests);

    const zcar_tests = b.addTest(.{ .root_module = zcar_mod });
    const run_zcar_tests = b.addRunArtifact(zcar_tests);

    const demo_tests = b.addTest(.{ .root_module = demo_mod });
    const run_demo_tests = b.addRunArtifact(demo_tests);

    const test_step = b.step("test", "Run app tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_zboard_tests.step);
    test_step.dependOn(&run_zmon_tests.step);
    test_step.dependOn(&run_zcar_tests.step);
    test_step.dependOn(&run_demo_tests.step);
}

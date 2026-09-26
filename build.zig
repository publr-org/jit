const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: what a consumer imports as `publr_jit` (compile, themes, class merge).
    _ = b.addModule("publr_jit", .{
        .root_source_file = b.path("src/jit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const jit = b.addExecutable(.{
        .name = "jit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(jit);

    // Hand-written Zig `test "..."` blocks per module are the spec. No
    // external fixtures, no comparison harness.
    const test_step = b.step("test", "Run all unit tests");
    const test_roots = [_][]const u8{
        "src/theme.zig",
        "src/theme_test_import.zig",
        "src/theme_from_css.zig",
        "src/candidate.zig",
        "src/utilities.zig",
        "src/variants.zig",
        "src/sort.zig",
        "src/compile.zig",
        "src/class_merge.zig",
    };

    for (test_roots) |root| {
        const unit = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }

    // The checked-in single-file distribution must match canonical src/ and
    // expose the same public compile API used by downstream consumers.
    const check_amalgamation = b.addSystemCommand(&.{ "sh", "scripts/amalgamate-jit.sh", "--check" });
    check_amalgamation.has_side_effects = true;
    const amalgamation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/amalgamation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "publr_jit",
                .module = b.createModule(.{ .root_source_file = b.path("publr_jit.zig") }),
            }},
        }),
    });
    const run_amalgamation_tests = b.addRunArtifact(amalgamation_tests);
    run_amalgamation_tests.step.dependOn(&check_amalgamation.step);
    test_step.dependOn(&run_amalgamation_tests.step);

    const amalgamation_step = b.step("test-amalgamation", "Verify and test publr_jit.zig");
    amalgamation_step.dependOn(&run_amalgamation_tests.step);

    // Constraint check: every JIT-side artifact must compile to wasm32-wasi.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const jit_wasm = b.addExecutable(.{
        .name = "jit_wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    const wasm_step = b.step("test-wasm", "Compile-only check: jit builds for wasm32-wasi");
    wasm_step.dependOn(&b.addInstallArtifact(jit_wasm, .{}).step);

    // The RUNNABLE wasm: a freestanding reactor (no WASI, no entry point) that
    // exports the linear-memory ABI in src/wasm.zig. A Web Worker loads it and
    // calls compile(classes) -> CSS with no server. ReleaseSmall because the
    // artifact is downloaded by every client.
    const wasm_engine_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const jit_engine = b.addExecutable(.{
        .name = "jit_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_engine_target,
            .optimize = .ReleaseSmall,
        }),
    });
    jit_engine.entry = .disabled;
    jit_engine.rdynamic = true;
    jit_engine.export_memory = true;
    const wasm_engine_step = b.step("wasm-engine", "Build the freestanding browser CSS engine (jit_engine.wasm)");
    wasm_engine_step.dependOn(&b.addInstallArtifact(jit_engine, .{}).step);
}

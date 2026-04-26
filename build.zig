const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(lib);

    // Shared library for Python bindings
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(shared_lib);

    const shared_step = b.step("shared", "Build shared library for FFI");
    shared_step.dependOn(&shared_lib.step);

    // WebAssembly build
    const wasm = b.addExecutable(.{
        .name = "zpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wapi.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const wasm_step = b.step("wasm", "Build WebAssembly module");
    const install_wasm = b.addInstallArtifact(wasm, .{});
    wasm_step.dependOn(&install_wasm.step);

    // CLI tool (upstream-compat binary)
    const exe = b.addExecutable(.{
        .name = "zpdf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zpdf CLI");
    run_step.dependOn(&run_cmd.step);

    // pdf.zig CLI (NDJSON-streaming flavour, Week 3 of architecture.md §14).
    // Both binaries install to zig-out/bin/ side-by-side until Week 5 makes
    // pdf.zig canonical.
    const pdfzig_exe = b.addExecutable(.{
        .name = "pdf.zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_pdfzig.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(pdfzig_exe);

    const run_pdfzig = b.addRunArtifact(pdfzig_exe);
    run_pdfzig.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_pdfzig.addArgs(args);
    }
    const run_pdfzig_step = b.step("run-pdfzig", "Run the pdf.zig CLI");
    run_pdfzig_step.dependOn(&run_pdfzig.step);

    // Streaming-layer unit tests (uuid, tokenizer, stream, chunk, cli).
    // Each module's tests are also picked up via the main `test` step below.
    const stream_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli_pdfzig.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_stream_unit_tests = b.addRunArtifact(stream_unit_tests);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const simd_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_simd_unit_tests = b.addRunArtifact(simd_unit_tests);

    const decompress_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decompress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_decompress_unit_tests = b.addRunArtifact(decompress_unit_tests);

    const parser_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_parser_unit_tests = b.addRunArtifact(parser_unit_tests);

    const xref_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/xref.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_xref_unit_tests = b.addRunArtifact(xref_unit_tests);

    const encoding_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/encoding.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_encoding_unit_tests = b.addRunArtifact(encoding_unit_tests);

    const interpreter_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interpreter.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_interpreter_unit_tests = b.addRunArtifact(interpreter_unit_tests);

    const testpdf_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testpdf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_testpdf_unit_tests = b.addRunArtifact(testpdf_unit_tests);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_simd_unit_tests.step);
    test_step.dependOn(&run_decompress_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
    test_step.dependOn(&run_xref_unit_tests.step);
    test_step.dependOn(&run_encoding_unit_tests.step);
    test_step.dependOn(&run_interpreter_unit_tests.step);
    test_step.dependOn(&run_testpdf_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_stream_unit_tests.step);

    // Allocation-failure tests — Week 4 of architecture.md §11.
    // Asserts the documented shape of upstream OOM behaviour (Findings 001–003
    // in audit/fuzz_findings.md). Run separately from `test` so upstream-test
    // leak detection on this harness's transitively-imported tests doesn't
    // pollute the main test suite.
    const alloc_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/alloc_failure_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_alloc_test = b.addRunArtifact(alloc_test);
    const alloc_test_step = b.step("alloc-failure-test", "Run checkAllAllocationFailures coverage on parse paths");
    alloc_test_step.dependOn(&run_alloc_test.step);

    // Fuzz harness — Week 4 of architecture.md §11.
    // 11 targets at 1M iters by default; PDFZIG_FUZZ_ITERS / PDFZIG_FUZZ_TARGET
    // / PDFZIG_FUZZ_SEED env vars override at run time.
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| run_fuzz.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run the Week-4 fuzz harness (PDFZIG_FUZZ_ITERS overrides 1M default)");
    fuzz_step.dependOn(&run_fuzz.step);

    // Benchmark
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}

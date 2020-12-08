import os

from emscripten_helpers import run_closure_compiler, create_engine_file, add_js_libraries
from SCons.Util import WhereIs


def is_active():
    return True


def get_name():
    return "JavaScript"


def can_build():
    return WhereIs("emcc") is not None


def get_opts():
    from SCons.Variables import BoolVariable

    return [
        # eval() can be a security concern, so it can be disabled.
        BoolVariable("javascript_eval", "Enable JavaScript eval interface", True),
        BoolVariable("threads_enabled", "Enable WebAssembly Threads support (limited browser support)", False),
        BoolVariable("gdnative_enabled", "Enable WebAssembly GDNative support (produces bigger binaries)", False),
        BoolVariable("use_closure_compiler", "Use closure compiler to minimize JavaScript code", False),
    ]


def get_flags():
    return [
        ("tools", False),
        ("builtin_pcre2_with_jit", False),
        # Disabling the mbedtls module reduces file size.
        # The module has little use due to the limited networking functionality
        # in this platform. For the available networking methods, the browser
        # manages TLS.
        ("module_mbedtls_enabled", False),
    ]


def configure(env):

    ## Build type

    if env["target"] == "release":
        # Use -Os to prioritize optimizing for reduced file size. This is
        # particularly valuable for the web platform because it directly
        # decreases download time.
        # -Os reduces file size by around 5 MiB over -O3. -Oz only saves about
        # 100 KiB over -Os, which does not justify the negative impact on
        # run-time performance.
        env.Append(CCFLAGS=["-Os"])
        env.Append(LINKFLAGS=["-Os"])
    elif env["target"] == "release_debug":
        env.Append(CCFLAGS=["-Os"])
        env.Append(LINKFLAGS=["-Os"])
        env.Append(CPPDEFINES=["DEBUG_ENABLED"])
        # Retain function names for backtraces at the cost of file size.
        env.Append(LINKFLAGS=["--profiling-funcs"])
    else:  # "debug"
        env.Append(CPPDEFINES=["DEBUG_ENABLED"])
        env.Append(CCFLAGS=["-O1", "-g"])
        env.Append(LINKFLAGS=["-O1", "-g"])
        env.Append(LINKFLAGS=["-s", "ASSERTIONS=1"])

    if env["tools"]:
        if not env["threads_enabled"]:
            raise RuntimeError(
                "Threads must be enabled to build the editor. Please add the 'threads_enabled=yes' option"
            )
        # Tools need more memory. Initial stack memory in bytes. See `src/settings.js` in emscripten repository (will be renamed to INITIAL_MEMORY).
        env.Append(LINKFLAGS=["-s", "TOTAL_MEMORY=33554432"])
    elif env["builtin_icu"]:
        env.Append(CCFLAGS=["-frtti"])
    else:
        # Disable exceptions and rtti on non-tools (template) builds
        # These flags help keep the file size down.
        env.Append(CCFLAGS=["-fno-exceptions", "-fno-rtti"])
        # Don't use dynamic_cast, necessary with no-rtti.
        env.Append(CPPDEFINES=["NO_SAFE_CAST"])

    ## Copy env variables.
    env["ENV"] = os.environ

    # LTO
    if env["use_lto"]:
        env.Append(CCFLAGS=["-flto=full"])
        env.Append(LINKFLAGS=["-flto=full"])

    # Closure compiler
    if env["use_closure_compiler"]:
        # For emscripten support code.
        env.Append(LINKFLAGS=["--closure", "1"])
        # Register builder for our Engine files
        jscc = env.Builder(generator=run_closure_compiler, suffix=".cc.js", src_suffix=".js")
        env.Append(BUILDERS={"BuildJS": jscc})

    # Add helper method for adding libraries.
    env.AddMethod(add_js_libraries, "AddJSLibraries")

    # Add method that joins/compiles our Engine files.
    env.AddMethod(create_engine_file, "CreateEngineFile")

    # Closure compiler extern and support for ecmascript specs (const, let, etc).
    env["ENV"]["EMCC_CLOSURE_ARGS"] = "--language_in ECMASCRIPT6"

    env["CC"] = "emcc"
    env["CXX"] = "em++"

    env["AR"] = "emar"
    env["RANLIB"] = "emranlib"

    # Use TempFileMunge since some AR invocations are too long for cmd.exe.
    # Use POSIX-style paths, required with TempFileMunge.
    env["ARCOM_POSIX"] = env["ARCOM"].replace("$TARGET", "$TARGET.posix").replace("$SOURCES", "$SOURCES.posix")
    env["ARCOM"] = "${TEMPFILE(ARCOM_POSIX)}"

    # All intermediate files are just LLVM bitcode.
    env["OBJPREFIX"] = ""
    env["OBJSUFFIX"] = ".bc"
    env["PROGPREFIX"] = ""
    # Program() output consists of multiple files, so specify suffixes manually at builder.
    env["PROGSUFFIX"] = ""
    env["LIBPREFIX"] = "lib"
    env["LIBSUFFIX"] = ".bc"
    env["LIBPREFIXES"] = ["$LIBPREFIX"]
    env["LIBSUFFIXES"] = ["$LIBSUFFIX"]

    env.Prepend(CPPPATH=["#platform/javascript"])
    env.Append(CPPDEFINES=["JAVASCRIPT_ENABLED", "UNIX_ENABLED"])

    if env["javascript_eval"]:
        env.Append(CPPDEFINES=["JAVASCRIPT_EVAL_ENABLED"])

    if env["threads_enabled"] and env["gdnative_enabled"]:
        raise Exception("Threads and GDNative support can't be both enabled due to WebAssembly limitations")

    # Thread support (via SharedArrayBuffer).
    if env["threads_enabled"]:
        env.Append(CPPDEFINES=["PTHREAD_NO_RENAME"])
        env.Append(CCFLAGS=["-s", "USE_PTHREADS=1"])
        env.Append(LINKFLAGS=["-s", "USE_PTHREADS=1"])
        env.Append(LINKFLAGS=["-s", "PTHREAD_POOL_SIZE=8"])
        env.Append(LINKFLAGS=["-s", "WASM_MEM_MAX=2048MB"])
        env.extra_suffix = ".threads" + env.extra_suffix
    else:
        env.Append(CPPDEFINES=["NO_THREADS"])

    if env["gdnative_enabled"]:
        env.Append(CCFLAGS=["-s", "RELOCATABLE=1"])
        env.Append(LINKFLAGS=["-s", "RELOCATABLE=1"])
        env.extra_suffix = ".gdnative" + env.extra_suffix

    # Reduce code size by generating less support code (e.g. skip NodeJS support).
    env.Append(LINKFLAGS=["-s", "ENVIRONMENT=web,worker"])

    # Wrap the JavaScript support code around a closure named Godot.
    env.Append(LINKFLAGS=["-s", "MODULARIZE=1", "-s", "EXPORT_NAME='Godot'"])

    # Allow increasing memory buffer size during runtime. This is efficient
    # when using WebAssembly (in comparison to asm.js) and works well for
    # us since we don't know requirements at compile-time.
    env.Append(LINKFLAGS=["-s", "ALLOW_MEMORY_GROWTH=1"])

    # This setting just makes WebGL 2 APIs available, it does NOT disable WebGL 1.
    env.Append(LINKFLAGS=["-s", "USE_WEBGL2=1"])

    # Do not call main immediately when the support code is ready.
    env.Append(LINKFLAGS=["-s", "INVOKE_RUN=0"])

    # Allow use to take control of swapping WebGL buffers.
    env.Append(LINKFLAGS=["-s", "OFFSCREEN_FRAMEBUFFER=1"])

    # callMain for manual start.
    env.Append(LINKFLAGS=["-s", "EXTRA_EXPORTED_RUNTIME_METHODS=['callMain']"])

    # Add code that allow exiting runtime.
    env.Append(LINKFLAGS=["-s", "EXIT_RUNTIME=1"])

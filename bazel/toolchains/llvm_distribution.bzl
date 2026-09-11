"""Fetches an official LLVM release distribution, optionally merging an ICU
runtime into it.

LLVM's released ld.lld is built on Ubuntu 22.04 and links ICU 70 by soname
and by version-suffixed symbol, so it cannot start on a host shipping any
other ICU major. Merging those libraries into the tree's lib/ satisfies
ld.lld's own RUNPATH, which needs no wrapper and no LD_LIBRARY_PATH.

Instantiated twice: once for the exec side, which gets the overlay and the
self-check, and once as a bare aarch64 library donor whose binaries never
execute here.

Depends on @toolchains_llvm//toolchain:BUILD.llvm_repo.tpl's {LLVM_VERSION}
placeholder, consumed here via .format(); validated against toolchains_llvm
1.9.0.
"""

load("@llvm_distributions_data//:data.bzl", "LLVM_DISTRIBUTIONS", "LLVM_DISTRIBUTION_URLS")

_TAR_ZST_SUFFIX = ".tar.zst"

# --- ICU overlay constants -------------------------------------------------
# Bumping the ICU version touches these two plus the overlay_* attributes set
# at each llvm_distribution() call site in MODULE.bazel.

# The upstream ICU tarball's own top-level folder. Stripped on extraction so
# that the `overlay_lib_dir` attribute value matches what a reader of the
# tarball's own layout expects ("usr/local/lib"), not "icu/usr/local/lib".
_ICU_OVERLAY_STRIP_PREFIX = "icu"

_ICU_RUNTIME_FILEGROUP = """
# Declared as a link-action input because the exec root's own lib filegroup
# globs only libc++*.a and libunwind.a, so nothing else places these in the
# sandbox.
filegroup(
    name = "icu_runtime",
    srcs = glob(["lib/libicu*.so.70*"]),
)
"""

def _fetch_llvm(rctx):
    """Fetch basename from @toolchains_llvm's own published distribution table.

    LLVM_DISTRIBUTIONS/LLVM_DISTRIBUTION_URLS are the same maps
    @toolchains_llvm's own llvm.toolchain() extension uses, so adding an LLVM
    release needs no hand-edited constant or URL template here.
    """
    basename = "LLVM-{}-{}{}".format(rctx.attr.llvm_version, rctx.attr.distribution, _TAR_ZST_SUFFIX)
    sha256 = LLVM_DISTRIBUTIONS.get(basename)
    url = LLVM_DISTRIBUTION_URLS.get(basename)
    if not sha256 or not url:
        fail((
            "llvm_distribution: '{basename}' is not in @toolchains_llvm's " +
            "distribution table (@llvm_distributions_data//:data.bzl). Check " +
            "the llvm_version/distribution attributes."
        ).format(basename = basename))
    strip_prefix = basename[:-len(_TAR_ZST_SUFFIX)]
    rctx.download_and_extract(
        url = url,
        sha256 = sha256,
        stripPrefix = strip_prefix,
    )

def _copy_icu_overlay(rctx):
    """Merge the pinned ICU sonames into the distribution's lib/.

    Copies each requested soname and the real file its symlink points at.

    Extracted to a scratch subdirectory rather than over the LLVM tree, so
    the tarball's own usr/local/ hierarchy never reaches a glob in the
    rendered BUILD file.
    """
    if not rctx.attr.overlay_sha256 or not rctx.attr.overlay_lib_dir or not rctx.attr.overlay_libs:
        fail((
            "llvm_distribution: overlay_urls is set but overlay_sha256/" +
            "overlay_lib_dir/overlay_libs is empty. An ICU overlay must be " +
            "fully pinned (checksummed and enumerated) or not requested at " +
            "all -- an unpinned fetch is code that runs unverified on the " +
            "next build."
        ))
    rctx.download_and_extract(
        url = rctx.attr.overlay_urls,
        sha256 = rctx.attr.overlay_sha256,
        output = "_icu_overlay",
        stripPrefix = _ICU_OVERLAY_STRIP_PREFIX,
    )

    overlay_lib_dir = rctx.path("_icu_overlay/" + rctx.attr.overlay_lib_dir)
    if not overlay_lib_dir.exists:
        fail("llvm_distribution: overlay_lib_dir '{}' does not exist under the extracted ICU tarball ({}).".format(
            rctx.attr.overlay_lib_dir,
            overlay_lib_dir,
        ))

    available = {entry.basename: entry for entry in overlay_lib_dir.readdir()}
    for soname in rctx.attr.overlay_libs:
        matches = [name for name in available.keys() if name == soname or name.startswith(soname + ".")]
        if not matches:
            fail("llvm_distribution: no file matching soname '{}' under {}. Present: {}.".format(
                soname,
                overlay_lib_dir,
                ", ".join(sorted(available.keys())),
            ))
        for name in matches:
            # -d preserves the tarball's own soname symlinks (e.g.
            # libicui18n.so.70 -> libicui18n.so.70.1) instead of turning
            # each symlink into its own ~10-30 MB copy of the real file.
            result = rctx.execute(["cp", "-d", str(available[name]), "lib/" + name])
            if result.return_code != 0:
                fail("llvm_distribution: failed to copy {} into lib/: {}".format(name, result.stderr))

    rctx.delete("_icu_overlay")

def _render_build(rctx):
    major_version = rctx.attr.llvm_version.split(".")[0]
    template = rctx.read(Label("@toolchains_llvm//toolchain:BUILD.llvm_repo.tpl"))
    content = template.format(LLVM_VERSION = major_version)
    if rctx.attr.overlay_urls:
        content += _ICU_RUNTIME_FILEGROUP
    rctx.file("BUILD.bazel", content, executable = False)

def _self_check_ld_lld(rctx):
    """Prove the merged tree's linker can start.

    Fails here rather than at whichever link action happens to run first.

    Detection only: there is nothing to fall back to, so the rule does not
    try.
    """
    result = rctx.execute(["bin/ld.lld", "--version"])
    if result.return_code != 0:
        fail("llvm_distribution: 'bin/ld.lld --version' failed in {} (exit {}). stderr:\n{}".format(
            rctx.path("."),
            result.return_code,
            result.stderr,
        ))

def _llvm_distribution_impl(rctx):
    _fetch_llvm(rctx)

    has_overlay = bool(rctx.attr.overlay_urls)
    if has_overlay:
        _copy_icu_overlay(rctx)

    _render_build(rctx)

    if has_overlay:
        _self_check_ld_lld(rctx)

llvm_distribution = repository_rule(
    implementation = _llvm_distribution_impl,
    attrs = {
        "llvm_version": attr.string(
            mandatory = True,
            doc = "LLVM release version, e.g. '23.1.0'. Its major component substitutes {LLVM_VERSION} in BUILD.llvm_repo.tpl.",
        ),
        "distribution": attr.string(
            mandatory = True,
            doc = "LLVM release distribution suffix, e.g. 'Linux-X64' or 'Linux-ARM64', combined with llvm_version into the official release basename.",
        ),
        "overlay_urls": attr.string_list(
            default = [],
            doc = "URL(s) of the ICU overlay tarball. Empty on a target-side (library-donor-only) instantiation: no merge and no self-check run.",
        ),
        "overlay_sha256": attr.string(
            default = "",
            doc = "Expected sha256 of the overlay tarball.",
        ),
        "overlay_lib_dir": attr.string(
            default = "",
            doc = "Directory inside the extracted (and prefix-stripped) overlay holding the shared objects to copy, e.g. 'usr/local/lib'.",
        ),
        "overlay_libs": attr.string_list(
            default = [],
            doc = "Soname prefixes to copy from overlay_lib_dir into lib/, e.g. 'libicui18n.so.70'.",
        ),
    },
)

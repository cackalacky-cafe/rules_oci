"""Repository rules for fetching external tools"""

load("@aspect_bazel_lib//lib:repositories.bzl", "register_yq_toolchains")
load("//oci/private:toolchains_repo.bzl", "PLATFORMS", "toolchains_repo")
load("//oci/private:versions.bzl", "CRANE_VERSIONS", "ZOT_VERSIONS")

LATEST_CRANE_VERSION = CRANE_VERSIONS.keys()[0]
LATEST_ZOT_VERSION = ZOT_VERSIONS.keys()[0]

CRANE_BUILD_TMPL = """\
# Generated by container/repositories.bzl
load("@contrib_rules_oci//oci:toolchain.bzl", "crane_toolchain")
crane_toolchain(
    name = "crane_toolchain", 
    crane = select({
        "@bazel_tools//src/conditions:host_windows": "crane.exe",
        "//conditions:default": "crane",
    }),
)
"""

def _crane_repo_impl(repository_ctx):
    url = "https://github.com/google/go-containerregistry/releases/download/{version}/go-containerregistry_{platform}.tar.gz".format(
        version = repository_ctx.attr.crane_version,
        platform = repository_ctx.attr.platform[:1].upper() + repository_ctx.attr.platform[1:],
    )
    repository_ctx.download_and_extract(
        url = url,
        integrity = CRANE_VERSIONS[repository_ctx.attr.crane_version][repository_ctx.attr.platform],
    )
    repository_ctx.file("BUILD.bazel", CRANE_BUILD_TMPL)

crane_repositories = repository_rule(
    _crane_repo_impl,
    doc = "Fetch external tools needed for crane toolchain",
    attrs = {
        "crane_version": attr.string(mandatory = True, values = CRANE_VERSIONS.keys()),
        "platform": attr.string(mandatory = True, values = PLATFORMS.keys()),
    },
)

ZOT_BUILD_TMPL = """\
# Generated by container/repositories.bzl
load("@contrib_rules_oci//oci:toolchain.bzl", "registry_toolchain")
registry_toolchain(
    name = "zot_toolchain", 
    registry = "zot",
    launcher = "launcher.sh"
)
"""

ZOT_LAUNCHER_TMPL = """\
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
ZOT="${SCRIPT_DIR}/zot"

function start_registry() {
    local CONFIG_PATH="$1/config.json"
    cat > "${CONFIG_PATH}" <<EOF
{
    "storage": {"rootDirectory": "$1" },
    "http": { "port": "0", "address": "127.0.0.1" },
    "log": { "level": "info" }
}
EOF

    local OUTPUT="$2"

    "${ZOT}" serve "${CONFIG_PATH}" 2>&1 >> "${OUTPUT}" &

    local DEADLINE=5
    local TIMEOUT=$((SECONDS+${DEADLINE}))

    while [ "${SECONDS}" -lt "${TIMEOUT}" ]; do
        PORT=$(cat $OUTPUT | sed -nr 's/.+"port":([0-9]+),.+/\\1/p')
        if [ -n "${PORT}" ]; then
            break
        fi
    done
    if [ -n "${PORT}" ]; then
        echo "Exhausted: registry couldn't become ready within ${DEADLINE}s." >> "${OUTPUT}"
    fi
    REGISTRY="127.0.0.1:${PORT}"
}
"""

def _zot_repo_impl(repository_ctx):
    platform = repository_ctx.attr.platform.replace("x86_64", "amd64").replace("_", "-")
    url = "https://github.com/project-zot/zot/releases/download/{version}/zot-{platform}".format(
        version = repository_ctx.attr.zot_version,
        platform = platform,
    )
    repository_ctx.download(
        url = url,
        output = "zot",
        executable = True,
        integrity = ZOT_VERSIONS[repository_ctx.attr.zot_version][platform],
    )
    repository_ctx.file("launcher.sh", ZOT_LAUNCHER_TMPL)
    repository_ctx.file("BUILD.bazel", ZOT_BUILD_TMPL)

zot_repositories = repository_rule(
    _zot_repo_impl,
    doc = "Fetch external tools needed for zot toolchain",
    attrs = {
        "zot_version": attr.string(mandatory = True, values = ZOT_VERSIONS.keys()),
        "platform": attr.string(mandatory = True, values = PLATFORMS.keys()),
    },
)

# Wrapper macro around everything above, this is the primary API
def oci_register_toolchains(name, crane_version, zot_version):
    """Convenience macro for users which does typical setup.

    - create a repository for each built-in platform like "container_linux_amd64" -
      this repository is lazily fetched when node is needed for that platform.
    - create a repository exposing toolchains for each platform like "container_platforms"
    - register a toolchain pointing at each platform
    Users can avoid this macro and do these steps themselves, if they want more control.
    Args:
        name: base name for all created repos, like "container7"
        crane_version: passed to each crane_repositories call
        zot_version: passed to each zot_repositories call
    """

    register_yq_toolchains()

    crane_toolchain_name = "{name}_crane_toolchains".format(name = name)
    zot_toolchain_name = "{name}_zot_toolchains".format(name = name)

    for platform in PLATFORMS.keys():
        crane_repositories(
            name = "{name}_crane_{platform}".format(name = name, platform = platform),
            platform = platform,
            crane_version = crane_version,
        )
        native.register_toolchains("@{}//:{}_toolchain".format(crane_toolchain_name, platform))

        zot_repositories(
            name = "{name}_zot_{platform}".format(name = name, platform = platform),
            platform = platform,
            zot_version = zot_version,
        )
        native.register_toolchains("@{}//:{}_toolchain".format(zot_toolchain_name, platform))

    toolchains_repo(
        name = crane_toolchain_name,
        toolchain_type = "@contrib_rules_oci//oci:crane_toolchain_type",
        # avoiding use of .format since {platform} is formatted by toolchains_repo for each platform.
        toolchain = "@%s_crane_{platform}//:crane_toolchain" % name,
    )

    toolchains_repo(
        name = zot_toolchain_name,
        toolchain_type = "@contrib_rules_oci//oci:registry_toolchain_type",
        # avoiding use of .format since {platform} is formatted by toolchains_repo for each platform.
        toolchain = "@%s_zot_{platform}//:zot_toolchain" % name,
    )

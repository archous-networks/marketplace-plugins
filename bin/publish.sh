#!/usr/bin/env bash
#
# publish.sh — stage a built plugin ZIP, then regenerate plugins.json.
#
#   bin/publish.sh stage <plugin-name> <path/to/built.zip>
#   bin/publish.sh index                    # regenerate plugins.json at HEAD
#   bin/publish.sh release <name> <zip>     # stage + commit + index + commit
#
# Two steps, and the order matters. `zipUrl` pins the COMMIT SHA that contains the
# archive, so the artifact stays immutable even if the branch moves — the same
# thing Ubiquiti does in Ubiquiti-App/UCRM-plugins. A SHA cannot be known until
# the commit exists, so the ZIP is committed first and the index second.
#
# Filenames are fixed per plugin (`<name>/<name>.zip`), not versioned: the version
# lives in plugins.json and history holds the old bytes, so nothing accumulates in
# the tree.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO_SLUG="${REPO_SLUG:-archous-networks/marketplace-plugins}"

die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

stage() {
    local name="$1" zip="$2"

    [[ -f "$zip" ]] || die "no such file: $zip"

    # Trust the archive over the argument: the manifest is what UISP reads.
    local declared
    declared="$(php -r '
        $z = new ZipArchive;
        if ($z->open($argv[1]) !== true) { fwrite(STDERR, "not a readable ZIP\n"); exit(1); }
        $m = json_decode((string) $z->getFromName("manifest.json"), true);
        echo $m["information"]["name"] ?? "";
    ' "$zip")"

    [[ -n "$declared" ]] || die "$zip has no manifest.json at its root"
    [[ "$declared" == "$name" ]] || die "ZIP declares plugin '$declared', not '$name'"

    mkdir -p "plugins/$name"
    cp "$zip" "plugins/$name/$name.zip"
    ok "staged plugins/$name/$name.zip"
}

index() {
    local sha
    sha="$(git rev-parse HEAD)"

    php -r '
        $root = $argv[1]; $slug = $argv[2]; $sha = $argv[3];
        $out = [];

        // Hand-maintained, and the ONLY hand-maintained input to this file —
        // everything else below is read out of the published archives. See
        // dependencies.json for why it is not kept in plugins.json itself.
        $deps = json_decode((string) @file_get_contents("$root/dependencies.json"), true);
        $deps = is_array($deps["dependencies"] ?? null) ? $deps["dependencies"] : [];

        foreach (glob("$root/plugins/*/*.zip") as $zipPath) {
            $z = new ZipArchive;
            if ($z->open($zipPath) !== true) { continue; }

            $m = json_decode((string) $z->getFromName("manifest.json"), true);
            $z->close();

            $i = $m["information"] ?? null;
            if (!is_array($i)) { continue; }

            $name = $i["name"];

            $entry = [
                "name"        => $name,
                "displayName" => $i["displayName"] ?? $name,
                "description" => $i["description"] ?? "",
                "url"         => $i["url"] ?? "",
                "version"     => $i["version"] ?? "0.0.0",
                "author"      => $i["author"] ?? "",
                // Other Archous plugins this one needs. The marketplace installs
                // them first and refuses to remove them while this is installed.
                "dependencies" => array_values(array_map("strval", (array) ($deps[$name] ?? []))),
                // zipUrl pins the SHA so a published version means one exact
                // byte sequence, permanently — a branch URL would not.
                "zipUrl"      => sprintf("https://github.com/%s/raw/%s/plugins/%s/%s.zip", $slug, $sha, $name, $name),
                "sha256"      => hash_file("sha256", $zipPath),
            ];

            // Compliancy is what UISP uses to decide installability; carry it
            // through verbatim rather than inventing defaults.
            foreach (["unmsVersionCompliancy", "ucrmVersionCompliancy"] as $k) {
                if (isset($i[$k])) { $entry[$k] = $i[$k]; }
            }

            $out[] = $entry;
        }

        usort($out, static fn(array $a, array $b): int => strcmp($a["name"], $b["name"]));

        file_put_contents(
            "$root/plugins.json",
            json_encode(["plugins" => $out], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n"
        );

        printf("indexed %d plugin(s) at %s\n", count($out), substr($sha, 0, 8));
    ' "$ROOT" "$REPO_SLUG" "$sha"
}

case "${1:-}" in
    stage) shift; stage "$1" "$2" ;;
    index) index ;;
    release)
        shift
        stage "$1" "$2"
        git add "plugins/$1/$1.zip"
        git commit -q -m "Publish $1 artifact" || true
        index
        git add plugins.json
        version="$(php -r '$d=json_decode(file_get_contents("plugins.json"),true); foreach($d["plugins"] as $p){ if($p["name"]===$argv[1]) echo $p["version"]; }' "$1")"
        git commit -q -m "Index $1 $version" || true

        # Tag the release so `name@<version>` in a marketplace `plugins` entry has
        # something to resolve against. The plugin derives the archive URL by
        # convention from this tag — plugins.json only ever describes the CURRENT
        # version, so a pin to an older one has no index to read.
        #
        # Per-plugin, because one repo holds several and a bare v3.7.2 could not
        # say whose. The tag must point at the commit whose tree holds that
        # version's ZIP, which is this one — the index commit, after staging.
        tag="$1-v$version"

        if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
            # Retagging would silently move a published version to different bytes,
            # which is exactly the guarantee the SHA-pinned zipUrl exists to give.
            die "tag $tag already exists — bump the version rather than republishing it"
        fi

        git tag -a "$tag" -m "$1 $version"
        ok "released $1 $version (tagged $tag)"
        warn "push with: git push && git push --tags"
        ;;
    -h|--help|"") sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command: $1" ;;
esac

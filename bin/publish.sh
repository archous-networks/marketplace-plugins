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

die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m%s\033[0m\n' "$*"; }

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
        git commit -q -m "Index $1 $(php -r '$d=json_decode(file_get_contents("plugins.json"),true); foreach($d["plugins"] as $p){ if($p["name"]===$argv[1]) echo $p["version"]; }' "$1")" || true
        ok "released $1"
        ;;
    -h|--help|"") sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command: $1" ;;
esac

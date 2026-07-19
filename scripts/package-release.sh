#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/package-release.sh [--output DIRECTORY]
  scripts/package-release.sh --verify ZIP CHECKSUM

The default mode builds a universal, coverage-free, Hardened Runtime ad-hoc
signed app and packages a versioned directory containing the app, LICENSE,
NOTICE.md, and README.md. It writes and verifies a portable SHA-256 file.

--verify validates a previously packaged ZIP and checksum without rebuilding.
Default output directory: build/package.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

temporary_directories=()
temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

make_temporary_directory() {
  local prefix="$1"
  temporary_directory="$(mktemp -d "$temporary_root/${prefix}.XXXXXX")"
  temporary_directories+=("$temporary_directory")
}

cleanup() {
  local directory
  for directory in ${temporary_directories[@]+"${temporary_directories[@]}"}; do
    case "$directory" in
      "$temporary_root"/dockpriority-*.??????)
        [[ -d "$directory" ]] && rm -rf -- "$directory"
        ;;
      *)
        echo "warning: refusing to clean unvalidated temporary path: $directory" >&2
        ;;
    esac
  done
}
trap cleanup EXIT

verify_app() {
  local app_path="$1"
  local expected_version="$2"
  local executable="$app_path/Contents/MacOS/DockPriority"
  local info_plist="$app_path/Contents/Info.plist"
  local bundle_id version build_number architectures signature_details

  [[ -d "$app_path" ]] || fail "missing app bundle: $app_path"
  [[ -f "$executable" ]] || fail "missing app executable: $executable"
  [[ -f "$info_plist" ]] || fail "missing Info.plist: $info_plist"
  [[ -z "$(find "$app_path" -name default.profraw -print -quit)" ]] || \
    fail "release app contains default.profraw"
  [[ -z "$(find "$app_path" -type l -print -quit)" ]] || \
    fail "release app contains a symbolic link"

  if otool -l "$executable" | grep -Eq '__llvm_prf|__llvm_cov'; then
    fail "release executable contains LLVM profiling/coverage sections"
  fi
  if strings -a "$executable" | grep -Eq 'default\.profraw|__llvm_profile'; then
    fail "release executable contains LLVM profiling runtime strings"
  fi

  codesign --verify --deep --strict --verbose=2 "$app_path"
  signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
  grep -Eq '^Signature=adhoc$' <<<"$signature_details" || \
    fail "release app is not ad-hoc signed"
  grep -Eq 'flags=.*[(,]runtime[,)]' <<<"$signature_details" || \
    fail "release app signature does not enable Hardened Runtime"

  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
  build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
  [[ "$bundle_id" == 'io.github.cinestill800t.DockPriority' ]] || \
    fail "unexpected bundle identifier: $bundle_id"
  [[ "$version" == "$expected_version" ]] || \
    fail "app version $version does not match package version $expected_version"
  [[ -n "$build_number" ]] || fail "missing app build number"

  architectures="$(lipo -archs "$executable")"
  for required_architecture in arm64 x86_64; do
    [[ " $architectures " == *" $required_architecture "* ]] || \
      fail "missing $required_architecture architecture: $architectures"
  done

  printf 'Verified DockPriority %s (%s), architectures: %s\n' \
    "$version" "$build_number" "$architectures"
}

verify_archive() {
  local zip_input="$1"
  local checksum_input="$2"
  local zip_directory zip_path zip_name checksum_directory checksum_path checksum_name
  local version expected_root member relative checksum_value checksum_file extra
  local extraction_dir extracted_root item base_name

  [[ -f "$zip_input" ]] || fail "missing ZIP: $zip_input"
  [[ -f "$checksum_input" ]] || fail "missing checksum: $checksum_input"
  zip_directory="$(cd "$(dirname "$zip_input")" && pwd -P)"
  zip_name="$(basename "$zip_input")"
  zip_path="$zip_directory/$zip_name"
  checksum_directory="$(cd "$(dirname "$checksum_input")" && pwd -P)"
  checksum_name="$(basename "$checksum_input")"
  checksum_path="$checksum_directory/$checksum_name"
  [[ "$zip_directory" == "$checksum_directory" ]] || \
    fail "ZIP and checksum must be in the same directory"
  [[ "$checksum_name" == "$zip_name.sha256" ]] || \
    fail "checksum name must be $zip_name.sha256"

  case "$zip_name" in
    DockPriority-*-macos.zip)
      version="${zip_name#DockPriority-}"
      version="${version%-macos.zip}"
      ;;
    *)
      fail "unexpected ZIP name: $zip_name"
      ;;
  esac
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] || \
    fail "invalid package version: $version"
  expected_root="DockPriority-$version"

  [[ "$(wc -l < "$checksum_path" | tr -d ' ')" == 1 ]] || \
    fail "checksum file must contain exactly one line"
  read -r checksum_value checksum_file extra < "$checksum_path"
  [[ "$checksum_value" =~ ^[0-9a-fA-F]{64}$ ]] || fail "invalid SHA-256 value"
  [[ "$checksum_file" == "$zip_name" && -z "${extra:-}" ]] || \
    fail "checksum must reference only the ZIP basename"
  (cd "$zip_directory" && shasum -a 256 -c "$checksum_name")

  make_temporary_directory dockpriority-verify
  extraction_dir="$temporary_directory"
  zipinfo -1 "$zip_path" > "$extraction_dir/members.txt"
  [[ -s "$extraction_dir/members.txt" ]] || fail "ZIP contains no members"
  while IFS= read -r member || [[ -n "$member" ]]; do
    [[ "$member" != /* && "$member" != *\\* ]] || \
      fail "ZIP contains an unsafe member path: $member"
    case "/$member/" in
      *'/../'*|*'/./'*) fail "ZIP contains path traversal: $member" ;;
    esac
    [[ "$member" == "$expected_root" || "$member" == "$expected_root/" || \
       "$member" == "$expected_root/"* ]] || \
      fail "ZIP contains an unexpected root entry: $member"
    relative="${member#"$expected_root"}"
    relative="${relative#/}"
    case "$relative" in
      ''|'DockPriority.app'|'DockPriority.app/'|'DockPriority.app/'*|'LICENSE'|'NOTICE.md'|'README.md') ;;
      *) fail "ZIP contains an unexpected top-level entry: $member" ;;
    esac
  done < "$extraction_dir/members.txt"
  if zipinfo -l "$zip_path" | \
    awk '$1 ~ /^l/ { found = 1 } END { exit(found ? 0 : 1) }'; then
    fail "ZIP contains a symbolic-link entry"
  fi

  mkdir "$extraction_dir/unpacked"
  ditto -x -k "$zip_path" "$extraction_dir/unpacked"
  [[ -z "$(find "$extraction_dir/unpacked" -type l -print -quit)" ]] || \
    fail "extracted release contains a symbolic link"
  extracted_root="$extraction_dir/unpacked/$expected_root"
  [[ -d "$extracted_root" ]] || fail "missing expected package root: $expected_root"
  [[ -s "$extracted_root/LICENSE" ]] || fail "missing LICENSE"
  [[ -s "$extracted_root/NOTICE.md" ]] || fail "missing NOTICE.md"
  [[ -s "$extracted_root/README.md" ]] || fail "missing README.md"

  while IFS= read -r -d '' item; do
    base_name="$(basename "$item")"
    case "$base_name" in
      DockPriority.app|LICENSE|NOTICE.md|README.md) ;;
      *) fail "unexpected extracted top-level entry: $base_name" ;;
    esac
  done < <(find "$extracted_root" -mindepth 1 -maxdepth 1 -print0)

  verify_app "$extracted_root/DockPriority.app" "$version"
  printf 'Verified release archive: %s\n' "$zip_path"
}

mode=package
output_dir="build/package"
verify_zip=''
verify_checksum=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ "$mode" == package && $# -ge 2 ]] || fail "--output requires a directory"
      output_dir="$2"
      shift 2
      ;;
    --verify)
      [[ "$mode" == package && $# -eq 3 ]] || fail "--verify requires ZIP and CHECKSUM"
      mode=verify
      verify_zip="$2"
      verify_checksum="$3"
      shift 3
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

if [[ "$mode" == verify ]]; then
  verify_archive "$verify_zip" "$verify_checksum"
  exit 0
fi

output_dir="$(mkdir -p "$output_dir" && cd "$output_dir" && pwd -P)"
make_temporary_directory dockpriority-package
staging_dir="$temporary_directory"
app_output="$staging_dir/app"

scripts/build-release.sh --output "$app_output"
app_path="$app_output/DockPriority.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
package_name="DockPriority-$version"
package_root="$staging_dir/$package_name"
zip_name="$package_name-macos.zip"
zip_path="$output_dir/$zip_name"
checksum_path="$zip_path.sha256"

[[ ! -e "$zip_path" && ! -e "$checksum_path" ]] || \
  fail "refusing to overwrite existing release output in $output_dir"

mkdir "$package_root"
ditto "$app_path" "$package_root/DockPriority.app"
cp -p LICENSE NOTICE.md README.md "$package_root/"
(
  cd "$staging_dir"
  ditto --norsrc --noextattr -c -k --keepParent "$package_name" "$zip_path"
)
(
  cd "$output_dir"
  shasum -a 256 "$zip_name" > "$zip_name.sha256"
)

[[ -s "$zip_path" && -s "$checksum_path" ]] || \
  fail "packaging did not create both ZIP and checksum"
verify_archive "$zip_path" "$checksum_path"
printf 'Packaged ad-hoc-signed, Hardened Runtime, non-notarized release:\n%s\n%s\n' \
  "$zip_path" "$checksum_path"

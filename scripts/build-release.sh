#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh [--output DIRECTORY]

Builds a coverage-free universal DockPriority.app, then ad-hoc signs it with
Hardened Runtime. The output directory must not already contain
DockPriority.app. Default: build/release.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

verify_app() {
  local app_path="$1"
  local executable="$app_path/Contents/MacOS/DockPriority"
  local info_plist="$app_path/Contents/Info.plist"
  local bundle_id version build_number architectures signature_details

  [[ -d "$app_path" ]] || fail "missing app bundle: $app_path"
  [[ -f "$executable" ]] || fail "missing app executable: $executable"
  [[ -f "$info_plist" ]] || fail "missing Info.plist: $info_plist"
  [[ -z "$(find "$app_path" -name default.profraw -print -quit)" ]] || \
    fail "release app contains default.profraw"

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
  [[ -n "$version" && -n "$build_number" ]] || fail "missing app version metadata"

  architectures="$(lipo -archs "$executable")"
  for required_architecture in arm64 x86_64; do
    [[ " $architectures " == *" $required_architecture "* ]] || \
      fail "missing $required_architecture architecture: $architectures"
  done

  printf 'Verified DockPriority %s (%s), architectures: %s\n' \
    "$version" "$build_number" "$architectures"
}

output_dir="build/release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a directory"
      output_dir="$2"
      shift 2
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
output_dir="$(mkdir -p "$output_dir" && cd "$output_dir" && pwd -P)"
app_path="$output_dir/DockPriority.app"

[[ ! -e "$app_path" ]] || fail "refusing to overwrite existing app: $app_path"

xcodebuild build \
  -project DockPriority.xcodeproj \
  -scheme DockPriority \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$output_dir/DerivedData" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  ENABLE_CODE_COVERAGE=NO \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO \
  GCC_GENERATE_TEST_COVERAGE_FILES=NO \
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
  CONFIGURATION_BUILD_DIR="$output_dir" \
  CODE_SIGNING_ALLOWED=NO

[[ -d "$app_path" ]] || fail "build did not produce $app_path"
codesign --force --sign - --options runtime \
  --entitlements DockPriority/DockPriority.entitlements "$app_path"
verify_app "$app_path"

printf '%s\n' "$app_path"

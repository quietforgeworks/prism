#!/bin/zsh
set -eu
project_dir="${0:A:h}"
build_dir="${PRISM_BUILD_DIR:-$project_dir/.build}"
app_output="${PRISM_APP_OUTPUT:-$project_dir/../Prism.app}"
cd -- "$project_dir"
mkdir -p "$build_dir/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/module-cache"
swift build -c release --disable-sandbox --scratch-path "$build_dir" --cache-path "$build_dir/package-cache" --config-path "$build_dir/package-config"
bin_dir=$(swift build -c release --disable-sandbox --scratch-path "$build_dir" --show-bin-path)
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/prism-build.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
staged_app="$stage_dir/Prism.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$bin_dir/Prism" "$staged_app/Contents/MacOS/Prism"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp Resources/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
chmod +x "$staged_app/Contents/MacOS/Prism"
codesign --force --sign - --identifier local.prism.clipboard "$staged_app"
codesign --verify --strict "$staged_app"
ditto --norsrc --noextattr "$staged_app" "$app_output"
print "已构建：$app_output"

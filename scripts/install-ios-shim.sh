#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SOURCE" ]]; do
  SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  if [[ "$SOURCE" != /* ]]; then
    SOURCE="$SOURCE_DIR/$SOURCE"
  fi
done

ROOT="$(cd -P "$(dirname "$SOURCE")/.." && pwd)"
APP_ROOT=""
SCHEME=""
TEST_TARGET=""
APP_TARGET=""
BUNDLE_ID=""
TEST_BUNDLE_ID=""
DEVICE="booted"
DEVICE_TYPE="simulator"
CONFIGURATION="Debug"
WORKSPACE=""
PROJECT=""
DERIVED_DATA_PATH=""
DEPLOYMENT_TARGET="15.0"
PATCH_XCODEPROJ=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/install-ios-shim.sh --app-root <dir> --scheme <UITestScheme> --bundle-id <id> [options]

Writes an app-local .zmr/ios-shim command and XCTest source file.

Options:
  --app-root <dir>       App repository root. Required.
  --scheme <scheme>      Xcode UI test scheme that includes ZMRShimUITestCase. Required.
  --bundle-id <id>       App bundle id under test. Required.
  --app-target <name>    App target name. Enables generated Xcode target helper.
  --test-target <name>   UI test target name. Default: scheme.
  --test-bundle-id <id>  UI test bundle id. Default: <bundle-id>.zmr-uitests.
  --workspace <path>     Workspace path relative to app root.
  --project <path>       Xcode project path relative to app root.
  --derived-data-path <path>
                          Derived data path relative to app root.
  --device <udid|booted> Simulator or physical-device destination id. Default: booted.
  --device-type <type>   simulator or physical. Default: simulator.
  --configuration <name> Xcode build configuration. Default: Debug.
  --deployment-target <version>
                          iOS deployment target for generated UI test target. Default: 15.0.
  --patch-xcodeproj      Run the generated Xcodeproj helper immediately.
  -h, --help             Show this help.

After running, use .zmr/ensure-ios-shim-target.sh to create/update the UI test
target when --project or --workspace and --app-target are available, then pass
--ios-shim ./.zmr/ios-shim to zmr.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_value() {
  local flag="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "$flag requires a value"
  fi
  printf '%s\n' "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-root)
      APP_ROOT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --scheme)
      SCHEME="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --app-target)
      APP_TARGET="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --test-bundle-id)
      TEST_BUNDLE_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --workspace)
      WORKSPACE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --project)
      PROJECT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --derived-data-path)
      DERIVED_DATA_PATH="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --test-target)
      TEST_TARGET="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --device)
      DEVICE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --device-type)
      DEVICE_TYPE="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --deployment-target)
      DEPLOYMENT_TARGET="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --patch-xcodeproj)
      PATCH_XCODEPROJ=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$APP_ROOT" ]] || die "--app-root is required"
[[ -n "$SCHEME" ]] || die "--scheme is required"
[[ -n "$BUNDLE_ID" ]] || die "--bundle-id is required"
if [[ -n "$WORKSPACE" && -n "$PROJECT" ]]; then
  die "--workspace and --project are mutually exclusive"
fi
if [[ -z "$TEST_TARGET" ]]; then
  TEST_TARGET="$SCHEME"
fi
if [[ -z "$TEST_BUNDLE_ID" ]]; then
  TEST_BUNDLE_ID="$BUNDLE_ID.zmr-uitests"
fi
if [[ "$PATCH_XCODEPROJ" -eq 1 ]]; then
  [[ -n "$PROJECT" || -n "$WORKSPACE" ]] || die "--patch-xcodeproj requires --project or --workspace"
  [[ -n "$APP_TARGET" ]] || die "--patch-xcodeproj requires --app-target"
fi
if [[ "$DEVICE_TYPE" != "simulator" && "$DEVICE_TYPE" != "physical" ]]; then
  die "--device-type must be simulator or physical"
fi
if [[ "$DEVICE_TYPE" == "physical" && "$DEVICE" == "booted" ]]; then
  die "--device-type physical requires --device <physical-device-id>"
fi

mkdir -p "$APP_ROOT"
APP_ROOT="$(cd "$APP_ROOT" && pwd)"
SHIM_INSTALL_FINGERPRINT="$(
  {
    printf '%s\n' \
      "$SCHEME" \
      "$TEST_TARGET" \
      "$TEST_BUNDLE_ID" \
      "$WORKSPACE" \
      "$PROJECT" \
      "$APP_TARGET" \
      "$BUNDLE_ID" \
      "$DERIVED_DATA_PATH" \
      "$DEVICE_TYPE" \
      "$CONFIGURATION" \
      "$DEPLOYMENT_TARGET"
    shasum -a 256 \
      "$ROOT/scripts/install-ios-shim.sh" \
      "$ROOT/scripts/ensure-ios-shim-target.rb" \
      "$ROOT/shims/ios/ZMRShim.swift" \
      "$ROOT/shims/ios/ZMRShimUITestCase.swift"
  } | shasum -a 256 | awk '{print $1}'
)"
mkdir -p "$APP_ROOT/.zmr" "$APP_ROOT/.zmr/shims/ios" "$APP_ROOT/.zmr/ios-shim-state"
rm -f "$APP_ROOT/.zmr/ios-shim-state/destination.id"
rm -f "$APP_ROOT/.zmr/ios-shim-state/xcodebuild.pid"
rm -f "$APP_ROOT/.zmr/ios-shim-state/xcodebuild.log"
rm -rf "$APP_ROOT/.zmr/ios-shim-state/server"
cp "$ROOT/shims/ios/ZMRShim.swift" "$APP_ROOT/.zmr/shims/ios/ZMRShim.swift"
cp "$ROOT/shims/ios/ZMRShimUITestCase.swift" "$APP_ROOT/.zmr/ZMRShimUITestCase.swift"
cp "$ROOT/scripts/ensure-ios-shim-target.rb" "$APP_ROOT/.zmr/ensure-ios-shim-target.rb"

cat > "$APP_ROOT/.zmr/ZMRShimUITests-Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>$(DEVELOPMENT_LANGUAGE)</string>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key>
  <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>ZMR_APP_BUNDLE_ID</key>
  <string>$(ZMR_APP_BUNDLE_ID)</string>
  <key>ZMR_SHIM_REQUEST_FILE</key>
  <string>$(ZMR_SHIM_REQUEST_FILE)</string>
  <key>ZMR_SHIM_RESPONSE_FILE</key>
  <string>$(ZMR_SHIM_RESPONSE_FILE)</string>
  <key>ZMR_SHIM_MODE</key>
  <string>$(ZMR_SHIM_MODE)</string>
  <key>ZMR_SHIM_SERVER_DIR</key>
  <string>$(ZMR_SHIM_SERVER_DIR)</string>
</dict>
</plist>
EOF

cat > "$APP_ROOT/.zmr/ios-shim" <<EOF
#!/usr/bin/env bash
set -euo pipefail

cd "$APP_ROOT"

STATE_DIR="$APP_ROOT/.zmr/ios-shim-state"
SERVER_DIR="\$STATE_DIR/server"
PID_FILE="\$STATE_DIR/xcodebuild.pid"
READY_FILE="\$SERVER_DIR/ready"
DESTINATION_ID_FILE="\$STATE_DIR/destination.id"
BUILD_READY_FILE="\$STATE_DIR/build-for-testing.ready"
BUILD_FINGERPRINT_FILE="\$STATE_DIR/build-for-testing.fingerprint"
DERIVED_DATA_CLEAN_FINGERPRINT_FILE="\$STATE_DIR/derived-data-clean.fingerprint"
LOG_FILE="\$STATE_DIR/xcodebuild.log"
DERIVED_DATA_PATH_VALUE="$DERIVED_DATA_PATH"
INSTALL_FINGERPRINT_VALUE="$SHIM_INSTALL_FINGERPRINT"
ZMR_TEST_TARGET_NAME="$TEST_TARGET"
ZMR_SCHEME_NAME="$SCHEME"
STDIN_FILE="\$(mktemp)"
trap 'rm -f "\$STDIN_FILE"' EXIT

mkdir -p "\$STATE_DIR" "\$SERVER_DIR"

cat > "\$STDIN_FILE"

XCODEBUILD_ARGS=()
if [[ -n "$WORKSPACE" ]]; then
  XCODEBUILD_ARGS+=(-workspace "$WORKSPACE")
elif [[ -n "$PROJECT" ]]; then
  XCODEBUILD_ARGS+=(-project "$PROJECT")
fi
if [[ -n "$DERIVED_DATA_PATH" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi

tail_log() {
  if [[ -f "\$LOG_FILE" ]]; then
    tail -120 "\$LOG_FILE" >&2
  fi
}

tail_log_path() {
  local log_file="\$1"
  if [[ -f "\$log_file" ]]; then
    tail -120 "\$log_file" >&2
  fi
}

run_xcodebuild_with_timeout() {
  local label="\$1"
  local timeout_seconds="\$2"
  local log_file="\$3"
  shift 3

  local pid started_at next_progress progress_seconds elapsed
  progress_seconds="\${ZMR_IOS_SHIM_PROGRESS_SECONDS:-30}"
  "\$@" >"\$log_file" 2>&1 &
  pid="\$!"
  started_at="\$SECONDS"
  next_progress=\$((started_at + progress_seconds))

  while kill -0 "\$pid" 2>/dev/null; do
    elapsed=\$((SECONDS - started_at))
    if (( elapsed >= timeout_seconds )); then
      echo "timed out waiting for \$label after \${timeout_seconds}s" >&2
      kill -TERM "\$pid" 2>/dev/null || true
      sleep 2
      if kill -0 "\$pid" 2>/dev/null; then
        kill -KILL "\$pid" 2>/dev/null || true
      fi
      wait "\$pid" 2>/dev/null || true
      tail_log_path "\$log_file"
      exit 1
    fi
    if (( SECONDS >= next_progress )); then
      echo "still waiting for \$label after \${elapsed}s; log: \$log_file" >&2
      next_progress=\$((SECONDS + progress_seconds))
    fi
    sleep 1
  done

  if ! wait "\$pid"; then
    tail_log_path "\$log_file"
    exit 1
  fi
}

resolve_destination() {
  local destination_id="$DEVICE"
  if [[ "\$destination_id" == "booted" ]]; then
    if [[ "$DEVICE_TYPE" == "physical" ]]; then
      echo "physical iOS shim requires an explicit --device id" >&2
      exit 2
    fi
    if [[ -f "\$DESTINATION_ID_FILE" ]]; then
      destination_id="\$(cat "\$DESTINATION_ID_FILE" 2>/dev/null || true)"
      if [[ -n "\$destination_id" ]] && xcrun simctl list devices available | grep -F "\$destination_id" >/dev/null 2>&1; then
        # Reuse the first resolved booted simulator so build-for-testing and
        # test-without-building target the same simulator even if it shuts down
        # while Xcode is compiling the shim target.
        printf '%s' "\$destination_id"
        return 0
      fi
    fi
    destination_id="\$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-Fa-f-][0-9A-Fa-f-]*\)) (Booted).*/\1/p' | head -n 1)"
    if [[ -n "\$destination_id" ]]; then
      printf '%s' "\$destination_id" > "\$DESTINATION_ID_FILE"
    fi
  fi
  if [[ -z "\$destination_id" ]]; then
    echo "no booted iOS simulator found" >&2
    exit 2
  fi
  printf '%s' "\$destination_id"
}

destination_spec() {
  local destination_id platform_name
  destination_id="\$(resolve_destination)"
  if [[ "$DEVICE_TYPE" == "physical" ]]; then
    platform_name="iOS"
  else
    platform_name="iOS Simulator"
  fi
  printf 'platform=%s,id=%s' "\$platform_name" "\$destination_id"
}

clean_zmr_derived_data() {
  if [[ -z "\$DERIVED_DATA_PATH_VALUE" ]]; then
    return 0
  fi
  if [[ "\${ZMR_IOS_SHIM_FORCE_REBUILD:-}" != "1" && -f "\$DERIVED_DATA_CLEAN_FINGERPRINT_FILE" ]] && [[ "\$(cat "\$DERIVED_DATA_CLEAN_FINGERPRINT_FILE" 2>/dev/null || true)" == "\$INSTALL_FINGERPRINT_VALUE" ]]; then
    return 0
  fi

  local derived_data_abs
  if [[ "\$DERIVED_DATA_PATH_VALUE" == /* ]]; then
    derived_data_abs="\$DERIVED_DATA_PATH_VALUE"
  else
    derived_data_abs="$APP_ROOT/\$DERIVED_DATA_PATH_VALUE"
  fi
  while [[ "\$derived_data_abs" == */ && "\$derived_data_abs" != "/" ]]; do
    derived_data_abs="\${derived_data_abs%/}"
  done

  case "\$derived_data_abs" in
    "$APP_ROOT/ZMRDerivedData"|"$APP_ROOT"/*/ZMRDerivedData)
      if [[ -d "\$derived_data_abs/Build/Products" ]]; then
        find "\$derived_data_abs/Build/Products" -depth \\( -name "\$ZMR_TEST_TARGET_NAME*" -o -name "\$ZMR_SCHEME_NAME*" \\) -exec rm -rf {} +
      fi
      if [[ -d "\$derived_data_abs/Build/Intermediates.noindex" ]]; then
        find "\$derived_data_abs/Build/Intermediates.noindex" -depth \\( -name "\$ZMR_TEST_TARGET_NAME.build" -o -name "\$ZMR_SCHEME_NAME.build" \\) -exec rm -rf {} +
      fi
      printf '%s\\n' "\$INSTALL_FINGERPRINT_VALUE" > "\$DERIVED_DATA_CLEAN_FINGERPRINT_FILE"
      ;;
    *)
      echo "warning: refusing to delete non-ZMR derived data path: \$DERIVED_DATA_PATH_VALUE" >&2
      ;;
  esac
}

# Liveness only. Authoritative for "did our server die?".
server_pid_alive() {
  if [[ ! -f "\$PID_FILE" ]]; then
    return 1
  fi
  local pid
  pid="\$(cat "\$PID_FILE" 2>/dev/null || true)"
  [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null
}

# Liveness AND identity. Used to decide whether a PID file left by an earlier
# run still names our server, so a recycled PID is not mistaken for one.
#
# Do NOT use this to detect exit while waiting: start_server records \$! the
# instant nohup forks, and the child may not have exec'd its real argv yet, so
# a healthy server can briefly fail the identity match. Treating that as "the
# server exited" turned a startup window into a hard failure.
is_server_running() {
  server_pid_alive || return 1
  local pid command
  pid="\$(cat "\$PID_FILE" 2>/dev/null || true)"
  command="\$(ps -p "\$pid" -o command= 2>/dev/null || true)"
  [[ "\$command" == *xcodebuild* && "\$command" == *"$TEST_TARGET"* ]]
}

run_oneshot() {
  local request_file response_file oneshot_log destination_id
  request_file="\$(mktemp "\$STATE_DIR/request.XXXXXX")"
  response_file="\$(mktemp "\$STATE_DIR/response.XXXXXX")"
  oneshot_log="\$(mktemp "\$STATE_DIR/xcodebuild.oneshot.log.XXXXXX")"
  cp "\$STDIN_FILE" "\$request_file"
  destination_id="\$(destination_spec)"

  if ! xcodebuild test \\
    "\${XCODEBUILD_ARGS[@]}" \\
    -scheme "$SCHEME" \\
    -configuration "$CONFIGURATION" \\
    -destination "\$destination_id" \\
    -only-testing:"$TEST_TARGET/ZMRShimUITestCase/testRunZMRCommand" \\
    ZMR_SHIM_MODE="oneshot" \\
    ZMR_SHIM_REQUEST_FILE="\$request_file" \\
    ZMR_SHIM_RESPONSE_FILE="\$response_file" \\
    ZMR_APP_BUNDLE_ID="$BUNDLE_ID" \\
    >"\$oneshot_log" 2>&1; then
    tail -120 "\$oneshot_log" >&2
    exit 1
  fi

  cat "\$response_file"
  printf '\\n'
}

wait_for_ready() {
  local deadline
  deadline=\$((SECONDS + \${ZMR_IOS_SHIM_START_TIMEOUT_SECONDS:-180}))
  while (( SECONDS < deadline )); do
    if [[ -f "\$READY_FILE" ]]; then
      return 0
    fi
    if ! server_pid_alive; then
      echo "iOS shim server exited before it became ready" >&2
      tail_log
      exit 1
    fi
    sleep 0.2
  done
  echo "timed out waiting for iOS shim server readiness" >&2
  tail_log
  exit 1
}

build_for_testing() {
  if [[ "\${ZMR_IOS_SHIM_FORCE_REBUILD:-}" != "1" && -f "\$BUILD_READY_FILE" && -f "\$BUILD_FINGERPRINT_FILE" ]] && [[ "\$(cat "\$BUILD_FINGERPRINT_FILE" 2>/dev/null || true)" == "\$INSTALL_FINGERPRINT_VALUE" ]]; then
    return 0
  fi

  local destination_id build_log
  destination_id="\$(destination_spec)"
  build_log="\$STATE_DIR/xcodebuild.build.log"
  clean_zmr_derived_data

  run_xcodebuild_with_timeout "iOS shim build-for-testing" "\${ZMR_IOS_SHIM_BUILD_TIMEOUT_SECONDS:-5400}" "\$build_log" \\
    xcodebuild build-for-testing \\
      "\${XCODEBUILD_ARGS[@]}" \\
      -scheme "$SCHEME" \\
      -configuration "$CONFIGURATION" \\
      -destination "\$destination_id" \\
      ZMR_SHIM_MODE="server" \\
      ZMR_SHIM_SERVER_DIR="\$SERVER_DIR" \\
      ZMR_APP_BUNDLE_ID="$BUNDLE_ID"

  printf '%s\\n' "\$INSTALL_FINGERPRINT_VALUE" > "\$BUILD_FINGERPRINT_FILE"
  touch "\$BUILD_READY_FILE"
}

start_server() {
  if is_server_running; then
    wait_for_ready
    return 0
  fi

  rm -f "\$READY_FILE" "\$SERVER_DIR"/request-*.json "\$SERVER_DIR"/response-*.json "\$SERVER_DIR/stop"
  : > "\$LOG_FILE"
  build_for_testing

  local destination_id
  destination_id="\$(destination_spec)"
  nohup xcodebuild test-without-building \\
    "\${XCODEBUILD_ARGS[@]}" \\
    -scheme "$SCHEME" \\
    -configuration "$CONFIGURATION" \\
    -destination "\$destination_id" \\
    -only-testing:"$TEST_TARGET/ZMRShimUITestCase/testRunZMRCommand" \\
    ZMR_SHIM_MODE="server" \\
    ZMR_SHIM_SERVER_DIR="\$SERVER_DIR" \\
    ZMR_APP_BUNDLE_ID="$BUNDLE_ID" \\
    >"\$LOG_FILE" 2>&1 < /dev/null &

  echo "\$!" > "\$PID_FILE"
  wait_for_ready
}

send_request() {
  start_server

  local REQUEST_ID request_file response_file tmp_request deadline
  REQUEST_ID="\$(date +%s%N)-\$\$"
  request_file="\$SERVER_DIR/request-\$REQUEST_ID.json"
  response_file="\$SERVER_DIR/response-\$REQUEST_ID.json"
  tmp_request="\$request_file.tmp"
  cp "\$STDIN_FILE" "\$tmp_request"
  mv "\$tmp_request" "\$request_file"

  deadline=\$((SECONDS + \${ZMR_IOS_SHIM_RESPONSE_TIMEOUT_SECONDS:-180}))
  while (( SECONDS < deadline )); do
    if [[ -f "\$response_file" ]]; then
      cat "\$response_file"
      printf '\\n'
      rm -f "\$request_file" "\$response_file"
      return 0
    fi
    if ! server_pid_alive; then
      echo "iOS shim server exited while waiting for response \$REQUEST_ID" >&2
      tail_log
      exit 1
    fi
    sleep 0.05
  done

  echo "timed out waiting for iOS shim response \$REQUEST_ID" >&2
  tail_log
  exit 1
}

if [[ "\${ZMR_IOS_SHIM_ONESHOT:-}" == "1" ]]; then
  run_oneshot
else
  send_request
fi
EOF

chmod +x "$APP_ROOT/.zmr/ios-shim"

shell_quote() {
  printf '%q' "$1"
}

patch_zmr_config() {
  local config_file="$APP_ROOT/.zmr/config.json"
  ruby -rjson -e '
    path = ARGV.fetch(0)
    app_id = ARGV.fetch(1)
    config = if File.exist?(path)
      JSON.parse(File.read(path))
    else
      { "schemaVersion" => 1, "appId" => app_id }
    end
    abort "error: .zmr/config.json must be a JSON object" unless config.is_a?(Hash)
    config["schemaVersion"] ||= 1
    config["appId"] ||= app_id unless app_id.empty?
    tools = config["tools"]
    abort "error: .zmr/config.json tools must be a JSON object" if tools && !tools.is_a?(Hash)
    tools ||= {}
    tools["iosShimPath"] = "./.zmr/ios-shim"
    config["tools"] = tools
    File.write(path, "#{JSON.pretty_generate(config)}\n")
  ' "$config_file" "$BUNDLE_ID"
}

patch_zmr_config

cat > "$APP_ROOT/.zmr/ensure-ios-shim-target.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_ROOT=$(shell_quote "$APP_ROOT")
PROJECT=$(shell_quote "$PROJECT")
WORKSPACE=$(shell_quote "$WORKSPACE")
APP_TARGET=$(shell_quote "$APP_TARGET")
TEST_TARGET=$(shell_quote "$TEST_TARGET")
SCHEME=$(shell_quote "$SCHEME")
BUNDLE_ID=$(shell_quote "$BUNDLE_ID")
TEST_BUNDLE_ID=$(shell_quote "$TEST_BUNDLE_ID")
DEPLOYMENT_TARGET=$(shell_quote "$DEPLOYMENT_TARGET")

cd "\$APP_ROOT"

if [[ -z "\$APP_TARGET" ]]; then
  echo "error: rerun install-ios-shim.sh with --app-target to enable Xcode target patching" >&2
  exit 2
fi

if [[ -z "\$PROJECT" ]]; then
  if [[ -z "\$WORKSPACE" ]]; then
    echo "error: rerun install-ios-shim.sh with --project or --workspace to enable Xcode target patching" >&2
    exit 2
  fi
  PROJECT="\$(ruby -rrexml/document -rpathname -e '
    app_root = Pathname.new(ARGV[0]).expand_path
    workspace = app_root.join(ARGV[1]).expand_path
    app_target = ARGV[2].to_s
    bundle_id = ARGV[3].to_s
    data = workspace.join("contents.xcworkspacedata")
    abort "error: workspace metadata not found at #{data}" unless data.file?
    doc = REXML::Document.new(data.read)
    projects = []
    doc.elements.each("//FileRef") do |element|
      location = element.attributes["location"].to_s
      next unless location.end_with?(".xcodeproj")
      project_path = location.sub(/\A(?:group|container|self):/, "")
      project = Pathname.new(project_path)
      project = workspace.dirname.join(project).expand_path unless project.absolute?
      projects << project
    end
    projects.uniq!
    abort "error: workspace #{ARGV[1]} does not reference an .xcodeproj; rerun with --project" if projects.empty?
    if projects.length > 1
      begin
        require "xcodeproj"
      rescue LoadError
        abort "error: workspace #{ARGV[1]} references multiple .xcodeproj files; install the xcodeproj gem or rerun with --project"
      end
      projects = projects.select do |project_path|
        begin
          Xcodeproj::Project.open(project_path.to_s).targets.any? { |target| target.name == app_target }
        rescue StandardError
          false
        end
      end
      abort "error: workspace #{ARGV[1]} references multiple .xcodeproj files, and none contain target #{app_target}; rerun with --project" if projects.empty?
      if projects.length > 1 && !bundle_id.empty?
        bundle_matches = projects.select do |project_path|
          begin
            Xcodeproj::Project.open(project_path.to_s).targets.any? do |target|
              target.name == app_target &&
                target.build_configurations.any? do |configuration|
                  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"].to_s == bundle_id
                end
            end
          rescue StandardError
            false
          end
        end
        projects = bundle_matches unless bundle_matches.empty?
      end
      abort "error: workspace #{ARGV[1]} references multiple .xcodeproj files containing target #{app_target}; bundle id #{bundle_id} did not disambiguate; rerun with --project" if projects.length > 1
    end
    puts projects.first.relative_path_from(app_root).to_s
  ' "\$APP_ROOT" "\$WORKSPACE" "\$APP_TARGET" "\$BUNDLE_ID")"
fi

ruby "\$APP_ROOT/.zmr/ensure-ios-shim-target.rb" \\
  --project "\$PROJECT" \\
  --app-target "\$APP_TARGET" \\
  --test-target "\$TEST_TARGET" \\
  --scheme "\$SCHEME" \\
  --bundle-id "\$BUNDLE_ID" \\
  --test-bundle-id "\$TEST_BUNDLE_ID" \\
  --deployment-target "\$DEPLOYMENT_TARGET" \\
  --source ".zmr/ZMRShimUITestCase.swift" \\
  --source ".zmr/shims/ios/ZMRShim.swift" \\
  --info-plist ".zmr/ZMRShimUITests-Info.plist"
EOF

chmod +x "$APP_ROOT/.zmr/ensure-ios-shim-target.sh"

if [[ "$PATCH_XCODEPROJ" -eq 1 ]]; then
  "$APP_ROOT/.zmr/ensure-ios-shim-target.sh"
fi

cat > "$APP_ROOT/.zmr/ios-shim.README.md" <<EOF
# ZMR iOS Shim

Generated for scheme \`$SCHEME\`, UI test target \`$TEST_TARGET\`, and bundle id \`$BUNDLE_ID\`.

When the app has an Xcode project or workspace, run:

\`\`\`bash
.zmr/ensure-ios-shim-target.sh
\`\`\`

The helper uses the Ruby \`xcodeproj\` gem to create/update the UI test target,
add the shim sources, set the test bundle Info.plist, and write a shared scheme.
For workspaces, it resolves the project automatically when there is one project,
or when exactly one project contains \`--app-target\`, or when \`--bundle-id\`
disambiguates matching app targets. Rerun the installer with \`--project\` for
still-ambiguous workspaces. Install the gem with
\`gem install xcodeproj\` or your app's Bundler setup.

If you do not want ZMR to patch the Xcode project, add these files to the app's
UI test target manually:

- \`.zmr/ZMRShimUITestCase.swift\`
- \`.zmr/shims/ios/ZMRShim.swift\`
- \`.zmr/ZMRShimUITests-Info.plist\`

Run ZMR with:

\`\`\`bash
zmr run .zmr/ios-smoke.json --platform ios --ios-shim ./.zmr/ios-shim
\`\`\`

The command caches \`build-for-testing\` output under \`.zmr/ios-shim-state/\`
and uses \`test-without-building\` for selector commands. Set
\`ZMR_IOS_SHIM_FORCE_REBUILD=1\` after app-side target changes, or
\`ZMR_IOS_SHIM_ONESHOT=1\` to force a cold XCTest run for debugging Xcode target
wiring.
EOF

echo "wrote $APP_ROOT/.zmr/ios-shim"
echo "wrote $APP_ROOT/.zmr/ZMRShimUITestCase.swift"
echo "wrote $APP_ROOT/.zmr/shims/ios/ZMRShim.swift"
echo "wrote $APP_ROOT/.zmr/ZMRShimUITests-Info.plist"
echo "wrote $APP_ROOT/.zmr/ensure-ios-shim-target.sh"

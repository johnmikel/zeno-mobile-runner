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
OUT=""
APP_NAME="ZMRDemo"
BUNDLE_ID="com.example.mobiletest"
DEPLOYMENT_TARGET="16.0"

usage() {
  cat <<'USAGE'
Usage:
  scripts/create-ios-demo-app.sh --out <dir> [options]

Creates a small public SwiftUI iOS simulator demo app and installs the ZMR
XCTest shim into it. The generated app is intentionally generic and contains no
private app references.

Options:
  --out <dir>                  Output app repository directory. Required.
  --name <name>                App target name. Default: ZMRDemo.
  --bundle-id <id>             App bundle id. Default: com.example.mobiletest.
  --deployment-target <ver>    iOS deployment target. Default: 16.0.
  -h, --help                   Show this help.

After generation:
  cd <dir>
  xcodebuild -project ios/ZMRDemo.xcodeproj -scheme ZMRDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build
  xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/ZMRDemo.app
  zmr run .zmr/ios-shim-smoke.json --platform ios --device booted --app-id com.example.mobiletest --ios-shim ./.zmr/ios-shim --trace-dir traces/zmr-ios-demo
  zmr run .zmr/ios-shim-workflow.json --platform ios --device booted --app-id com.example.mobiletest --ios-shim ./.zmr/ios-shim --trace-dir traces/zmr-ios-workflow
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
    --out)
      OUT="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --name)
      APP_NAME="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="$(require_value "$1" "${2-}")"
      shift 2
      ;;
    --deployment-target)
      DEPLOYMENT_TARGET="$(require_value "$1" "${2-}")"
      shift 2
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

[[ -n "$OUT" ]] || die "--out is required"
[[ "$APP_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--name must be a valid Swift identifier"
if ! ruby -e 'require "xcodeproj"' >/dev/null 2>&1; then
  die "Ruby gem xcodeproj is required. Install it with: gem install xcodeproj"
fi

mkdir -p "$OUT/ios/$APP_NAME"
OUT="$(cd "$OUT" && pwd)"
PROJECT_PATH="$OUT/ios/$APP_NAME.xcodeproj"
SOURCE_DIR="$OUT/ios/$APP_NAME"
TEST_SCHEME="${APP_NAME}ZMRUITests"

cat > "$SOURCE_DIR/${APP_NAME}App.swift" <<EOF
import SwiftUI

@main
struct ${APP_NAME}App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
EOF

cat > "$SOURCE_DIR/ContentView.swift" <<'EOF'
import SwiftUI

private enum DemoScreen {
    case welcome
    case profile
    case catalog
    case detail
    case review
}

private struct CatalogItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
}

struct ContentView: View {
    @State private var input = ""
    @State private var status = "Ready"
    @State private var screen: DemoScreen = .welcome
    @State private var profileName = ""
    @State private var profileEmail = ""
    @State private var selectedItem = CatalogItem(id: "north_ridge_pack", title: "North Ridge Pack", subtitle: "Weatherproof day pack")
    @FocusState private var inputFocused: Bool

    private let catalogItems = [
        CatalogItem(id: "trail_lamp", title: "Trail Lamp", subtitle: "Compact campsite light"),
        CatalogItem(id: "river_bottle", title: "River Bottle", subtitle: "Insulated hydration bottle"),
        CatalogItem(id: "north_ridge_pack", title: "North Ridge Pack", subtitle: "Weatherproof day pack"),
        CatalogItem(id: "summit_shell", title: "Summit Shell", subtitle: "Lightweight rain layer"),
        CatalogItem(id: "basecamp_roll", title: "Basecamp Roll", subtitle: "Modular storage roll"),
        CatalogItem(id: "maple_organizer", title: "Maple Organizer", subtitle: "Cable and tool pouch"),
        CatalogItem(id: "canyon_sling", title: "Canyon Sling", subtitle: "Cross-body field bag"),
        CatalogItem(id: "harbor_tote", title: "Harbor Tote", subtitle: "Daily carry tote"),
        CatalogItem(id: "studio_stand", title: "Studio Stand", subtitle: "Fold-flat work stand")
    ]

    var body: some View {
        VStack(spacing: 16) {
            switch screen {
            case .welcome:
                welcomeView
            case .profile:
                profileView
            case .catalog:
                catalogView
            case .detail:
                detailView
            case .review:
                reviewView
            }

            VStack(spacing: 4) {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("demo_status")

                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workflow_status")
            }
        }
        .padding()
        .onOpenURL { _ in
            status = "Deep link opened"
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 20) {
            Text("ZMR iOS Demo")
                .font(.title)
                .accessibilityIdentifier("demo_title")

            Button("Continue") {
                status = "Continue tapped"
                screen = .profile
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("continue_button")
        }
    }

    private var profileView: some View {
        VStack(spacing: 14) {
            Text("Profile")
                .font(.title2)
                .accessibilityIdentifier("profile_title")

            TextField("Type here", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .accessibilityIdentifier("demo_input")

            TextField("Name", text: $profileName)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("profile_name_input")

            TextField("Email", text: $profileEmail)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("profile_email_input")

            Button("Save profile") {
                status = "Profile saved"
                screen = .catalog
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("save_profile_button")
        }
    }

    private var catalogView: some View {
        VStack(spacing: 14) {
            Text("Catalog")
                .font(.title2)
                .accessibilityIdentifier("catalog_title")

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(catalogItems) { item in
                        Button {
                            selectedItem = item
                            status = "Selected \(item.title)"
                            screen = .detail
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(catalogAccessibilityIdentifier(for: item))
                    }
                }
            }
            .frame(maxHeight: 340)
            .accessibilityIdentifier("catalog_list")
        }
    }

    private var detailView: some View {
        VStack(spacing: 16) {
            Text(selectedItem.title)
                .font(.title2)
                .accessibilityIdentifier("detail_title")

            Text(selectedItem.subtitle)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("detail_subtitle")

            Button("Save item") {
                status = "Saved \(selectedItem.title)"
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("detail_save_button")

            Button("Review order") {
                status = "Workflow complete"
                screen = .review
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("review_button")
        }
    }

    private var reviewView: some View {
        VStack(spacing: 16) {
            Text("Review")
                .font(.title2)
                .accessibilityIdentifier("review_title")

            Text("Workflow complete")
                .font(.headline)
                .accessibilityIdentifier("review_complete")

            Text(selectedItem.title)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("review_item")
        }
    }

    private func catalogAccessibilityIdentifier(for item: CatalogItem) -> String {
        if item.id == "north_ridge_pack" {
            return "catalog_item_north_ridge_pack"
        }
        return "catalog_item_\(item.id)"
    }
}
EOF

cat > "$SOURCE_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>\$(DEVELOPMENT_LANGUAGE)</string>
  <key>CFBundleExecutable</key>
  <string>\$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>\$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>${BUNDLE_ID}</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>exampleapp</string>
      </array>
    </dict>
  </array>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>UILaunchScreen</key>
  <dict/>
</dict>
</plist>
EOF

ruby - "$PROJECT_PATH" "$APP_NAME" "$BUNDLE_ID" "$DEPLOYMENT_TARGET" <<'RUBY'
require "fileutils"
require "xcodeproj"

project_path, app_name, bundle_id, deployment_target = ARGV
project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, app_name, :ios, deployment_target)
group = project.main_group.new_group(app_name, app_name)

["#{app_name}App.swift", "ContentView.swift"].each do |source|
  file_ref = group.new_file(source)
  target.add_file_references([file_ref])
end
group.new_file("Info.plist")

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SWIFT_VERSION"] = "5.0"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "#{app_name}/Info.plist"
  settings["TARGETED_DEVICE_FAMILY"] = "1,2"
  settings["CODE_SIGNING_ALLOWED"] = "NO"
end

project.save
scheme_dir = File.join(project.path, "xcshareddata/xcschemes")
FileUtils.mkdir_p(scheme_dir)
scheme_path = File.join(scheme_dir, "#{app_name}.xcscheme")
File.write(scheme_path, <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <Scheme LastUpgradeVersion = "1600" version = "1.7">
    <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
        <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
          <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{target.uuid}" BuildableName = "#{app_name}.app" BlueprintName = "#{app_name}" ReferencedContainer = "container:#{File.basename(project.path)}">
          </BuildableReference>
        </BuildActionEntry>
      </BuildActionEntries>
    </BuildAction>
    <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
        <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{target.uuid}" BuildableName = "#{app_name}.app" BlueprintName = "#{app_name}" ReferencedContainer = "container:#{File.basename(project.path)}">
        </BuildableReference>
      </BuildableProductRunnable>
    </LaunchAction>
    <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
        <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "#{target.uuid}" BuildableName = "#{app_name}.app" BlueprintName = "#{app_name}" ReferencedContainer = "container:#{File.basename(project.path)}">
        </BuildableReference>
      </BuildableProductRunnable>
    </ProfileAction>
  </Scheme>
XML
RUBY

"$ROOT/scripts/install-ios-shim.sh" \
  --app-root "$OUT" \
  --scheme "$TEST_SCHEME" \
  --test-target "$TEST_SCHEME" \
  --project "ios/$APP_NAME.xcodeproj" \
  --app-target "$APP_NAME" \
  --bundle-id "$BUNDLE_ID" \
  --test-bundle-id "$BUNDLE_ID.zmr-uitests" \
  --deployment-target "$DEPLOYMENT_TARGET" \
  --patch-xcodeproj

cp "$ROOT/examples/ios-smoke.json" "$OUT/.zmr/ios-smoke.json"
cp "$ROOT/examples/ios-shim-smoke.json" "$OUT/.zmr/ios-shim-smoke.json"
cp "$ROOT/examples/ios-shim-workflow.json" "$OUT/.zmr/ios-shim-workflow.json"

echo "created iOS demo app at $OUT"
echo "project: $PROJECT_PATH"
echo "app scheme: $APP_NAME"
echo "shim scheme: $TEST_SCHEME"
echo "bundle id: $BUNDLE_ID"

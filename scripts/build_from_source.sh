#!/usr/bin/env bash
set -euo pipefail

# Moonshine — Build from Source
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ybmeng/moonshine/main/scripts/build_from_source.sh | bash
# Or from within the repo:
#   ./scripts/build_from_source.sh

REPO_URL="https://github.com/ybmeng/moonshine.git"
SCHEME="Whisky"
CONFIGURATION="Release"

echo "==> Moonshine — Build from Source"
echo ""

# --- Step 1: Homebrew ---
if ! command -v brew &>/dev/null; then
    echo "==> Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
else
    echo "==> Homebrew already installed"
fi

# --- Step 2: SwiftLint ---
if ! command -v swiftlint &>/dev/null; then
    echo "==> Installing swiftlint..."
    brew install swiftlint
else
    echo "==> swiftlint already installed"
fi

# --- Step 3: Clone repo (if needed) ---
# Check if we're already inside the moonshine repo
if [ -f "Whisky.xcodeproj/project.pbxproj" ]; then
    PROJECT_DIR="$(pwd)"
    echo "==> Already in moonshine repo: $PROJECT_DIR"
else
    PROJECT_DIR="$HOME/moonshine"
    if [ -d "$PROJECT_DIR/.git" ]; then
        echo "==> Repo already cloned at $PROJECT_DIR, pulling latest..."
        git -C "$PROJECT_DIR" pull
    else
        echo "==> Cloning moonshine..."
        git clone "$REPO_URL" "$PROJECT_DIR"
    fi
    cd "$PROJECT_DIR"
fi

# --- Step 4: Build ---
BUILD_DIR="/tmp/moonshine-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building $SCHEME ($CONFIGURATION)..."
xcodebuild \
    -project "$PROJECT_DIR/Whisky.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "Whisky.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "Error: Whisky.app not found after build"
    exit 1
fi

echo "==> Build succeeded: $APP_PATH"

# --- Step 5: Install to /Applications ---
INSTALL_PATH="/Applications/Whisky.app"
if [ -d "$INSTALL_PATH" ]; then
    echo "==> Removing previous installation..."
    rm -rf "$INSTALL_PATH"
fi

echo "==> Installing to /Applications..."
cp -R "$APP_PATH" "$INSTALL_PATH"

# --- Step 6: Clean up build artifacts ---
rm -rf "$BUILD_DIR"

# --- Step 7: Launch ---
echo "==> Launching Whisky.app..."
open "$INSTALL_PATH"

echo ""
echo "==> Done! Whisky.app is installed and running."
echo "    The setup wizard will download Wine Staging 11.2 and apply the OpenGL patch."

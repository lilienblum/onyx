#!/bin/sh
set -e

# Onyx installer
# curl -fsSL https://raw.githubusercontent.com/lilienblum/onyx/master/install.sh | sh

REPO="lilienblum/onyx"
BIN_DIR="$HOME/.local/bin"

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
  linux) ;;
  darwin) OS="macos" ;;
  *) echo "error: unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *) echo "error: unsupported architecture: $ARCH"; exit 1 ;;
esac

if [ "$OS" = "macos" ]; then
  NAME="onyx-aarch64-macos"
else
  NAME="onyx-${ARCH}-linux"
fi

# Get latest release URL
URL="https://github.com/$REPO/releases/latest/download/${NAME}.tar.gz"

echo "installing onyx..."
echo "  $URL"

# Download and extract
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

curl -fsSL "$URL" -o "$TMP/onyx.tar.gz"
tar xzf "$TMP/onyx.tar.gz" -C "$TMP"

# Install
mkdir -p "$BIN_DIR"
mv "$TMP/$NAME" "$BIN_DIR/onyx"
chmod +x "$BIN_DIR/onyx"

echo "installed to $BIN_DIR/onyx"

# Check PATH
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "add ~/.local/bin to your PATH:"
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
      fish) echo "  fish_add_path ~/.local/bin" ;;
      zsh)  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
      *)    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
    esac
    echo ""
    ;;
esac

echo "run 'onyx init' to complete setup"

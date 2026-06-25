#!/bin/bash

# Exit immediately if any command fails
set -e

echo "=== FLUTTER BUILD ON VERCEL ==="

# 1. Clone Flutter stable branch with depth=1 (fast clone)
if [ ! -d "flutter" ]; then
  echo "Cloning Flutter SDK (stable branch)..."
  git clone https://github.com/flutter/flutter.git -b stable --depth 1
else
  echo "Flutter SDK directory found."
fi

# 2. Add Flutter to the path
echo "Adding Flutter to PATH..."
export PATH="$PATH:$(pwd)/flutter/bin"

# 3. Enable web support
echo "Configuring Flutter for Web..."
flutter config --enable-web

# 4. Check Flutter tool version
echo "Flutter version status:"
flutter --version

# 5. Run the web build
echo "Compiling Flutter Web App (Release)..."
flutter build web --release

echo "=== FLUTTER WEB BUILD COMPLETED SUCCESSFULLY ==="

#!/bin/zsh
# Build the Android clone with the user-space toolchain (no Android Studio).
# Usage: ./build.sh [gradle tasks...]   (default: :app:assembleRelease)
set -e
export JAVA_HOME=~/dev/jdk/Contents/Home
export ANDROID_HOME=~/Library/Android/sdk
cd "$(dirname "$0")"
[ -f local.properties ] || echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
exec ~/dev/gradle/bin/gradle "${@:-:app:assembleRelease}"

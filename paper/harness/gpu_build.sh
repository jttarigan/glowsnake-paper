#!/bin/zsh
# Builds and runs the offscreen GPU harness (macOS, windowless).
# Reuses the pure-layer extraction from build.sh and additionally extracts
# the app's runtime shader string (shaderSource) so the harness compiles the
# EXACT pipeline the app ships — `private` is stripped because the string
# lands in a different file here.
set -e
cd "$(dirname "$0")"
mkdir -p .build ../data

{
  echo "import Foundation"
  echo "import simd"
  awk '/MARK: - Visual effects switchboard/{p=1}
       /MARK: - Glyph atlas/{p=0}
       /MARK: - Scene builder/{p=1}
       /MARK: - Metal renderer/{p=0}
       p' ../../main.swift
} > .build/model_scene.swift

awk '/^private let shaderSource = """$/{p=1}
     p{print}
     p && /^"""$/ && !/shaderSource/{exit}' ../../main.swift \
  | sed 's/^private //' > .build/shader.swift

grep -q 'let shaderSource' .build/shader.swift || {
  echo "shader extraction failed"; exit 1
}

swiftc -O .build/model_scene.swift .build/shader.swift \
       GlyphAtlasStub.swift GPUMain.swift -o .build/gpu_harness

.build/gpu_harness ../data "$@"

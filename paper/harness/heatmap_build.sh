#!/bin/zsh
# Builds and runs the Table-1 swatch generator: renders each shape kind in
# isolation through the app's extracted shader and writes PNG chips to
# ../figures. Same pure-layer + shader extraction as gpu_build.sh.
set -e
cd "$(dirname "$0")"
mkdir -p .build ../figures

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
       GlyphAtlasStub.swift HeatmapMain.swift -o .build/heatmap_harness

.build/heatmap_harness ../figures

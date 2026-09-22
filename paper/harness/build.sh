#!/bin/zsh
# Builds and runs the headless data-collection harness.
#
# Extracts the app's pure layers (model + draw-list + color helpers, and
# Layout + SceneBuilder) verbatim from ../../main.swift using the MARK
# section boundaries, so the app file needs no changes and can't drift from
# what we measure. GlyphAtlas (the one UIKit-dependent type SceneBuilder
# touches) is replaced by the count-faithful stub in GlyphAtlasStub.swift.
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

swiftc -O .build/model_scene.swift GlyphAtlasStub.swift main.swift \
       -o .build/harness

.build/harness ../data/headless_counts.csv

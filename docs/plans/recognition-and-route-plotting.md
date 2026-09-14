# Recognition & Route Plotting

Status: first pass built. Recognition, board graph, revenue, token detection,
correction UI, and route search are all in place and covered by tests. Revenue comes
from recognized tile data, with text recognition on the photo as the fallback. Train
rules and a full tile set are still to come (see Deferred).

## Context

The app photographs an 18xx board, works out what's on it, and finds the best-paying
route for a company. Before this pass it could only take a photo, draw an adjustable
hex grid over it, and compare each hex against template images that didn't exist -- so
nothing was ever recognized, and there was no model of what a tile's track actually
connects to, no revenue reading, and no route search.

This pass builds the two halves the calculator needs: reading the board, and plotting
routes across it. Per-train and per-company route legality rules are deliberately left
for later; route length is a plain "maximum stops" number for now.

## Where the tile data comes from

[tobymao/18xx](https://github.com/tobymao/18xx) (the engine behind 18xx.games, MIT
licensed) describes every tile as a compact string, documented in its `TILES.md` and
listed in `lib/engine/config/tile.rb`:

- `'9' => 'path=a:0,b:3'` -- plain track between hex edges 0 and 3
- `'5' => 'city=revenue:20;path=a:0,b:_0;path=a:1,b:_0'` -- a city reached from edges 0 and 1
- `'58' => 'town=revenue:10;path=a:0,b:_0;path=a:_0,b:2'` -- a town

Hex edges are numbered 0-5; an endpoint written `_N` refers to the Nth city/town declared
earlier in the same string. Twenty of these tile strings are ported verbatim into
[lib/models/tile_seed_data.dart](../../lib/models/tile_seed_data.dart) (plain yellow track,
yellow cities/towns, common green upgrades) plus a blank map hex. Adding a tile means
adding one line there -- nothing else changes.

Using this data twice is what removes the need for tile artwork: the same definitions are
both the route graph's topology and the source of the reference images the classifier
matches photos against.

## How it fits together

```
photo
  -> manual grid alignment (drag + sliders)            screens/image_processing.dart
  -> per-hex crop matched against rendered templates   processing/tile_classifier.dart
       templates drawn from tile definitions           processing/tile_renderer.dart
  -> PlacedTile (tile id + rotation) per hex
  -> review & correction, tap any hex or circle        screens/board_review.dart
  -> revenue: tile data where the match is confident,  processing/revenue_resolver.dart
       read from the photo where it isn't              processing/revenue_ocr.dart
  -> station tokens matched by colour                  processing/token_detector.dart
  -> stations + track runs between them                models/board_graph.dart
  -> best route within a stop limit                    processing/route_finder.dart
  -> route drawn back over the photo
```

## The pieces

**Hex geometry** ([models/board.dart](../../lib/models/board.dart)) is the single source of
truth for where hexes sit, shared by the alignment overlay, the template renderer, the OCR
crops, and the route overlay. Hexes are pointy-top in an odd-r offset layout. Edges run
clockwise on screen: 0=E, 1=SE, 2=SW, 3=W, 4=NW, 5=NE, so the edge shared with a neighbour
across edge k is always `(k + 3) % 6`, matching the tile DSL's numbering. `Board` doubles as
the grid calibration and maps between screen coordinates and image pixels, so an alignment
made on one screen is reusable on another.

**Tile definitions** ([models/tile_definition.dart](../../lib/models/tile_definition.dart))
parse the DSL subset we need -- `city=`, `town=`, `path=`, with `revenue`/`slots` -- and
skip what we don't (labels, upgrades, borders, junctions, multi-lane track). `rotated(n)`
turns a tile by n 60-degree steps.

**Classification** ([processing/tile_classifier.dart](../../lib/processing/tile_classifier.dart))
renders every tile in every rotation, then scores a cropped hex against them by
brightness-normalized mean squared error. It reports a confidence, measured against the best
*different* tile so a symmetric tile isn't called uncertain just because two of its own
rotations tie. This is a coarse matcher and is expected to be wrong sometimes, which is why
correction is part of the flow rather than an afterthought.

**Board graph** ([models/board_graph.dart](../../lib/models/board_graph.dart)) reduces the
board to what routing needs. Stations (cities/towns) are nodes; plain pass-through track is
contracted into the edge that crosses it, so a run of straights between two cities is one
`TrackEdge` that remembers the hexes it crosses (which is what the route overlay draws).
Track only joins across a hex boundary when both tiles have track reaching that side.

**Route search** ([processing/route_finder.dart](../../lib/processing/route_finder.dart))
enumerates simple paths out of the home station -- no station twice, no stretch of track
twice -- and joins the best two non-overlapping arms, so a route runs both ways out of its
home as a real one does. `maxStops` stands in for train length and is the seam where real
train rules will plug in. `bestRouteAnywhere` ignores tokens, for use before tokens are set.

**Revenue** ([processing/revenue_resolver.dart](../../lib/processing/revenue_resolver.dart))
takes each station's figure from the most reliable source available:

1. A value the user typed.
2. The tile data, when the tile was matched confidently or the user confirmed it in the
   tile editor. Printed tile revenue is more dependable than reading small print off a photo.
3. A number read off the photo, when the tile match was doubtful.
4. Otherwise the doubtful tile's own value, flagged as unverified so the user checks it.

"Confident" is `TileMatch.reliableConfidence`, currently 0.25. That is a first guess and
needs tuning against real board photos. The review screen reads the photo for doubtful
stations as soon as it opens, and the toolbar button re-reads them on request.

**Text recognition** ([processing/revenue_ocr.dart](../../lib/processing/revenue_ocr.dart))
uses each platform's own recognizer over one method channel, rather than a Flutter plugin:
Apple's Vision framework on iOS ([TextRecognitionPlugin.swift](../../ios/Runner/TextRecognitionPlugin.swift))
and ML Kit on Android
([TextRecognitionChannel.kt](../../android/app/src/main/kotlin/com/example/eighteen_xx_calculator/TextRecognitionChannel.kt)).
The reason is CocoaPods: its trunk goes read-only on 2 December 2026, and Google ships ML
Kit for iOS only as a CocoaPod, so the Flutter ML Kit plugins can't move to Swift Package
Manager. Vision ships with iOS, so the iOS app has no CocoaPods dependency at all. Android
gets ML Kit through Gradle, with the Latin model bundled so it works offline. The two
engines may read the same photo differently, so check revenue reading on a device of each
kind.

**Review UI** ([screens/board_review.dart](../../lib/screens/board_review.dart)) treats
recognition as a first draft: tap a hex to change its tile or rotation, tap a circle to fix
its revenue or set which company has a token there. Doubtful tiles and unverified revenue
are outlined in amber, figures read from the photo in blue, and each station's editor says
where its figure came from. Token detection fills in suggestions that are never trusted
silently.

## Deferred

- Real train rules: train types, "+" trains counting towns separately, E/D trains, city slot
  availability, token requirements, route group restrictions. `maxStops` is the placeholder.
- Automatic hex detection and perspective correction -- alignment is manual.
- The rest of the standard tile manifest, and the parts of the DSL the parser skips.
- Cities, towns and off-board areas printed on the map itself. These aren't tiles, so they
  aren't recognized and have no station in the graph. The photo fallback can only correct
  the revenue of a station that exists, so it can't fill this gap on its own. Per-title map
  data, which tobymao/18xx also has, is the likely fix.
- Per-title company lists; companies are currently the eight token colours in
  [models/company.dart](../../lib/models/company.dart), renameable by the player later.

## Verifying

- `flutter analyze` -- clean.
- `flutter test` -- 80 tests covering DSL parsing and rotation, hex adjacency (including a
  cross-check that the topology agrees with the on-screen geometry), graph building,
  route search, classifier round-trips, token colour matching, revenue source priority,
  the text-recognition channel contract, and the review screen's tap, fallback and route
  flows.
- `flutter build apk --debug` -- builds, with the channel handler and ML Kit's bundled
  model in the APK.
- iOS -- the Swift sources type-check against the iOS simulator SDK targeting iOS 13. A full
  `flutter build ios --simulator` couldn't finish on the machine this was written on,
  because its Xcode doesn't have the iOS 26.5 platform component installed. CocoaPods is
  no longer involved.
- On a device: photograph a few tiles, align the grid, scan, then check the tile ids,
  the amber values, set a token, and find a route. Recognition quality under real
  lighting is the part that will need iterating.

## Notes for the next pass

- iOS builds with Swift Package Manager only. The Podfile and the CocoaPods includes in
  `ios/Flutter/*.xcconfig` have been removed, and the deployment target is back to iOS 13.
  Adding a plugin that only ships a CocoaPod would bring CocoaPods back, so check for
  Swift Package Manager support before adding iOS plugins.
- Camera permission strings were missing from both platforms and have been added.
- Three things that were quietly broken before this pass, now fixed: the hex grid used
  mismatched spacing constants and so could never line up with a real board; the gesture
  detectors deferred to their children, so dragging the grid and tapping the board did
  nothing; and `permission_handler` (unused, pinned to `any`) had drifted to a version
  requiring compileSdk 37, which failed the Android build. Dependencies are now pinned
  rather than `any`, so this can't recur silently.
- The classifier's accuracy on real photos is untested; if it proves weak, the next thing
  to try is matching on colour as well as shape, and using the hex's dominant background
  colour to narrow candidates to one tile phase before scoring.
- Once real photos are available, tune `TileMatch.reliableConfidence` from them: too low
  and misread tiles supply wrong revenue silently, too high and most revenue comes from
  the less reliable photo reading.
- Reading the photo on confident tiles too, and flagging any disagreement with the tile
  value, would be a cheap way to catch tiles that were matched confidently but wrongly.

# Recognition & Route Plotting

Status: second pass. The app now knows the title it is looking at, finds the hex
grid in a photo by itself and corrects the camera's angle, keeps a game session
between photos, and asks for close-ups of the hexes it isn't sure about. Train
rules are still the one big thing missing (see Deferred).

## Context

The app photographs an 18xx board, works out what's on it, and finds the
best-paying route for a company.

The first pass could read a board, but only if the user dragged a rectangular
hex grid over the photo by hand. That fell apart on a real board: a hand-held
photo has perspective, so a grid that lines up on one side is out by half a hex
on the other; real maps aren't rectangles, and hexes are missing all round the
edge; and matching every hex against every tile produced false tiles on an empty
board.

This pass fixes all three, and changes the shape of the app: a game is now a
**session** that persists, and photos update it rather than re-reading the whole
board each time.

## What it does now

1. Pick a title (1844 or 1854), then start or resume a game.
2. Photograph the whole board once. The app finds the grid, deskews it, works out
   which hex is which, and reads the board.
3. It flags hexes it isn't sure about and offers close-ups, grouped so one photo
   covers a hex and its six neighbours. The camera shows an outline to line up
   with.
4. Through the game, photograph just what changed -- one close-up per tile lay --
   and the session keeps up. Everything can still be corrected by tapping.
5. Ask for the best route for a company, at any point.

```
photo
  -> hex grid found automatically              processing/grid_detector.dart
       repeat + angle from autocorrelation
       perspective fitted to printed outlines
       title's map slid over the grid
  -> deskewed hex patches                      processing/hex_patch.dart
  -> what the rules allow on each hex          models/tile_rules.dart
  -> best match among those                    processing/tile_classifier.dart
  -> merged into the game session              models/game_session.dart
  -> low-confidence hexes grouped              processing/board_reader.dart
       -> close-ups, framed with a guide       screens/capture.dart
  -> route search over the session's graph     processing/route_finder.dart
```

## Where the data comes from

[tobymao/18xx](https://github.com/tobymao/18xx) (the engine behind 18xx.games,
MIT licensed) has both the tile designs and the per-title maps.
`tool/import_tobymao_title.dart` fetches a title's `map.rb`, `tiles.rb` and the
shared `config/tile.rb`, reads the Ruby constant hashes, and writes
`lib/titles/title_<id>.dart`:

```
dart run tool/import_tobymao_title.dart 1844
```

That gives, for each title: every hex that exists, what is printed on it (cities,
towns, off-board revenue by phase, pre-printed track, labels, impassable
borders), place names, and the tiles in the box with their counts. 1844 has 131
hexes and 59 tile designs; 1854 has 100 and 42.

**Which side is which.** tobymao numbers a pointy-top hex's sides from the
south-west, running clockwise: 0=SW, 1=W, 2=NW, 3=NE, 4=E, 5=SE. This is not
obvious from the data and getting it wrong is quiet but ruinous -- the printed
track faces the wrong way, so the upgrade rules reject the tile that is actually
on the hex and recognition never even considers it. It was settled against the
printed 1844 board: A20's `path=a:0` and `path=a:5` are the sides facing B19 and
B21, Bern's `path=a:5` faces G12, and Lausanne's `a:1,2,4` are its west,
north-west and east sides. [HexGeometry] defines it in one place, and
`board_test.dart` pins it to those printed hexes.

Knowing the map is what makes the rest work. It says which hexes exist (so the
ragged edge of the map can be matched against the photo), which hexes never
change (red off-board areas and grey hexes are never scanned), and what is
printed underneath each tile.

## Finding the grid

[processing/grid_detector.dart](../../lib/processing/grid_detector.dart) does
this in four steps, all on a copy of the photo about 1024 px across, reduced to
"how strongly does this pixel sit on a thin dark line".

**The repeat.** A photo of a hex grid, shifted by exactly one hex, lines up with
itself. The autocorrelation of the line image therefore peaks at the six
neighbour offsets, 60 degrees apart, which gives the hex size and the angle of
the grid without knowing anything about the map. Two traps: every other hex also
repeats, and so does the 30-degree-rotated grid through the hex corners, so a
candidate is only preferred over the strongest peak if it is a real peak in its
own right (it beats the shifts just short of and just past it), not merely a high
value on the slope near zero shift.

**The phase.** Folding the line image onto a single repeat of the lattice
averages every hex in the middle of the photo together, and matching that against
an ideal hex outline says where the hex centres fall.

**The perspective.** The grid is then pulled onto the printed outlines, a ring at
a time from the middle outward: each sample point on a predicted hex side looks
along its normal for the darkest line nearby, and a new perspective transform is
fitted to those matches with outliers down-weighted. Growing outward matters --
the grid never has to jump more than a fraction of a hex, so it can't lock onto
the wrong hex -- and a full perspective transform (eight numbers, not the four a
move/scale/turn has) is what actually absorbs the camera's angle.

**Which hex is which.** The map is then slid over the grid, in 60-degree turns
and whole-hex steps, to where the most map hexes land on printed outlines and the
fewest outlines are left uncovered. Ties are broken on colour: red off-board
hexes, yellow pre-printed hexes and grey hexes have to land on hexes of about
that colour, measured against each hex's own neighbours so uneven lighting
cancels out.

Two things learned from a real photo (a webcam shot of an 1844 board, lit
unevenly, with a fold across the middle):

- Line strength has to be normalized locally. Glare washed out the outlines over
  one part of the board; measured absolutely, those hexes looked like bare table.
  Dividing by the local average line strength fixed it.
- The map's silhouette alone is nearly symmetric enough to place the map upside
  down. Colour agreement is what settles it.

On that photo the whole thing takes about 1.2 s and places all 115 visible hexes
within a fraction of a hex, including across the fold.

## Reading the hexes

Each hex is sampled through the perspective transform into a square patch framed
exactly as `TileRenderer` draws a tile, so a tile in the photo lines up pixel for
pixel with its rendered template whatever angle the photo was taken at
([processing/hex_patch.dart](../../lib/processing/hex_patch.dart)). The patch
keeps two things: where the dark printing is (with coloured darkness discounted,
so lakes and rivers don't read as track) and the background colour.

[models/tile_rules.dart](../../lib/models/tile_rules.dart) then says what could
be on that hex: what was there before, and the legal upgrades of it -- next
colour, same number of cities and towns, keeping the track already laid, matching
the hex's label, not running off the map or across an impassable border. That is
usually a handful of options instead of every tile in every rotation, and it is
the single biggest reason recognition is more accurate than in the first pass.

[processing/tile_classifier.dart](../../lib/processing/tile_classifier.dart)
scores those options on where the dark printing lies, on background colour
(judged against the bare map nearby in the same photo), and with a penalty per
upgrade step, since most hexes don't change between photos. When the hex has been
photographed before, the "unchanged" option is also compared against that earlier
picture, which is how printed map art the renderer doesn't draw stops being a
problem.

Confidence is the margin between the best option and the next. Anything close is
reported as "worth a closer look" rather than as an answer, because a small lead
usually means map art, not a tile.

The tile editor will let the user pick any tile at all, since the rules here
don't cover every title's exceptions -- but it says so when the choice doesn't
fit ("F13 has 1 town printed, but tile 5 has 1 city"), and the board outlines
such a hex in red. A city where the map prints a town is an easy slip and it
makes every route through that hex wrong.

## Sessions and close-ups

A session ([models/game_session.dart](../../lib/models/game_session.dart)) holds
what the app believes about every hex: the tile, how sure it is, where that came
from, and how the hex looked when it was last sure. Sessions are saved per title
([services/session_store.dart](../../lib/services/session_store.dart)), along
with a small picture of each hex, which the tile editor shows next to what the
hex was read as.

Two rules keep the state honest:

- A doubtful reading is shown but doesn't become the basis for the next one, so
  one bad photo can't narrow what later photos are allowed to find.
- A doubtful reading never overwrites something the user set by hand; it only
  flags the hex. A confident one does, because that is a tile being laid.

Close-ups are the normal way to update a game. `planCloseUps` groups hexes into
as few photos as possible (each covers a hex and its six neighbours), and the
camera draws that outline over the preview. Which hexes is up to the user: a
board where recognition is unsure of twenty hexes is twenty hexes' worth of
photography, and after an operating round the player knows perfectly well which
three hexes changed. The board has a choosing mode -- tap the hexes, see how
many photos that comes to, take them -- reachable from the toolbar or from the
"needs a closer look" banner. Nothing starts chosen; an "All" button takes
everything the app is unsure of, to then toggle back off. Lining the board up with the
outline does two jobs: it frames the right hexes at a workable size, and it tells
the app which hex is which -- which a close-up of a repeating grid can't
otherwise say. The fit is then corrected against the printed lines, so the
framing only has to be good to within about half a hex. A close-up of Bern's
neighbourhood is roughly eight times the detail of the same hexes in a
whole-board photo.

## The rest

**Hex geometry** ([models/board.dart](../../lib/models/board.dart)) is unchanged:
pointy-top hexes, odd-r offset coordinates, edges 0..5 clockwise from east, and
cube coordinates for turning and measuring. Printed coordinates like `D19` are
converted on import.

**Board graph** ([models/board_graph.dart](../../lib/models/board_graph.dart))
now builds from what is on each hex -- a laid tile, or the map's printing where
there is none -- so printed cities, towns and off-board areas are stops, and
impassable borders block connections. Off-board revenue follows the session's
phase.

**Route search** ([processing/route_finder.dart](../../lib/processing/route_finder.dart))
is as before, with one rule added: a route can end at an off-board area but not
run through it. `maxStops` still stands in for train length.

**Revenue** comes from tile and map data. Where a hex is doubtful, the station
editor can read the printed figure off that hex's stored picture using the
platform text recognizers (Apple Vision on iOS, ML Kit on Android) over the
existing method channel.

## Deferred

- Real train rules: train types, "+" trains, E/D trains, city slot availability,
  token requirements, route groupings. `maxStops` is the placeholder.
- Per-title company lists and liveries; companies are still the eight token
  colours in [models/company.dart](../../lib/models/company.dart).
- Titles whose maps are flat-top rather than pointy-top; the importer refuses
  them rather than importing something wrong.
- Maps printed in two pieces (1854's local railways may be a separate inset on
  the physical board). The detector places one connected map; if a title's map is
  in two pieces, the second would need its own placement.
- Tile counts are imported but not used; "there are only two of tile 15 in the
  box" would be a good extra constraint on recognition.
- Hexes at the very edge of the map (red off-board areas, the grey mountain
  railways) are printed as part-hexes running off the board, so a close-up
  centred on one has little grid to lock onto. The planner aims at hexes that
  take tiles instead, and a fit is judged on the hexes that are drawn in full,
  but a photo of nothing but the map's edge will still fail.

## Verifying

- `flutter analyze` -- clean.
- `flutter test` -- the suite covers the perspective maths, the imported maps
  against how the boards are printed, the upgrade rules, grid detection (on
  boards drawn from the title data and re-photographed through a perspective
  transform, including turned, angled and unevenly lit), recognition end to end,
  session state and saving, close-up planning, and the screens.
- `test/photo_fit_test.dart` runs detection against a real photo that isn't
  checked in:

  ```
  BOARD_PHOTO=~/board.png BOARD_TITLE=1844 BOARD_PHOTO_OUT=/tmp/fit.png \
    flutter test test/photo_fit_test.dart
  ```

  It prints the fit and writes the photo with the grid drawn over it, which is
  the quickest way to see what detection is doing.

## Notes for the next pass

- **Recognition on real tiles is untested.** Everything here has been checked
  against one photo of an *empty* 1844 board and against boards drawn from the
  title data. On the empty board all 95 hexes now read as bare, with one
  flagged for a closer look; before the side-numbering was fixed, three hexes
  were confidently read as track that wasn't there. Photograph a board with
  real tiles on it and tune from there: `TileClassifier._shapeScale`,
  `_stepPenalty` and `_marginScale`, and `TileReading.reliableConfidence`, are
  the knobs, and the per-hex pictures the session saves are the evidence.
- Every `Isolate.run` lives in `services/photo_pipeline.dart`. A closure written
  inside a `State` method shares its captured context with the closures around
  it, so a neighbouring `setState` drags the widget tree and the framework's
  zone into the isolate message and it fails with "object is unsendable" --
  which the align screen then showed as a wall of text. Keep the heavy work
  behind the pipeline, and keep error messages short enough to fit on screen.
- The "photograph the empty board first" step exists because of that lake hex: it
  records how every hex looks bare, which is what later photos are compared
  against. It is worth checking how much it actually buys once there are tiles to
  read.
- `ColourModel.defaults` was measured from one warm-lit webcam photo. The reader
  replaces those values with what it measures whenever the photo has enough hexes
  of a colour it already knows, so the defaults only matter for the first photo
  of a game.
- Detection assumes the photo isn't mirrored. The macOS webcam path turns
  mirroring off; a mirrored photo would not match any rotation of the map.
- `path_provider` reaches Foundation through FFI (2.6.0), so it adds no
  CocoaPods dependency on iOS -- worth re-checking on upgrade, since the iOS
  build has no CocoaPods at all and adding a plugin that only ships a pod would
  bring it back.

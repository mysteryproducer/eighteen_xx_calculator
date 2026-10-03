# Recognition & Route Plotting

Status: tenth pass. The app knows the title it is looking at, finds the hex
grid in a photo by itself and corrects the camera's angle, keeps a game session
between photos, and asks for close-ups of the hexes it isn't sure about. It has
been through most of a real game of 1844: tiles up to brown, the five-hex
Furka-Oberalp piece, station tokens, tunnels, mountain railways with their
plates read, and photos taken under glare and in evening light. 1889, whose
board is flat-topped, is imported for the next game. This pass adds the
companies' side of the table: each company's trains run together under the
title's train rules, a photo of a player's area reads charters (trains, tokens
left) and share certificates, and the players' holdings turn a company's
routes into what each of them is paid. Money isn't tracked, by choice: it
would take a lot of keeping up, and can't be read from photos. The eighth pass
came from a fresh game started over the same board, photographed once from an
angle to dodge the lamp's glare: tiles are now read from how their track runs
on into the next hex as well as within their own, the cities on the green and
brown tiles are drawn as they are printed, close-ups can be taken at an
angle, and charters are read better (see each section). The ninth pass closes
the 1844 game -- every grey tile down -- and checks more of the rules: a
company with tokens down and none in its home city, plain track tiles whose
two curves only look joined, and a route's bonus, spelt out on a tap. 1889's
data has been gone over for the next game: its diesel off-board figure, its
port tile and its phases (see Where the data comes from). The tenth pass came
from the first sessions on an Android phone, a Nokia C32: its photos are
sharper, and the automatic fit finds the grid in them; and snapping a rough
placement now recovers from handles up to about half a hex out, where it used
to need them within a tenth (see Finding the grid). The eleventh pass came
from the first session of 1889, on an iPhone. That edition's tiles are
double-sided, the usual drawing on one side and a geometric texture with
darkened city circles on the other, and both are recognised; a circle
darkened in the tile's colour is no longer taken for a token; a company's home
token is taken as down, since 1889 prints each company's logo in its home
city; 1889's charters and fanned certificates are read, from a photo taken
sideways too; the align screen names the hexes to drag, as this board prints
no grid; and a tile or train of a later colour offers the next phase (see
each section).

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

1. Pick a title (1844, 1854 or 1889), then start or resume a game.
2. Photograph the whole board once. The app finds the grid, deskews it, works out
   which hex is which, and reads the board.
3. It flags hexes it isn't sure about and offers close-ups, grouped so one photo
   covers a hex and its six neighbours. The camera shows an outline to line up
   with.
4. Through the game, photograph just what changed -- one close-up per tile lay --
   and the session keeps up. Everything can still be corrected by tapping.
5. Ask for the best routes for a company, at any point: each of its trains
   runs its own route, under the title's rules.
6. Photograph a player's area (the camera button's second choice): company
   charters with their trains and the tokens left on them, and share
   certificates. Confirm or correct what was read, and say whose
   certificates they are; the first charter's routes are then worked out.
7. Players, and the certificates each holds, are kept under More > Players
   and shares; the route panel shows what each is paid.

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
       a route per train, no shared track      processing/train_routes.dart

photo of a player's area
  -> lines of text, with where each lies       processing/revenue_ocr.dart
  -> charters, trains, tokens, certificates    processing/play_area_reader.dart
  -> checked by the rules, confirmed           models/company_rules.dart
                                               screens/play_area_review.dart
```

## Where the data comes from

[tobymao/18xx](https://github.com/tobymao/18xx) (the engine behind 18xx.games,
MIT licensed) has both the tile designs and the per-title maps.
`tool/import_tobymao_title.dart` fetches a title's `map.rb`, `tiles.rb`,
`entities.rb` and the shared `config/tile.rb`, reads the Ruby constant hashes,
and writes `lib/titles/title_<id>.dart`:

```
dart run tool/import_tobymao_title.dart 1844
```

That gives, for each title: every hex that exists, what is printed on it (cities,
towns, off-board revenue by phase, pre-printed track, labels, impassable
borders), place names, the tiles in the box with their counts, and the
companies that put tokens on the board, with their token colours and home
cities. 1844 has 131 hexes, 62 tile designs and 15 companies; 1854 has 100, 42
and 17; 1889 has 52, 40 and 7. (1854 builds its six local railways in code
from three plain lists; the importer reads the lists.)

From `game.rb`, `trains.rb` and `phases.rb` (1854 keeps them in files of
their own) it also reads the trains -- how far each runs, what it costs,
which train scraps it, each variant (1844's 2H) a train of its own -- and the
phases with their train limits by kind of company; and from `entities.rb`
each company's kind, token costs (`[0, 40]`: the home token's first) and share
certificates (`[50, 25, 25]`: the director's first). A train's distance can
be split by kind of stop: 1844's 8E visits any number and is paid for 8
(`pays: 8`), 1854's "+" trains run to so many cities and any number of towns
(`freeTowns`). Rules that live in tobymao's game code rather than its data
are kept by hand in `GameTitle`: which trains count hexes (1844's H trains),
the route rules below, and the special upgrades.

**Flat-topped boards.** 1889's map is printed with flat-topped hexes, lettered
by column and numbered by row. The app keeps every map pointy-topped: a
flat-topped board turned a twelfth of a turn clockwise is exactly a
pointy-topped one, and each side keeps its number (side 0, the bottom of a flat
hex, becomes the lower left of a pointy one), so the title's tiles carry over
unchanged. Stepping across side k is the same step on both, which makes
tobymao's flat doubled coordinates (x, y) the pointy doubled coordinates
((3x - y) / 2, (x + y) / 2) -- `MapLayout.coordFromFlatId`. Everything that
reads photos works on the turned map as it does on 1844's (the grid detector
finds a flat board photographed as printed with no change), and everything
that draws turns it back by `GameTitle.displayTurn`: the board, the tile
pictures, the close-up guide and the align screen's starting grid.

The importer also skips a tile printed exactly like one already listed --
1889's beginner variant lists 6 again as Beg6, and so on, and two identical
drawings would always tie in recognition. 1889's off-boards print a third
figure, "diesel", which tobymao pays to a D train alone (its
`route_base_revenue`): every other train is paid the brown figure to the end
of the game. So it is kept apart from the phases (`TileStation.dieselRevenue`,
`StationNode.revenueFor`), and a session's phase is one of the tile colours
the title's phases bring in (`GameTitle.phaseColours`) -- for 1889, yellow to
brown; it had been offered a grey phase, which paid every train the diesel
figure. Checked against tobymao's 1889 game code, the rest of its data was
already complete: the map, tiles and counts, companies with their homes,
token costs and tobymao's default shares (a 20% director's and eight 10%), the
trains (D, unlimited, runs any distance) and the phases with their train
limits. Its private companies change money and when tiles may be laid, not
routes, and aren't modelled, except that the port tile (437) goes only where
the Mitsubishi Ferry may lay it (see Reading the hexes). Where the printed pieces place cities
differently from tobymao's rule (see Reading the hexes), a small table in the
importer gives their places.

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

A third trap turned up on the first photo of a game in progress: a coarser
grid of every fourth hex, whose long shifts scored a shade higher than the real
neighbours (a slightly soft photo loses more across the rows, where outlines
slant, than along them). The grid came out four times too big. A photo of the
whole board bounds the answer: the map can't be more than two and a half times
the size of the frame, which a board cut off at the edges still fits well
inside and every-fourth-hex doesn't. Every side of a candidate triple also has
to be a real peak, not just a local maximum -- the third side is the difference
of two rounded peaks, so its own peak may be a pixel away.

The opposite trap came with photos taken at more of an angle: the map placed
as a small grid squashed into one corner. Perspective makes the far side of
the board repeat at about two thirds of the near side's spacing, so over the
whole photo the real repeat smears out, and something finer -- half the
spacing, or printing close around every hex -- wins instead. So the repeat
is bounded from below as well (the map spans at least half the frame), and
when nothing within the bounds stands out, it is looked for again in the
middle three fifths of the photo, where the spacing varies much less. All
five whole-board photos of the third round now fit, covering 60-80% of their
hexes, and the earlier photos fit as before.

A close-up gets help. The capture guide already says roughly how big a hex
should be, which does two things: the line filter is built to match an outline
of that width (an outline is a fixed fraction of a hex across, so it is a
hair's breadth in a whole-board photo and several pixels wide in a close-up,
and a filter for one looks straight past the other), and the repeat is looked
for near where it should be rather than anywhere. That matters because a
close-up taken at a low angle keeps the repeat along the rows and loses it
across them -- perspective squeezes the far rows closer together than the near
ones -- so one axis often has to carry the answer. One is enough: hexes are
regular, so the other follows at 60 degrees.

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

**A close-up framed a hex off.** Lining an outline of seven hexes up on the
wrong seven is an easy slip -- the grid looks the same everywhere -- and the fit
then reads every hex from the one next door. It happened on the first real
close-up of Andermatt: framed on H15, it read the tile on H13 as a straight on
H15 and missed the tunnel piece entirely. What does differ is what is printed
where: grey mountain railways, purple tunnels, red off-board areas and lakes
never move. So the fit is also tried one hex each way, and a placement is taken
over the guide's only if the photo's colours agree with the map's clearly
better there (yellow against blue only: that is what sets the beige map and its
tiles apart from grey and purple, while red against green varies with the
light). In a plain stretch of map there is nothing to go on, and the guide
stands.

**What the game already knows.** By the fourth round of photos a third of the
board was tiles, and tiles cover the printed outlines the grid is fitted to:
on the evening photo of the whole board only 73 of 206 cells showed an
outline, the map was placed upside down, and a close-up of Basel was fitted
two-thirds of a hex out. The session knows a great deal that the photo can be
checked against, and three things use it (`BoardHints`):

- Placing the map compares the photo's colours with the colours the session
  expects -- each tile's, where one is laid -- instead of the printed map's.
  The agreement now counts for as much of the map as it covers (a placement
  overlapping a handful of cells could agree with them by chance and won
  before), the shortlist of placements takes any that fit the outlines half
  as well as the best (tiles hide outlines), and colour counts double. The
  evening photo is placed right; every earlier photo still is, with a wider
  margin.
- Which way the board faced in the last photo of it (`GridFit.facing`, kept
  in the session) is preferred unless the photo clearly says otherwise, and
  turns the close-up guide to match: players photograph from where they sit.
  A close-up taken from the side of the board fails without it and fits with
  it.
- After fitting, the hexes the session is sure of -- tiles it knows, printed
  cities and towns -- are matched against their drawings a little way around
  where the grid put them (`BoardReader.alignToKnown`): first all together,
  since one hex can match by chance a little way off but not all of them the
  same way, then each a little further for any turn or perspective. The
  correction is only as flexible as they are spread: a plain shift for a
  cluster, a slight turn and scaling over a few hexes, perspective across a
  whole board. Likeness is a correlation of darkness, not a distance: by
  distance a blank hex is a near miss for a misplaced tile, so the search
  wandered off onto plain map. Basel's close-up comes back into line (the
  tiles there go from 0.2 to 0.9 alike) and reads both tiles at 99%; the
  evening board reads 43 hexes as tiles and leaves 7 doubtful, against 35 and
  27. It takes a quarter of a second, on a coarse picture of each hex.

A colour-only version of the last step (lining up expected colour regions)
was tried first and dropped: under evening light the beige map and pale
yellow tiles barely differ, and it turned the Basel close-up four degrees the
wrong way.

**Following the board in the preview.** Close-ups taken with the camera turned
20-30 degrees from the guide were the commonest failure in the fifth round of
photos: the fit locked onto the hexes next door, so plates went unseen and
brown tiles unread. On the Mac the capture screen now looks at a preview frame
about once a second (`processing/guide_follower.dart`) and moves the guide to
match: a turn of up to 25 degrees, a quarter bigger or smaller, and under
three-quarters of a hex across -- small enough that it can't swing onto other
hexes. Each look starts from where the guide was first drawn, never from the
last correction, so it can't drift; when the board is lost the guide eases
back. The photo is fitted starting from the guide as it was when taken. Frames
are read by brightness alone, since the webcam's byte order isn't fixed, which
the line-finding doesn't need. (Phones stream frames in the sensor's own
orientation, a quarter turn from the screen on most, so they don't follow yet.)
The close-up fit itself now looks for the grid up to 28 degrees either way of
the guide, rather than 20, and lining up with known hexes no longer trusts a
best match at the edge of its search.

**Locking on, and tilting.** Angling the camera is the best cure for glare,
and a close-up guide that only turns and scales made the user hold the camera
square over the board. Once the guide has found the board on two looks in a
row it now locks on (`trackGuide`): from then on each look pulls the outline,
perspective and all, onto the printed lines from where it last was, so the
camera can be tilted and the outline follows. Each step is small -- no corner
of the target hex may move more than a third of a hex -- so it can't slide
onto the next hex; three looks without the board and it goes back to
following flat. The outline and the faint tiles in it are drawn through the
same perspective, the placement is kept in units of the frame's shorter side
so it holds on the full-size photo, and the close-up fit tries that placement
pulled straight onto the lines as well as a grid measured afresh, keeping
whichever sits better. Tested on synthetic previews (a camera tilted so the
far rows are 30% narrower is followed to within 0.15 of a hex); not yet on
the real webcam.

**When detection fails anyway**, the align screen starts from the map laid over
the middle of the photo rather than from nothing, or from a wrong fit whose
handles are off screen. The grid moves by dragging, sizes by pinching (touch
or trackpad), scrolling or buttons, turns a quarter at a time, and "Fit to the
photo" puts it back over the photo whenever it gets lost.

The four hexes to drag are near the board's corners, each moved to a named
place within two hexes where there is one (`MapLayout.anchors`), and labelled
by that place -- Sukumo, Sakaide & Okayama, Naruto & Awaji and Muroto on 1889,
whose board prints no grid references at all -- or by grid reference, a
choice the align screen toggles and keeps (`AppSettings.labelAnchorsByName`).

**A photo taken at a steep angle** -- the 2 October game's, the far edge of
the board three quarters the width of the near one -- defeats the lattice
search: the rows come out much closer together than the hexes along them,
and the size of hex changes across the frame, so the repeat smears out even
in the middle. Stretching the photo back to proportion before searching was
tried and kept as a last resort, but didn't find this one. What does work is
the user's placement, snapped onto the printed lines ("Snap to lines").

**Snapping a rough placement.** Snapping used to pull the placement as it was
onto the lines (`GridDetector.refine`), or measure the hex size afresh in the
middle and grow from there, keeping whichever sat better. Measured on five real
photos -- two from the webcam and three from the phone, two of the five taken
at an angle -- with the four handles moved off their hexes in random
directions, neither recovered unless every handle was within about a tenth of
a hex: a quarter of a hex out, neither ever did, and measuring afresh often
ended half a hex out, misled by track and printing. A tenth of a hex is a few
pixels on a phone's screen, which is why lining the grid up was so hard.

Snapping now settles the placement hex cluster by hex cluster
(`GridDetector._settle`). Each visible hex and its neighbours find, on their
own, the shift of up to a little over half a hex that puts their outlines
best on the printed lines; a placement is fitted to the clusters that agree
with each other, to within a sixth of a hex, leaving out the ones under tiles
or glare; and that is pulled onto the lines as before. Each cluster only has
to be right where it is, so a placement out by a different amount in each
corner -- shifted, turned, stretched and skewed at once, which is what four
rough handles give -- settles as well as one that is merely shifted. With
every handle a quarter of a hex out it recovered 8 times in 8 on all five
photos; 0.4 of a hex out, 5 to 8 in 8; half a hex out, 3 to 8 in 8, the
angled photos being the hardest. Beyond half a hex, a hex is nearer its
neighbour's place than its own, which only the user can settle. It takes
about a third of a second on a laptop, a third of what snapping took before.
Where too few clusters show their outlines -- a close-up of tiles -- it falls
back to the old two.

The automatic fit ends with the same step, kept when the outlines sit better
for it. The phone's whole-board photos had come out a fraction of a hex out
towards their edges, and now read 94 of 94 hexes right where one read 86
(against the round 9 game, which shows the same board). On twelve webcam
photos it changed nothing the fit had right: no hex moved more than 0.03 of
a hex. It can't put right a fit with every hex one place out, which is what
the 2 October evening photo gets (below).

The 2 October evening photo is misplaced too: the
perspective comes out wrong as the lattice grows, and the map settles half a
hex out. An affine fit while growing, a guard on each growth step, trying the
half-hex alternatives and a wider search for the lattice's phase each placed
it, and each broke others -- the 1 October photo with six tiles fell from 82
hexes right to 78, the pre-play board's coverage from 0.78 to 0.22 -- so none
was kept, and it is placed with the handles. Looked at again in the tenth
pass, its grid is right but every hex is one place out (Bern is taken for
E10): which hex is which went wrong, not where the outlines are.

## Reading the hexes

Each hex is sampled through the perspective transform into a square patch framed
exactly as `TileRenderer` draws a tile, so a tile in the photo lines up pixel for
pixel with its rendered template whatever angle the photo was taken at
([processing/hex_patch.dart](../../lib/processing/hex_patch.dart)). The patch
keeps three things: where the dark printing is, the background colour, and how
much printing crosses each of the six sides.

That last one does most of the work of telling a tile from bare map: track runs
off the edge of a tile, while hill shading and place names don't. It is
measured in a thin band just inside each side, and the track has to run right
through the band rather than merely touch it -- tile track always meets a side
square on, so close to the side it runs straight in even where the rest of it
curves away, whereas the hex's own printed outline (dark, and blurred inward in
a photo of a whole board) doesn't reach the inner edge of the band. The first two
need care about colour. Lakes are dark and shouldn't read as track, but a test
for "dark and coloured" also throws away the track itself, which photographs as
a warm brown under warm light -- so the test is for blue in particular.

Comparisons are made on slightly blurred copies. Track is a thin line, and
comparing thin lines pixel for pixel punishes a line a little out of place
harder than a line that isn't there at all, so a real tile loses to bare map --
which is exactly what happened to a curve photographed on a real board.

[models/tile_rules.dart](../../lib/models/tile_rules.dart) then says what could
be on that hex: what was there before, and the legal upgrades of it -- next
colour, same number of cities and towns, keeping the track already laid, matching
the hex's label, not running off the map or across an impassable border. That is
usually a handful of options instead of every tile in every rotation, and it is
the single biggest reason recognition is more accurate than in the first pass.
A labelled city may change its number of cities, as tobymao allows -- 1844's
Lausanne is two cities in green and one of two circles in brown and grey,
which the rules had refused, so the grey 903 laid there in play was "not on
offer" -- but not from bare map, and never down to none. And a title can keep
a tile to certain hexes (`GameTitle.tilesOnlyOn`): 1889's port tile, which only
the Mitsubishi Ferry lays, goes on one of its four coastal towns. It is drawn
as printed now, its town a black disc with an anchor in it, but that is too
small a difference from 58's dot to choose between them -- on the real G10
the two score within 0.03 of each other, and 58 came out ahead -- so on those
four towns the app asks rather than tells. (What else tells them apart is
where the revenue sits, 437's 30 beside the town, which no tile's drawing
shows.)

Tiles are drawn the way tile art is drawn, because the drawing *is* the
template recognition matches against: artwork that is merely recognisable to a
person is not good enough
([processing/tile_renderer.dart](../../lib/processing/tile_renderer.dart)). A
run between two sides is the circular arc that meets both sides square on, so a
tight turn hugs the corner they share. Bending track through the middle of the
hex instead, as this did at first, makes every curve too wide and a
photographed curve then matches no template well -- which is what happened to
the curve on F13.

The rest of the geometry is tobymao's, ported rather than guessed: a `loc:` on a
city or town puts it half a radius out from the centre towards that side or
corner instead of in the middle; a town is a bar when it has track running
through it and a dot when it doesn't; and two things sharing the centre spread
30 degrees apart. Their own renderer could not be pre-rendered headlessly to get
this -- it is Opal and Snabberb, Ruby compiled to run in a browser -- so the
constants come from `assets/app/view/game/part/*.rb`.

Some titles have upgrade rules of their own, in tobymao's game code rather
than its data, and those are kept by hand (`GameTitle.specialUpgrades`): 1844's
Aarau (D15) is printed with two small cities that its first tile joins into
one city of two circles, so it takes 14, 15 or 619 and then the usual browns.
When a tile is refused, the reason counts circles as well as cities ("1 city
with 2 circles"), since "1 city" alone read as one place for a token.

Where stops go is worked out as the tiles are printed. A stop on its own sits
in the middle, unless it is a town on a run of track from side to side, which
sits halfway along the run with its bar across it (tiles 3 and 58 had been
drawn as a V through the middle). Where there are several -- the OO tiles --
each stop leans towards one of its sides, chosen by tobymao's rule (the least
crowded of its own sides), and sits on its own run of track about 0.4 of a
radius out: a straight, a tight turn round the corner, or a gentle curve
round the next hex's centre, as tiles draw them. tobymao applies its rule to
the tile as turned, which gets 1844's tile 67 wrong; applied to the tile as
printed and turned with it, it matches the tile photographed at Fribourg, one
city on each run, stacked on the east side. Some pieces are designed their own
way: the printed OO hexes (Romont and Fribourg one above the other,
Winterthur and Frauenfeld rising to the right) and tile 59, whose second city
sits out by side 4 with its track curving round to it. Those come from the
photos, through the importer's table.

**A title's own style of tile** (`GameTitle.tileStyle`): 1889's tiles print a
town as a dot on the track rather than as a bar across it, and the user's
edition is double-sided (`GameTitle.doubleSidedTiles`): the usual drawing on
one side, and on the other a geometric texture with the city circles and the
towns' rings printed in a darker shade of the tile, brown on yellow
(`TileStyle.shaded`). A tile with stops is matched against both drawings and
the better kept, and the reading says which side it saw
(`TileReading.shadedSide`). The texture is too faint to matter to the match;
the dark circles would otherwise make every city look full. The board and the
capture overlay draw tiles in the title's style too.

City slots are the exception, measured off the real tiles instead, because
tobymao's are drawn for a screen: its slots are a quarter of the radius, and
1844's printed slots are a third (0.30 where two share a city). Undersized
rings made every city tile a poor match for its photo, and the brown city
tiles of the third round, mostly ring, matched other tiles better than
themselves. The row of
slots in a two-slot city in the middle of a tile turns with the tile, but
which way it starts differs between tiles (15, 611 and 619 one way, 14
another), so recognition tries each of the three ways a row can run and takes
the best.

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

Three details that decided the tunnel piece. Templates are scaled against the
track colour, not against their own darkest printing as photos are: a hex whose
only printing is the faint dotted line of a railway not yet open was being
scaled up until it looked like solid track, and the tile that opens the line
couldn't be told from the map underneath. For the same reason a side that only
the unopened line reaches is expected to show faint printing, not solid. And
the sides are searched every half sample, interpolating: the piece's track is
printed thin, two samples wide, and the old search stepped over it. Then,
because a line opens all at once -- 1844's P4 lays all five hexes' tiles
together -- the hexes of a line in view are decided together, their evidence
added up: one hex alone is a close call, the line is not.

Recognition looks up to three lays ahead of what the session last knew for
sure (four where it has never been sure): bare map to brown is three, and a
game photographed now and then skips rounds. It looked two ahead before,
which put a brown tile on a hex last seen bare out of reach.

Tiles are never taken up in play, so the rules only look forward from what was
there. That made a misread permanent: the tile the off-by-one close-up put on
H15 would have stayed however many photos showed bare map. So where the app
read the tile itself -- never where the user set it -- bare map stays on offer
at the price of three upgrade steps, which only clear evidence pays.

The tile editor shows the choices drawn rather than listed
([widgets/tile_choices.dart](../../lib/widgets/tile_choices.dart)): a tile's
number means nothing at a glance, its shape means everything. The first row
has each tile once, grouped by colour; picking one shows a second row of the
ways it can turn, each drawn as laid. Within a colour, the tiles and turns
whose track joins the track on the hexes around come first ("joins 2"), but
nothing is left out for not joining up -- plenty of legal lays don't.

The editor offers everything that could legally be on the hex at any point in
the game, not just what could follow the tile there now. Recognition narrows
to what follows (that is what makes it tractable), but the editor is for
putting things right: a misread yellow tile needs the other yellow tiles on
offer, and a line laid in error needs "none". Offering only upgrades of the
current tile was why a hex holding a 58 showed no other yellow tile, and why
the Furka-Oberalp line couldn't be taken up once laid.

It will also let the user pick any tile at all, since the rules here don't
cover every title's exceptions -- but it says so when the choice doesn't fit
("F13 has 1 town printed, but tile 5 has 1 city"), and the board outlines such
a hex in red. A city where the map prints a town is an easy slip and it makes
every route through that hex wrong.

A line printed for later opening is one piece -- 1844's Furka-Oberalp line
covers five hexes -- so laying or lifting it on any of its hexes does the same
on all of them, each with its own part of it.

**Track at the sides, and across them.** Each side's exit is measured as dark
printing running right through a band inside the side. A short stub of track
beside a city printed close to the side -- the capsule of a green tile's two
slots -- has the white of the city at the inner end of the band, blurred in
over the few pixels a hex gets in a photo of the whole board, so those real
exits read weak, and a yellow tile with fewer exits won. Three changes put
that right. The band now slides a little along the track (any run of a sixth
of the way out that reaches within a fifth of the side counts); the exits an
option is expected to have are as its own drawing shows them, so a stub
expected weak isn't penalised for reading weak; and, as the user suggested,
track is looked for across each side as well: a line of samples from just
inside the side to just beyond it, dark all the way and standing out from
the side either way along it (so a border printed along the side doesn't
count), shows track running on into the next hex. That is only ever evidence
for an exit -- track may end at a bare hex -- and it counts as much as the
exits do. On the 2 October photo crossings read 0.62 where the two sides
really join (median) and 0.00 where neither has an exit.

**The cities as printed.** Measured on close-ups (I6's 15, Geneva, H13's 611)
the two slots of a city share a capsule -- the circles a third of the hex
across, their centres a third out from the middle, a white band between --
reaching four fifths of the way to the sides they point at; they had been
drawn smaller and touching. The three of 1844's 909 are bigger still, two
fifths out. Tokens are looked for in the same places, so that moved too. And
OO tile 66 puts the city on its run from side 0 to side 3 out towards the
corner between sides 4 and 5 (C20, 2 October), which the importer's table
now says.

**Colour.** A tile's colour is taken from the pixels about as bright as its
background, which on a brown tile under three big white circles was the
white: the brown counted as "too dark to be background" and the tile came
out grey. White -- the brightest, least coloured thing in the hex -- is now
left out of that, unless it is most of the hex (bare map, grey tiles). And a
game the app knows nothing of yet has nothing to measure its tiles' colours
on, so the colours it starts from were measured under some other light: the
tiles a photo reads clearly now measure them, and if that moves them much,
the photo is read again.

On the 2 October photo, read as a fresh game from the same placement, these
took the reading from 75 to 85 of 94 hexes right (all but one of the rest
flagged for a look: the Gotthard line, see Deferred) and the tokens from 16
to 24 of 28 cities. On the evening photo of 1 October, whose fit is most of
a hex out in places, they read 80 where the code before read 81.

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
- What the user set by hand stands. A photo replaces it only with an upgrade
  of it (yellow to green, green to brown, brown to grey), which is play moving
  on. A confident photo that shows anything else is kept as a suggestion:
  the hex is outlined in purple, a banner offers to review them, and the
  editor shows what the photo saw with a button to take it. A doubtful photo
  changes nothing, and in particular doesn't loosen the user's hold on the
  hex -- which is how, before, a doubtful reading followed by a confident one
  could quietly put back what the user had corrected. An upgrade of what they
  set is suggested on less (from 30%): a reader that expects a hex not to
  have changed scores a tile laid since below one left alone, and the grey
  tiles of the end of the 1844 game read right but short of sure, so none
  were offered.

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

The guide also draws the tiles the game already has on those hexes, at half
strength by default -- what stop-motion apps use for lining a shot up with the
last one (iStopMotion overlays at 50%; guidance for precise alignment runs
50-60%, 30-40% where the ghost competes with the live picture). A slider under
the preview changes it, and the setting is kept in `settings.json` beside the
saved games ([services/app_settings.dart](../../lib/services/app_settings.dart)).

## Tunnels (1844)

1844's tunnel companies drive tunnels through the mountain hexes
(`TUNNEL_HEXES` in tobymao's `entities.rb`), along the shapes of its tunnel
tiles X78 and X79: straight through, or a gentle bend. tobymao models a tunnel
as narrow track added to whatever is already on the hex, not a tile replacing
it -- which is how Gotthard can carry the Furka-Oberalp line and a tunnel
across it -- and the app does the same: `GameSession.tunnels` holds the two
sides each tunnel joins, the hex's content gains the narrow track, and routes
use it. They are drawn as the pieces are printed, a black band broken by white
dashes, and set or lifted in the hex editor's Tunnel row.

The piece is found by its dashes
([processing/tunnel_detector.dart](../../lib/processing/tunnel_detector.dart)):
along the run a tunnel takes, the photo goes dark, light, dark at the dash
spacing (0.28 of a hex on the 1844 pieces), and along no other run does it.
Each run a tunnel could take is scored on how well the light along it follows
an even on-off pattern; a tunnel is read where one run scores at least 1.8
times any other and half the hex's own contrast. On the real photos the piece
scored 2.2 times the next run; printed hexes without one, at most 1.4 times.
Tunnels follow the token rules: one the user set is never changed by a
photo, an uncertain one is flagged and open to correction.

## Mountain railways (1844)

1844's mountain railways put a revenue plate on one of the grey mountains
(`MOUNTAIN_HEXES` in `entities.rb`): plates XM1-XM3, each a row of four boxes
in the phase colours with what the mountain pays in each phase. tobymao models
a plate as a tile laid over the mountain; the app keeps it beside the hex
instead, like a tunnel -- `GameSession.mountains` holds which plate is where,
and the mountain's off-board revenue becomes the plate's
(`TileDefinition.withRevenueFrom`), so routes pay it. Mountains can be chosen
for close-ups, and the hex editor's Mountain railway row picks the plate, each
drawn as printed.

A photo can see a plate by its colours; which plate it is lies in the figures.
The detector
([processing/mountain_detector.dart](../../lib/processing/mountain_detector.dart))
looks for the boxes' colours. A mountain is printed grey and black, so a patch
of yellow, one of green and one of salmon side by side, left to right, at the
spacing of the boxes, is a plate; colour scattered elsewhere -- the edge of a
neighbouring tile, the map's own colours -- doesn't form the row. A plate found in a
photo is recorded as "some plate", ringed, and listed to check, for the user to
name; a plate the user named is never changed by a photo; and only a clear
photo of a bare mountain takes away a plate a photo found.

The figures are read by the platform's text recognizer -- Apple's Vision,
now on macOS as well as iOS (`TextRecognitionPlugin.swift` in each runner),
which also brings revenue reading to the Mac;
[processing/plate_reader.dart](../../lib/processing/plate_reader.dart)). The
row of boxes the detector found
is cut out of the photo through the fit, so it comes out straight whichever way
the camera was held, and read twice: as photographed, and as ink on white
(each pixel's brightest channel, stretched against the paper around it), since
the dark green box loses its figure otherwise. What matters as much as the
figures is which box each was read in: 10, 50 and 80 could be XM1 or XM3, but
50 in the third box and 80 in the fourth is only XM1. Vision places whole
words, not characters, so a figure's box is judged from where it falls in its
word ("(50(80)" spanning the right half of the strip is 50 in the third box and
80 in the fourth). Every figure read settles the plate; two or more that only
one plate has name it, flagged for checking. On the third round's photos that
reads all three plates in close-ups (two settled) and, surprisingly, all three
on a whole-board photo from the 1920-pixel webcam -- clear plates are about 11
pixels tall there. Single boxes on their own can't be read: Vision finds no
text in a strip with only one figure in it.

Glare matters more here than anywhere: the boxes are pale to start with. The
third round's close-ups showed why close-ups suffer most. In the close-ups of
F19 and G14 the lamp's reflection sat in the middle, right on the hex each was
taken for, so each plate was washed nearly white in its own close-up and sharp
at the edge of the other's. Two things follow. Each mountain measures its own
washout -- the middle of its weakest colour channel, about 120-165 under the
lamp alone, 177 and up where glare faded a plate -- and on a
washed-out mountain the colours are looked for more faintly and not finding
them counts as not knowing. And a close-up reads every mountain it shows in
full, not just the ones it was taken for. On the round's photos that finds
every plate except the two under their own close-up's glare, which read as
unknown, and no plate on any bare mountain.

## Glare

Photographs of a board under a lamp often have a patch of glare, and the
tiles, glossier than the board, suffer worst: a yellow tile under it comes out
nearly white, its track faint grey. On the first photos with glare, recognition
missed almost every tile under the patch and, worse, read some of them
confidently as bare map.

Two things did not work, and are worth knowing before trying again. Taking
the glare back out -- measuring the local ink and paper levels and mapping
them back to clean ones -- failed because ink isn't measurable per hex in a
photo of the whole board: a hex with only thin printing never shows true
black, so ink read 150-210 on plain hexes in glare-free photos and the
correction stretched faint hill shading into track. And no single correction
fits both board and tiles when the tiles reflect more. Stretching faint
printing further under glare found nothing extra and added a false tile.

What is done instead is to find the glare and be honest about it
(`BoardReader.measureGlare`). Glare is white light added on top, so it lifts
every colour channel, the weakest included; a lamp that is merely brighter in
one place lifts the colours it already has and leaves the weakest -- blue,
under a warm lamp -- low. So each beige or yellow hex's weakest channel is
compared with the photo's middle value, and smoothed over neighbours. On every
photo so far it picks out exactly the washed-out patch. Under glare, colour
counts for less, and "nothing here" is never taken as read where it would be
news: glare can hide a tile but can't put track where there is none. The hexes
are reported after reading, for close-ups from another angle -- along with any
mountain whose plate, if it has one, glare may have hidden.

At first glare in close-ups went unmeasured: the measure compared each hex
with the photo's middle, and in a close-up mostly covered by glare the middle
is glare too. Two things fix that. A hex whose weakest
channel is near the top of the range counts as washed out however the rest of
the photo looks. And the session remembers where glare fell on the last photo
of the whole board, and a close-up is read assuming at least most of it is
still there, since close-ups are taken under the same light. The other lesson
of those close-ups (see Mountain railways) is that glare follows the camera as
much as the lamp: it tends to sit in the middle of a close-up, which is where
the hex it was taken for is.

The session's colour profile is the part of the lighting that does stay the
same between photos: how bare map and each colour of tile photograph under
this game's light. The defaults were measured under one warm lamp, and the
first photos under daylight were far less saturated (plain map 5-10% against
20%). "Calibrate colours" in the board's menu measures them from a photo of
the whole board, from the hexes the game is sure of, leaving out any under
glare, and says which colours it couldn't measure and where the glare was.

## Station tokens

[processing/token_detector.dart](../../lib/processing/token_detector.dart)
looks in every city slot of every hex it reads confidently. A token is a disc
in the company's colour with its logo in the middle, so the slot's ring shows
the colour and its middle the logo. Colours are judged against the white of the
board nearby -- the brightest printing, which is the slots and revenue bubbles
-- which takes out the lamp: under warm light an empty slot is cream.

A tile's slots are plain white, so there either the colour or a logo means a
token. The printed map is harder: 1844's cities glow yellow in the middle,
Lucerne's holds a lake, and every home city is printed with its company's logo
on white, which looks just like a pale token. So on the map only the home
company's token was looked for, by its colour; anywhere else there it said it
couldn't tell, and nothing changed. Measured on the first real token (BLS's,
on a tile on Bern) and the printed cities around it, that rule got every one
right. 1889 prints each company's logo in its home circle so like its token
that no photo can tell them apart, so now nothing is read on the printed map,
and a home token is taken as down (below).

1889's double-sided tiles print their city circles on one side in a darker
shade of the tile, which reads as a token of that colour: Anan's (J11) was
taken for Tosa Electric's on the first 1889 board. A circle the colour of the
tile around it, only darker, now counts as empty unless something in its
middle stands out from its ring the way a logo does
(`TokenDetector._tileColouredCircle`). On that session's saved hex pictures
G4, G12 and F3 now read empty; J11 and I4 couldn't be judged from them (128
pixels, a revenue oval beside the circle), so a real 1889 session has to
confirm it.

Most token errors turn out to be where the slots are looked for, not what is
seen in them: a slot sampled a fifth of a hex off reads the tile beside it --
a tan "MOB" on a brown tile, a pale green "FNM" on a green one. Drawing the OO
tiles as printed and lining the grid up with the known hexes removed three of
the four false tokens on the evening photo of the board (25 cities right).
Lining each city's hex up on its own before reading its slots was tried and
dropped: a token darkens its slot, which pulls the match the wrong way, and it
broke a token it had read right. What would help next is finding the slots
themselves -- white or coloured discs of a known size -- rather than trusting
where the drawing says they are.

Whose token it is comes from colour, compared against each company's colour as
it photographs rather than tobymao's deeper screen colour, and from where it
is: companies printed in the same colour (1844's BLS and GB are both mustard)
can only be told apart by home. A token placed without being sure whose it is
is kept, ringed on the board, and listed as "to check"; a later photo may
change it, and setting it by hand settles it. Tokens the user set are never
changed by a photo.

Every circle of a city holds its own token (`GameSession.tokens` is kept by
circle, `GameSession.slotId`; games saved before put their one token per city
in its first circle). A photo is folded in city by city, though: a city's
circles are alike in play, and which end of a row of them comes first is
something a photo can't tell (the row looks the same turned end to end), so
a token the user put in one circle that a photo shows in the other is the
same token. Matched circle by circle, it had been added again in the other
circle, and the city held the company twice. Each is drawn in its circle where the tile prints it,
read from photos circle by circle, and set in the station editor a row per
circle. A company keeps a circle free in its home city until its home token
is down -- no company's starting token can be blocked -- so a token filling
the last free circle of another company's home is shown in red with why
(`GameSession.tokenProblems`): FNM on Altdorf's one circle before the
Gotthardbahn had started, say. As with a tile that can't belong, the app shows
what is on the board and says it is wrong rather than refusing it.

A company's first token goes in its home city, so one with tokens down and none
on its home hex has one of them on the wrong hex. Each of its tokens is shown
in red with why (`GameSession.awayFromHome`), the station editor says so, and so
does the route panel when that company is chosen -- its routes are worked out
from tokens that can't all be right. The check goes by hex rather than by city,
as a tile upgrade can renumber a hex's cities; a company with no home of its
own (1844's SBB, which takes over others' tokens) is never away from it. On the
2 October evening board, where the user set NOB's two tokens down at random to
try it, both are flagged: NOB's home is Zürich (D19).

A company's home token is taken as down (`GameSession.homeTokensOff` lists
the exceptions): it is laid when the company starts, and on 1889's board the
logo printed in the home circle can't be told from it. The station editor
says so for a home city, and setting its circle to None marks a company that
hasn't started yet. Counting a company's tokens, checking it isn't away from
home, and its routes all go by the board with its home token in. Games saved
before take each company with no token on the board as not started.

## Trains and routes

[processing/train_routes.dart](../../lib/processing/train_routes.dart) finds
the best runs for all of a company's trains together. Each route must take in
a city holding one of the company's tokens; no two of its trains may share
any track (each tile segment is identified, so two trains can both stop at a
city if they reach it by different track); and, as before, a route can end at
a full city or an off-board area but not run through either. Trains run as
the title says:

- **so many stops** (towns left out of the count for a `freeTowns` train);
- **so many hexes**, 1844's H trains -- tobymao counts a route's hexes as the
  hexes it crosses into plus one -- which can't visit red off-board areas;
- **an express**, any number of stops paid for its best few, one of them a
  city the company has a token in, and any red off-board areas besides, as
  tobymao picks them.

1844's game code adds three route rules (`RouteRules`): a stop that pays
nothing can't be visited (a mountain railway before its plate is down, Torino
in yellow); a route on tunnel track earns 10 more for every stop it is paid
for; and a route joining an east and a west off-board area, or north and
south, earns their bonuses too (`GameTitle.stopGroups` and `groupBonus`, read
from the printed areas' groups and bonus icons). A route's bonus is spelt out
when its "of it bonus" is tapped (`TrainRun.bonuses`): tunnel track at so much
a stop, and each pair of groups joined, with what each area pays. On the 2
October evening board, the MOB's 8E pays 560, 220 of it bonus: 80 for tunnel
track (10 for each of the 8 stops it is paid for) and 140 for joining east to
west (Innsbruck 90 and Dijon/Paris 50).

Track without a stop on it is separate tracks, not a junction. 1844's H11 is a
tight curve and a gentle one that share a side, and a route can't come in by
one and leave by the other, turning in the middle of the hex -- which the
MOB's 8E did, until this pass. So a route goes along a tile's track and then
across a hex side, by turns, and each piece -- one of a tile's tracks, or a
hex side crossed -- is used once in a route and once by a company's trains
(`TrackEdge.segments`): the side H11's two curves share is used by one of
them or the other, as are each of F9's four sides. Cities and towns are where
track joins.

The search enumerates half-routes out of each tokened city, joins pairs of
them into routes, keeps each train's best few hundred, and picks one route
per train by branch and bound. A company's trains can all prefer the same busy
stretch of track, so it also lets the trains choose in turn, each from what
the others have left, and keeps whichever is better. On the 1 October board
(45 tiles, 11 companies) it takes 0 to 12 ms a company, even for two 8E
expresses. `test/session_routes_test.dart` runs every company on a saved game.

[models/company_rules.dart](../../lib/models/company_rules.dart) holds the
checks, each in a sentence for the screens to show:

- the **phase**, the latest whose train anyone is known to hold or whose
  tiles are being laid;
- the **train limit** for the company's kind in that phase;
- **rusting**: a train can't be running alongside one whose purchase scrapped
  it -- its own, others in the same photo, or another company's;
- **tokens**: those on the board and on the charter must add up to what the
  company has, so a token missing from the board shows up;
- **certificates**: no more of a size than the company prints, and no more
  than 100% between the players;
- **dividends**: a player's share of the revenue, rounded down, or of half of
  it where the title allows paying half (none of the three does: 1854's
  minors pay half by their own rule, which isn't modelled).

The session's phase follows what is seen (`CompanyRules.laterPhase`): a tile
of a later colour on the board, or a train on a charter whose purchase
brought in a later colour, means the game has moved on (1844's OP tiles, laid
early by their own rule, don't count). After a photo of the board or of a
player's area, the app asks before moving to that phase -- a misread tile
shouldn't change what every off-board pays -- and "Not yet" holds for that
colour while the board is open. A tile or train the user sets by hand moves
it at once, with a note saying so.

A company without trains noted still gets the old single route of so many
stops.

## A player's area

[processing/play_area_reader.dart](../../lib/processing/play_area_reader.dart)
works from the lines of text Vision reads (`recognizeTextLines`, with where
each lies; ML Kit answers the same on Android) and the photo. Companies are
found by symbol (the logo's letters) or name, allowing a letter or two
misread, and each thing found goes with the nearest of them:

(The first charter photographed on the phone, FNM's, found nothing at all,
though Vision reads the same photo perfectly. ML Kit runs things printed in a
row into one line -- the logo's letters into the name beside them ("FNM
Ferrovie"), the token costs into "0 Fr. 40 Fr. 100 Fr. 100 Fr. 100 Fr.", two
train cards' numbers into "8E 6" -- and a name printed over two lines,
"Ferrovie" / "Nord Milano (H1)", matches no company line by line, so no
company was found and nothing else counted. Now Android cuts each line where
a gap between its words is well over a space, using ML Kit's word boxes, and
the reader tries each line with the one printed under it, takes a symbol
leading a line, and splits a run of costs or train names into each one. Read
merged that way, the phone's photo gives FNM, its 8E and 6 and both tokens
left. Not yet checked on the phone; if a charter still reads as nothing, the
lines read are written to the log, `adb logcat -s flutter`.)

- a **train** is a train's name from the title in large print -- larger than
  most text around it, which leaves out the charter's own table of trains --
  with lookalike letters folded (Vision read 1844's `3H` as Cyrillic `3н`);
- a **token place** is a cost printed with a currency (`40 Fr.`) that is one
  of the company's token costs, which leaves out a train card's price;
- a **certificate** is a percentage. Certificates are stacked to show each
  one's top edge, where its percentage is printed, so every edge read is a
  certificate and the large figure on the top card is that card again. A
  percentage is fitted to the company's certificate sizes: `5%` with its
  first digit under the card on top is GB's 25%, and `503` with its `%` read
  as a digit is 50%.

Whether a token place is filled is judged by comparing a charter's places
with each other: how far each one's inside is from the card around its
printed cost, in colour, leaving out its darkest quarter (the printed ring,
and the figure some empty places have printed in them). Tokens differ --
GB's is dark, FNM's silver with a dark rim -- so no one colour says "token";
but where a charter's places split clearly into two kinds, the kind further
from the card holds tokens (GB: 18 against 85; FNM: 8 and 8 against 32 and
48). Where they are all alike they are all empty if they look like the card.
The home token always leaves its place when a company starts, so if the
place costing nothing looks full the charter isn't laid out as expected and
nothing is said.

A **train card** whose number wasn't read -- a single figure on its own is
the hardest thing for Vision to read; it missed FNM's 4 -- still shows its
price, and where only one kind of train costs that (in 1844 every price is
different), the price says which. A card whose number was read shows its
price beside it too, so that one isn't counted twice.

**Certificate stripes** count the cards in a stack better than their edges'
small print can be read (Vision missed all three of FNM's 10% edges): each
card's edge carries one stripe for a single share or two for a double, in
some colour that isn't the card's white, from top to bottom. A band across
the stack at the top card's large figure crosses each card's stripes in
turn -- narrow columns that aren't card all the way down; the logo has white
in it at some heights, so its columns don't count -- and stripes a stripe's
width apart are one card's. The top card is its large figure; each one under
it a single or double share of the company's (GB: 50 + 25; FNM: 20 + 10 + 10
+ 10). Where there are no stripes, the edges are read as before.

**Charters differ a lot between titles**; so far this has seen 1844's (GB,
FNM, MOB) and 1889's (below). What comes from each title's data -- company names and
symbols, train names, token costs, certificate sizes -- should carry over.
What is calibrated on 1844 is where a token place sits relative to its
printed cost (centred 2.6 times the cost's height above it), the
certificates' edge reading (`DIVIDENDE`), and that stacks are fanned out
sideways with stripes on their edges. Where those don't fit, the reading
says less rather than guessing, and the review screen lets everything be
entered by hand. Charters
also print rules (1844's says `Limit 2`, and has a table of trains, prices and
rusting) that could stand in for a title without data; worth looking at once
other titles' charters have been photographed.

**1889's charters** -- Tosa Electric's and Uwajima Railroad's, on the iPhone
-- needed five things:

- the card's name isn't tobymao's: "Uwajima Railroad" against "Uwajima
  Railway", and letter by letter "Awa Railroad" is nearer. Names are also
  compared without the words companies share (railway, railroad, line,
  company, and anything in brackets), so "Uwajima" finds it;
- the first token place prints `FREE`, which is the place costing nothing;
- a place's cost is printed beside its ring, where the token covers it, so a
  place with a token isn't read. Tokens leave a charter from the left, so
  when the places read are the first of the company's costs, evenly spaced,
  the rest are further along the row, and are looked at as usual. (A place
  whose cost isn't printed at all, 1844's home place, isn't one of the
  first, and nothing is made up);
- a train card prints `RUSTED BY 4` under its number: the train is the one a
  4 scraps, counted where its number wasn't read nearby;
- certificates are fanned top to bottom, each showing a strip along its
  foot -- `2 SHARES 20%`, `1 SHARE 10%` -- with no large figure repeating the
  top card: where every percentage is by a SHARE, each is a card.

Both charters were photographed sideways, the card's long side down the
portrait frame, and Vision reads sideways text as tall, broken lines. Where
most lines of four letters or more come back taller than wide, the photo is
turned a quarter each way and read again (`PhotoPipeline.readPlayArea`), and
the reading kept is the one with the most charters upright -- trains and
places below the name -- then the most trains, places, tokens and
certificates. Read that way, Tosa Electric has three 2 trains, its places
free, 40 and 40 with one token left, and certificates of 20, 10 and 10%;
Uwajima has a 6 and a 4, one token left, and two 10% certificates
(`test/play_area_reader_test.dart` keeps both photos' lines).

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
is the single route of so many stops, for a company without trains noted: a
route can end at an off-board area but not run through it, and a company's
route can end at a city whose every circle holds another company's token but
not run through it (`StationNode.blocks`); a city with an open circle, or one
of the company's own tokens, lets it through. With trains, see Trains and
routes.

**Revenue** comes from tile and map data. Where a hex is doubtful, the station
editor can read the printed figure off that hex's stored picture using the
platform text recognizers (Apple Vision on iOS, ML Kit on Android) over the
existing method channel.

**Drawing the board** ([processing/tile_renderer.dart](../../lib/processing/tile_renderer.dart)).
Track into a place a route can only end at -- an off-board area, or 1844's
mountain railways -- is drawn as the board prints it, a long narrow triangle
pointing a little under halfway in, rather than a line to the middle: five
lines meeting in Pilatus's hex read as a junction to run through. A town
where three or more lines meet is a black dot ringed in white and bigger
than the track, as the board prints Brig and Altdorf (a plain dot was lost in
the junction), and on the board view a town's figure sits beside it rather
than over it. The same drawing makes the templates recognition matches; on
the data set (see Learning from corrections) it reads the same, one hex
better.

## Learning from corrections

Every time the user fixes a hex in the editor, the app keeps the deskewed
picture it read and what the hex turned out to hold, in
[services/training_log.dart](../../lib/services/training_log.dart) --
`<app documents>/training/labels.jsonl` and a folder of pictures beside it. A
line records the title and hex, the real tile and rotation, what recognition had
said and how sure it was, so a later look can tell the cases it got *wrong* from
the ones it merely doubted. Nothing is sent anywhere; it is a folder on the
device, there to be copied off.

This exists because it is the one kind of training data that cannot be
synthesised: real tiles, real board, real light, framed exactly as the
classifier sees them, and labelled by someone who was looking at the board. It
costs nothing to collect -- the pictures were already being saved -- and it
grows while the game is played rather than in a separate labelling session.

The question it answers is whether to replace the template matching with a
trained classifier. A net would learn the things templates can't be told about
(print variation between editions, wear, shadow, the fat matte ink real tiles
are printed with) and would not need every new title's artwork to be pixel
right. Against that: the shape term is only one of three, and the other two --
the legality-constrained candidate list and the "it probably hasn't changed"
prior -- are doing most of the work and would be kept either way; a net trained
on 1844 and 1854 would not obviously carry to a title whose tiles it had never
seen, whereas the templates come free from the imported data; and there is no
measured failure rate yet to improve on beyond the handful of hexes checked so
far.

So: collect first, decide later, and decide on numbers. When the log holds
enough corrections to say where recognition actually fails, the smallest useful
change is to keep the pipeline exactly as it is and swap only the shape term for
a small convolutional net over the 48x48 patch -- a few thousand weights,
trained offline, run in plain Dart. `tflite_flutter` is the thing to avoid: it
needs a hand-built `libtensorflowlite_c` on macOS and ships as a pod on iOS,
which would undo this project's CocoaPods-free iOS build for a model small
enough to write out as a list of doubles.

**The data set** (tenth pass). `dataset/` (not in git; see its README) gathers
every photo from both devices -- 83 from the webcam, 7 from the phone -- every
saved game and both devices' correction logs, and
[test/build_dataset_test.dart](../../test/build_dataset_test.dart) cuts labelled
hexes out of the whole-board photos whose board is known exactly: nine of them,
under three truths (the board before play, round 8's and round 9's), placed from
hand-picked hex centres where the detector can't, each placement drawn out to
check. Labels known to be wrong are put right or left out there, not in the
games: F9 is tile 70, not the 43 every desktop game had; D19's grey tile is
turned illegally on the board; one phone correction was itself corrected
later; and the old desktop game's 20 unchecked misreads aren't used. That
gives 943 labelled pictures -- 837 from photos, 106 corrections -- over 50
labels; but only 155 different things, (hex, label) pairs, 62 of them tiles:
mostly the same hexes in other light and from other angles.

Read fresh with nothing to go on, the app gets 92% of the photo pictures right
(webcam 96%, phone 89%): bare map 98%, yellow 94%, green and brown 85%, grey
62%, the purple Furka-Oberalp and Gotthard pieces 62%, heavy glare 83%; 95-99%
by photo, except the upside-down one (71%, paler than the rest) and the
90-degree one under glare (85%). That is the number for a trained classifier
to beat, and where to look first: grey tiles against the bare map, the purple
pieces (drawn unlike the physical ones, see Deferred), glare, and exposure.

Whether to train a net now has numbers. The set is big enough to measure with
and too narrow to learn from: 155 things, most tiles only ever on one hex, all
of them 1844's, and a net trained on it would learn those hexes. The shape of
a sensible first try is unchanged from below -- keep the pipeline, replace
the shape term -- with two additions: train on tiles drawn by `TileRenderer`
in every turn under made-up light, glare, blur, colour and perspective, then
fit to the real pictures, measuring photo by photo with each photo held out;
and predict what the matcher already measures -- background colour, which
sides track leaves by, what kind of stop -- rather than tile names, so it
carries to 1889 without retraining and `TileRules` still picks the legal
tile. Finding the grid is a poor first job for a net: it would need hundreds
of whole-board photos of several boards, and rough handles now snap.

(Until the fourth pass every record said recognition had read exactly what
the user then set: the editor sets the hex while the picture is still being
loaded, and what was read was taken after that. It is now taken first, and
for a hex the user had already set, what the latest photo suggested is what
counts as read. Records from before then can't say what was read.)

## Deferred

- Train rules beyond those above: 1854's minors' automatic half pay and its
  8Ox, 1889's private companies, other titles' route groupings. Unknown
  train names run as many stops as the number they start with.
- Money: player and company cash aren't tracked, by choice.
- The Gotthard line's five-hex piece is drawn as five purple hexes with
  full-width track, but the physical piece is grey with a thin line and its
  name printed along it, so it reads as the unopened printing (five hexes
  wrong on the 2 October photo; one tap on any of them sets all five).
- Finding the grid by itself in a photo taken at a steep angle (see Finding
  the grid): it needs the user's four handles, though they only have to be
  within about half a hex now. The handles could snap by themselves when let
  go.
- Telling which hex is which when the grid is found but the map placed one
  hex out (the 2 October evening photo).
- Charters and certificates of titles other than 1844 (see A player's area),
  and certificate stripes.
- Company logos. Companies, colours and homes are imported; a token away from
  home in a colour two companies share is left for the user to name.
- Tokens on printed cities other than the company's home; see Station tokens.
- Maps printed in two pieces (1854's local railways may be a separate inset on
  the physical board). The detector places one connected map; if a title's map is
  in two pieces, the second would need its own placement.
- Tile counts are imported but not used; "there are only two of tile 15 in the
  box" would be a good extra constraint on recognition.
- A line printed for later opening (1844's Gotthard tunnel) is drawn faintly,
  expected by recognition, and carries nothing for routes. The hex does take a
  tile, but only the one the game lays when the line opens -- the importer
  keeps those tiles, marked `laidByGame`, and the rules offer nothing else
  there.
- Android's text recognizer answers lines only, not where words are, so a
  plate is read there by the order of its figures, which says less.
- 1844's OO tiles 64, 65 and 68 haven't been photographed, and 66 only at an
  angle: they are drawn by the general rule, which 59 and 66 show isn't always
  the print's. An upright close-up of each would let the importer's table
  place their cities.
- 1889's private companies, beyond where the port tile may go: they change
  money and when tiles may be laid, not routes.
- 1889's charters and certificates. The token places are looked for where an
  1844 charter has them (`_ringAbove`, `_ringInside`); the first photo of an
  1889 charter will show whether they sit the same way.
- Icons and figures aren't drawn on the templates, so tiles printed alike
  but for them read alike: 1889's port tile and 58.
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
- `test/session_routes_test.dart` runs every company's trains on a saved
  game and prints the routes and how long each took:

  ```
  ROUTE_SESSION=~/session.json ROUTE_TRAINS=5,5 \
    flutter test test/session_routes_test.dart
  ```

  `PLAY_PHOTO=~/board_1790912047858.png flutter test
  test/play_area_reader_test.dart` checks the token places on the real photo
  of GB's charter.
- `test/photo_fit_test.dart` runs detection against a real photo that isn't
  checked in:

  ```
  BOARD_PHOTO=~/board.png BOARD_TITLE=1844 BOARD_PHOTO_OUT=/tmp/fit.png \
    flutter test test/photo_fit_test.dart
  ```

  It prints the fit, what was read (tiles, glare, tokens, tunnels and mountain
  railways), and writes the photo with the grid drawn over it, which is the
  quickest way to see what detection is doing. `test/closeup_fit_test.dart` does the same for a close-up, from the
  hex the app asked to be centred:

  ```
  CLOSEUP_PHOTO=~/closeup.png CLOSEUP_TARGET=H17 CLOSEUP_OUT=/tmp/closeup.png \
    flutter test test/closeup_fit_test.dart
  ```

## Notes for the next pass

- **The first 1889 session** (iPhone SE, 3 Oct, after the 1844 photos): 25
  photos, mostly of parts of the board, and three charters; the photos, the
  game and the corrections are in the data set (`dataset/`, with what each
  photo shows), though no 1889 photo is labelled yet -- the board changed all
  through the session. Open from it:
  - The port tile (437) and tile 58 still can't be told apart by recognition
    (see Reading the hexes); drawing revenue where each tile prints it would
    give the two different templates, at the cost of changing every
    template.
  - The darkened circles are taken for empty now (see Station tokens), which
    wants a real 1889 board to confirm: the session's saved pictures were too
    small to judge J11 and I4 by.
  - Kotohira (I4) takes only an H tile, and a plain city laid there by
    mistake was read as the H tile -- the only legal choice, so its revenue
    was right but the board wasn't. Where an illegal tile matches far better
    than any legal one, the reader could say so, as the tile editor does for
    a tile that can't belong.
  - The phase offer and the home-token default haven't been through a real
    session yet.

- **The second phone session** (the same board): a photo turned 90 degrees
  under heavy glare (`CAP5253572290537228500`), found right first time; one
  upside down from across the table (`CAP9068391036075008007`), which looked
  not found; and FNM's charter (`CAP188738177176395477`), which found nothing
  (see A player's area). Replayed with today's detector, the upside-down
  photo is placed the right way round, but its outlines sit on the printed
  lines at only 0.16 to 0.20 (placed by hand, 0.20) against the 0.6 the app
  wants before it says it found the board, so it says "Not sure" and asks for
  the handles. On a late game's board most outlines are under tiles: right
  placements of the phone's photos score 0.43 to 0.50, a wrong one 0.26, so
  that score no longer tells right from wrong well, and the "found" bar is
  rarely met. Something better is wanted there -- the tiles' colours where
  the game knows them, say.

- **The first phone sessions** (Nokia C32, Android 13, after round 9; the
  phone's clock reads June 2023, so its file and session times are off). The app is
  a debug build there, so its private files can be copied over USB:
  `adb exec-out run-as com.example.eighteen_xx_calculator tar cf - cache
  app_flutter/sessions app_flutter/training > nokia.tar`. Photos stay in
  `cache` as `CAP*.jpg` -- Android may clear them -- and sessions with their
  hex pictures in `app_flutter/sessions`. Four photos: two whole-board shots
  square on, a close-up of the L21/K22 corner and, in a second session in
  other light, the whole board at an angle. They are 1920 x 1080, as `ResolutionPreset.
  veryHigh` asks, cut 16:9 from a 4:3 sensor; the board itself is nearer 4:3,
  so a 4:3 picture would give each hex more pixels. The board is round 9's
  (F9 is 70 in the phone's game and 43 in round 9's; one of them is wrong).
  Against round 9's game, the automatic fit placed both square-on shots and
  they read 94 of 94 (one was 86 before the fit was settled); it finds
  nothing in the angled one, as with the webcam's angled photos, and from
  rough handles that snaps. Colour: the phone's colours are stronger -- yellow
  and green stand twice as far from the bare map as in the webcam's -- but
  under the lamp they varied more over the board, and the sharper picture
  shows more of the grey mountain art on bare hexes, so colour alone sorts
  66 and 67 of 82 hexes right in the square-on shots against the webcam's 76
  of 79. The angled shot, in the other light, does best: 75 of 80, with
  brown and grey clear of bare map. What the phone gains is sharpness, which finds the grid.

- **The ninth round** (2 October, 21:10-21:18, evening lamp), the last of
  1844: every grey tile down. A whole-board photo (`board_1790946641361`);
  close-ups of the three grey tiles not read -- H13 (`board_1790946785823`),
  D19 (`board_1790946865567`) and I4 (`board_1790946961369`); and NOB's and
  MOB's charters (`board_1790947091764`). The game is the eighth round's
  (`sessions/1844-1790916212645289`). Zürich's grey tile (D19) is turned
  illegally on the board and the user took the app's legal 910@0, so D19 is
  left out of tuning. Placed with the handles, the whole board reads 93 of
  94 hexes right, Zürich the odd one; the grey tiles had been read right but
  not offered (see Sessions and close-ups), and Lausanne's refused by the
  rules (see Reading the hexes). NOB's two tokens were set down at random to
  try the home check.

- **The eighth round** (2 October, early afternoon): a fresh game
  (`sessions/1844-1790916212645289`) started over the board as it stood, and
  photographed once from an angle (`board_1790916245408`), a close-up around
  Bern under heavy glare (`board_1790916355724`) and FNM's charter beside four
  certificates (`board_1790917100047`). The user's corrections to the fresh
  game are the truth for the board: where it and the old game disagreed (20
  hexes), the photo sided with the fresh one every time -- the old game had
  low-confidence reads that were never checked. `photo_fit_test.dart` now
  takes BOARD_TRUTH (which hexes were read wrong, each option's score in
  parts), BOARD_POINTS (place the map from hand-picked hex centres, as the
  align screen's handles do), BOARD_HINTS, BOARD_COMPARE and BOARD_PROFILE.

- **The first photo of a player's area** (2 October, `board_1790912047858`):
  GB's charter under glare, its one token left (the other on G18), its 3H
  and 2H, and two certificates stacked, 50% on 25%. Read right: GB, both
  trains, both token places (one filled) and both certificates. The live
  session had no GB token on G18, which the token count now points out.

- **The fourth round of photos** (1 October, evening): a whole-board photo
  that had to be placed by hand (now placed automatically from the session's
  tiles), close-ups of C12 (fitted two-thirds of a hex out, now lined up by
  its tiles), G8, I6, I10 and twice around L21, and eleven tokens set or
  corrected by hand. Still weak: the false token on Lausanne's second city
  (I4, tile 901), and Chur (G26), where even the lined-up grid is half a hex
  off the tile -- both slots sampled on tile; see Station tokens.
- **The third round of photos** (1 October, early afternoon, same lamp):
  brown tiles, three mountain railway plates, a second tunnel and a token on
  D15, in five whole-board photos and five close-ups. Two whole-board photos
  had come out as a grid squashed in a corner, and the browns weren't
  recognised; both are fixed above. What is still weak: under the close-ups'
  glare some tiles come out flagged rather than read -- H13's 611 runs a close
  second to 915, F7's 57 a close second to 15 -- and a plate under glare isn't
  seen at all. Glare is the limit on this board, and a shot from another angle
  is the cure the app can only suggest.
- **The second round of photos** (1 October, late morning, daylight and a
  lamp): six more tiles, the Gotthard tunnel piece, and heavy glare over
  F11-H13. Against the saved game, the whole-board photo now keeps every
  hand-set tile, finds the tunnel (100%), confirms the new tiles outside the
  glare and reports the 18 hexes under it instead of misreading them. As a
  fresh game it still misreads the green tiles at Locarno and Bellinzona and
  Como's 14 -- outside the glare, all flagged as doubtful -- which is where
  to look next.
- **The first photos of a game in progress** (1 October, webcam, warm lamp):
  a whole-board photo with six tiles, the tunnel piece and BLS's token on
  Bern, and close-ups of Bern and Andermatt. After this pass the whole-board
  photo reads all eleven laid tiles and the token, with only the green tile
  flagged (at 59.8%); the close-ups read every hex they cover correctly, the
  green tile again just short of sure. Three problems in the app itself came
  out of them, beyond recognition: taps on the drawn board
  only reached the part of the map inside the window (the board was sized by
  the window for hit testing and painted in full), the tile editor's Apply
  button was below the bottom of a Mac's default window, and the align screen
  offered no way to size the grid or get it back on screen. Widget tests now
  run at the Mac's 800 x 600.
- Don't run `dart format` over files here: the code isn't in the formatter's
  current style, and one run rewrites every line of a file.
- **Recognition has now been checked against real tiles, on two photos of the
  same three hexes.** Both read all three correctly (58, 9 and 7, each the
  right way round); confidence runs from 30% to 82%, so some come out flagged
  for a look rather than taken as read. A whole-board photo of the same board
  before the game reads all 91 tile-taking hexes as bare, four flagged. That is
  one board, one camera and one set of lighting: keep checking.
  `TileClassifier._shapeScale`, `_stepPenalty`, `_exitWeight` and
  `_marginScale`, and `TileReading.reliableConfidence`, are the knobs, and the
  per-hex pictures the session saves are the evidence.
- Five things made real tiles read as bare map, all found by running photos
  from real sessions through the pipeline: the line filter was built for
  whole-board photos and barely saw a close-up's thicker outlines, so the grid
  settled a fraction of a hex out; discounting "coloured" darkness to keep
  lakes out also deleted the track, which is warm brown in a photo; the prior
  that a hex probably hasn't changed was applied even to hexes the app had
  never seen; curves were drawn bending through the hex centre rather than as
  arcs meeting the sides square on; and thin lines were compared pixel for
  pixel, which favours bare map over a slightly misplaced tile.
- The weight on the sides feature (`_exitWeight`) is the sharpest knob there
  is. At 2.4 the close-ups read confidently but two printed cities on the
  whole-board photo turn into city tiles; at 1.6 nothing is false but the real
  tiles come out flagged. It sits at 2.0.
- Every `Isolate.run` lives in `services/photo_pipeline.dart`. A closure written
  inside a `State` method shares its captured context with the closures around
  it, so a neighbouring `setState` drags the widget tree and the framework's
  zone into the isolate message and it fails with "object is unsendable" --
  which the align screen then showed as a wall of text. Keep the heavy work
  behind the pipeline, and keep error messages short enough to fit on screen.
- The tile editor's controls are in a `Wrap`, not a `Row`: on a phone the
  pictures fill the width and the turn control has to drop below them rather
  than be squeezed off the edge.
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

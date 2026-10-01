# Recognition & Route Plotting

Status: fifth pass. The app knows the title it is looking at, finds the hex
grid in a photo by itself and corrects the camera's angle, keeps a game session
between photos, and asks for close-ups of the hexes it isn't sure about. It has
been through a real game's first rounds: tiles up to brown, 1844's five-hex
Furka-Oberalp piece, station tokens, tunnels, mountain railways, and photos
taken under glare. Train rules are still the one big thing missing (see
Deferred).

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
and 17. (1854 builds its six local railways in code from three plain lists;
the importer reads the lists.)

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

**When detection fails anyway**, the align screen starts from the map laid over
the middle of the photo rather than from nothing, or from a wrong fit whose
handles are off screen. The grid moves by dragging, sizes by pinching (touch
or trackpad), scrolling or buttons, turns a quarter at a time, and "Fit to the
photo" puts it back over the photo whenever it gets lost.

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
  could quietly put back what the user had corrected.

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

A photo can say a plate is there but not which one: the figures are what
differ, and a whole-board photo is too small to read them. So the detector
([processing/mountain_detector.dart](../../lib/processing/mountain_detector.dart))
looks for the boxes' colours. A mountain is printed grey and black, so a patch
of yellow, one of green and one of salmon side by side, left to right, at the
spacing of the boxes, is a plate; colour scattered elsewhere -- the edge of a
neighbouring tile, the map's own colours -- doesn't form the row. A plate found in a
photo is recorded as "some plate", ringed, and listed to check, for the user to
name; a plate the user named is never changed by a photo; and only a clear
photo of a bare mountain takes away a plate a photo found.

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
company's token is looked for, by its colour; anywhere else there it says it
can't tell, and nothing changes. Measured on the first real token (BLS's, on a
tile on Bern) and the printed cities around it, that rule gets every one right.

Whose token it is comes from colour, compared against each company's colour as
it photographs rather than tobymao's deeper screen colour, and from where it
is: companies printed in the same colour (1844's BLS and GB are both mustard)
can only be told apart by home. A token placed without being sure whose it is
is kept, ringed on the board, and listed as "to check"; a later photo may
change it, and setting it by hand settles it. Tokens the user set are never
changed by a photo.

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

## Deferred

- Real train rules: train types, "+" trains, E/D trains, city slot availability,
  token requirements, route groupings. `maxStops` is the placeholder.
- Company logos. Companies, colours and homes are imported; a token away from
  home in a colour two companies share is left for the user to name.
- One token per city: a two-slot city with two companies' tokens records the
  first. `GameSession.tokens` would need a list per station.
- Tokens on printed cities other than the company's home; see Station tokens.
- Titles whose maps are flat-top rather than pointy-top; the importer refuses
  them rather than importing something wrong.
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
- Which mountain railway plate is on a mountain. The photo only says there
  is one; the user names it. Apple's Vision text recognizer, already used for
  revenue on iOS, reads the four figures off a plate in a clear close-up (10,
  40, 50, 60 is XM2) but only part of them on a softer one, and nothing under
  glare, so a macOS port of `TextRecognitionPlugin` could suggest the plate,
  not settle it.
- Two cities printed on one hex without a `loc:` (1844's OO hexes) are drawn
  on a 30-degree line; the board prints Fribourg and Romont one above the
  other. Recognition of OO tiles and tokens on them will suffer until the
  layout matches.
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

  It prints the fit, what was read (tiles, glare, tokens, tunnels and mountain
  railways), and writes the photo with the grid drawn over it, which is the
  quickest way to see what detection is doing. `test/closeup_fit_test.dart` does the same for a close-up, from the
  hex the app asked to be centred:

  ```
  CLOSEUP_PHOTO=~/closeup.png CLOSEUP_TARGET=H17 CLOSEUP_OUT=/tmp/closeup.png \
    flutter test test/closeup_fit_test.dart
  ```

## Notes for the next pass

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

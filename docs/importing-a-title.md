# Importing a title

A title's data comes from [tobymao/18xx](https://github.com/tobymao/18xx),
the engine behind 18xx.games (MIT licensed). One command brings it into the
app; what the data doesn't carry -- rules written in the game's code, and
how your copy of the game is printed -- is kept by hand, and this note says
where.

## In short

From the repository's root:

```
dart run tool/import_tobymao_title.dart 18Chesapeake
flutter test test/every_title_test.dart
flutter analyze
```

The first line writes `lib/titles/title_18_chesapeake.dart`, adds it to
`lib/titles/titles.dart` (which `GameTitle.all` is built from, so the title
is in the app's list straight away) and prints a report. Go through the
report: each item says what to check or which code to change, using the
sections below. Then run the whole suite.

Name the title as 18xx.games does (`1880`, `18Chesapeake`, `1822MX`) or as
its folder in tobymao is named (`g_18_chesapeake`); case, spaces and
underscores don't matter. `--list` lists every title tobymao has.

| Option | What it does |
| --- | --- |
| `--dry-run` | Writes nothing; prints the report. A quick look at a title before importing it. |
| `--out <dir>` | Writes the title file into `<dir>` instead, leaving `lib/titles` alone: to see what importing a title again would change (`diff lib/titles/title_1880.dart <dir>/title_1880.dart`). |
| `--from <dir>` | Reads the files from a local clone of tobymao/18xx (`git clone --depth 1 https://github.com/tobymao/18xx`), or from a folder holding one title's `.rb` files and `config/tile.rb`'s `tile.rb`, rather than from GitHub. |
| `--list` | Lists tobymao's titles. |
| `--registry` | Only rewrites `lib/titles/titles.dart`, from the title files in `lib/titles` (after deleting one, say). |

## What the import does

It finds the title's folder under `lib/engine/game`, fetches `map.rb`,
`tiles.rb`, `meta.rb`, `entities.rb`, `game.rb`, `trains.rb`, `phases.rb`,
`market.rb`, `step/dividend.rb` and `step/route.rb`, and the shared
`config/tile.rb`. A title
that is a variant of another (`class Game < G18Chesapeake::Game`; 1807 is one
of 1867) takes whatever it doesn't define from that one, as Ruby would. The
Ruby files are read for their constants; nothing is executed, so only
literal data comes across.

What the app gets from that alone:

- every hex on the map, with what is printed on it (cities, towns,
  off-boards with revenue by phase, track, labels, impassable borders) and
  its place name; flat- or pointy-topped;
- the tiles in the box, with their counts (a tile printed exactly like one
  already listed is skipped: two identical drawings always tie in
  recognition);
- the companies whose tokens go on the board: token colour, home hex and
  city, kind (`minor` matters to the app), token costs, certificates;
- the trains -- how far each runs, which stops count and pay, any multiplier,
  price, what scraps it -- and the phases, with their train limits and tile
  colours;
- the stock market's cells, and whether prices move on a grid, a hex market
  or a single row;
- 1844's tunnel and mountain-railway lists.

The title's id is its tobymao module name without the G (`G1880` is
`1880`). Don't change an id once a title is in use: saved games, the data
set and the hand-kept rules below all refer to it. The name shown in the
app is 18xx.games' (`GAME_TITLE`), or the id.

The title file is generated: don't edit it by hand. Fix the importer, or one
of its two tables (below), and import again.

## What the report means

An example, 1880's, shortened:

```
The title:
  - 1880 (g_1880), China, by Helmut Ohley, Leonhard Orgler
  - pointy-topped map: 121 hexes, 57 tiles, 21 companies, 12 trains, 11 phases, grid market
  - lib/models/game_title.dart already keeps rules for it in _marketRules
Tiles and hexes:
  - stub in 4: G7, F10, F6, E9 -- printing the app doesn't draw, ...
  - 15 hexes and tiles have two or more cities placed by tobymao's rule ...: F8, I9, ...
Trains, as the app will run them:
  - 2+2: up to 2 towns free
  - 6E: an express, paid for its best 6 stops
Rules in the game's code (game.rb, step/), which the app keeps by hand:
  - routes: revenue_for, revenue_str, revenue_stops, stop_type -- ...
  - minors keep what they earn (g_1880/step/dividend.rb): MarketRules(minorPayout: 0) in _marketRules
```

It looks for things by name -- the methods a title's `game.rb` defines, the
modules its dividend step includes, the parts of its tile code -- so it says
where to look, not what the rule is. Read the Ruby it points at before
writing anything. A line that says a constant "isn't a literal this tool can
read" means data is missing from the import: see
[In the importer](#2-in-the-importer).

## Code an import may need

Roughly in the order a new title needs them. Every table below is keyed by
the title's id.

### 1. Rules kept by hand, in `lib/models/game_title.dart`

| Table | When | Example |
| --- | --- | --- |
| `_marketRules` | A payout moves the share price other than one space right (`share_price_change` or `change_share_price` in `step/dividend.rb`); withholding moves it more than one space left; minors don't pay their owners everything (`MinorHalfPay`: `minorPayout: 0.5`; `MinorWithold`: `0`); some kinds of company can't move into cells with a letter. | 1807: `MarketRules(payoutMoves: [(1.0, 1)], minorPayout: 0.5)`; 1844: `barred: {'t': {'regional'}}`; 1880: `minorPayout: 0` |
| `_halfPay` | A company may pay out half (`HalfPay`, or `half` in `DIVIDEND_TYPES`). Shows Full/Half on the route panel. | 1807 (1867's step) |
| `_routeRules` | The game's code changes what a route pays or where it may stop, in one of the ways `RouteRules` knows: no stops that pay nothing, a bonus per stop on narrow track, a bonus for joining two groups of off-boards. | 1844 |
| `_hexTrains` | Some trains count hexes rather than stops (`hex_train?`). | 1844's H trains |
| `_specialUpgrades` | A printed hex takes tiles the usual rule (same cities and towns) wouldn't allow (`upgrades_to?`). | 1844's Aarau (D15) |
| `_tilesOnlyOn` | A tile only a private company lays, and only on certain hexes. The report lists every company that lays tiles on given hexes; most lay ordinary tiles, which don't belong here. | 1889's port, 437 |
| `_tileStyles`, `_doubleSided` | How your copy's tiles print their stops, and whether they're double-sided. See [Against your copy](#8-against-your-copy-of-the-game). | 1889 |

`payoutMoves` is a list of (multiple of the share price, spaces) pairs: a
payout of at least the multiple moves the price so many spaces, the largest
multiple reached counting, and a payout below the first doesn't move it. So
1846's rule -- below half the price, one left; at least the price, one
right; twice, two; three times, three -- is
`[(0.0, -1), (0.5, 0), (1.0, 1), (2.0, 2), (3.0, 3)]`. Its "three only from
165 up" doesn't fit, and would need `MarketRules` changed
(`lib/models/stock_market.dart`); so would anything else that isn't a
function of the payout and the price.

A route rule `RouteRules` doesn't know (1880's Trans-Siberian bonus and
ferries, 1846's east-west runs) needs a field in `RouteRules` and code in
`TrainRouter` (`lib/processing/train_routes.dart`): add what it earns where
a route's bonus is added up (`_route`), explain it in `_bonuses` so the
route panel can show it, and raise `_bonusCap` by the most it can add --
the search drops routes whose bound can't make the cut, so a bonus left out
of the cap is a bonus never found. Where a stop may be visited at all is
`_canVisit`; what it pays a train, `_Spec.earns`.

Earnings that aren't a route's (1880's stock-market bonus, which its route
step adds to the run by where the share value sits) belong where the app
works out what a company earns: the end-of-game rounds (`EndGame`,
`lib/models/end_game.dart`) and the route panel
(`lib/screens/session_board.dart`).

### 2. In the importer

`tool/import_tobymao_title.dart` keeps two tables, and is where data that
tobymao keeps in some other form gets read.

- **`_printedCityLocs`**: where your copy prints the cities of a hex or tile
  whose data gives no places for them. tobymao spreads them by a rule of its
  own; the print often differs, and recognition compares photos with the
  print. The report lists every hex and tile with two or more cities placed
  by that rule. Give a `loc` per city, in order: a side number, or a half
  number for the corner between two sides (sides count clockwise from the
  south-west on a pointy-topped hex, from the bottom on a flat-topped one).
  Then import again.
- **`_marketFixes`**: a cell tobymao has mistyped (the report points out a
  price lower than the one before it in its row). Give the cell as tobymao
  has it and as it should be; the import warns if the fix stops applying.
- **`RubyConstants`**: the reader for Ruby literals. When the report says a
  constant isn't readable, teach it the form (it learnt quoted symbols,
  `:'#FF0000'`, for 1846's colours) -- or, where the data is built in code,
  read the parts as the import does 1854's local railways from three plain
  lists.

### 3. Tile code the app doesn't read: `lib/models/tile_definition.dart`

`TileDefinition.parseDsl` reads cities, towns, off-boards, paths, labels,
impassable borders and icons. The report lists anything else a title's tiles
and hexes use, and `test/every_title_test.dart` fails on the one that
breaks the board outright:

- **`junction`, `halt`, `pass`** are nodes, which paths name by number
  (`b:_0`) as they do stops. The parser doesn't count them, so track to the
  stops after one goes to the wrong stop, or to none ("has track to stop 0
  of 0"). The standard junction tiles 80-83 and 544-546
  (`junction;path=a:0,b:_0;path=a:1,b:_0;path=a:2,b:_0`) are the common
  case: 1817 and the 1822 family use them. The fix: number every node as
  tobymao does, and turn a junction's paths into track joining each pair of
  its sides (a junction joins any two). A halt (a small stop) or a pass
  would also want a `StationKind`.
- **`visit_cost`, `route`** on a stop (a stop that doesn't count towards a
  train's distance, one routes may not use): `train_routes.dart`.
- **`lanes`, `a_lane`, `b_lane`** (parallel tracks, read as one) and
  **`track:dual`, `track:thin`** (read as standard gauge).
- **`stub`, `partition`, `stripes`, `frame`**: printing the app doesn't draw
  (`lib/processing/tile_renderer.dart`), so recognition compares photos with
  a drawing that lacks it. Harmless to routes.

### 4. Trains

`TrainData` (`lib/titles/title_data.dart`) carries what the import reads
from a train's distance: so many stops; towns free (all, or up to an
allowance); towns paying nothing; only some kinds of stop visited or paid;
an express's best few paid; a multiplier. The report says how the app will
run each train that isn't plain. A train beyond that -- one counting a kind
of stop the app doesn't have, or paid by its own rule in the game's code --
needs a field in `TrainData` and `TrainType` (`lib/models/game_title.dart`),
reading in the import's `addTrain`, and running in `train_routes.dart`.

### 5. The stock market: `lib/models/stock_market.dart`

Prices move along a grid's rows (a row's end leading up), a hex market's
diagonals, or a single row. The end-of-game table only moves prices for
payouts and withholding; sold-out rises and selling aren't followed. A
market that moves some other way needs `StockMarket` taught it.

### 6. The end of the game: `lib/models/end_game.dart`

Players are worth their cash and shares at the market. Loans, bonds and the
like (`player_value`, `init_loans` in the report) aren't counted; neither is
what a closing minor hands its owner (1880's pay over a fifth of their
cash). Shares that come in other sizes, or change size (1817's companies of
2, 5 and 10 shares), are handled by each company's stake, the "% each"
column.

### 7. Companies

- A company with more than one home: only the first is imported
  (`CompanyData.home`).
- One with no home on the map starts wherever its player puts it: nothing
  to do.
- `minor` companies hold no place on the stock market (the market reader
  doesn't look for their tokens, and the end of the game moves no price for
  them), and pay their owners as `MarketRules.minorPayout` says.
- Token colours are 18xx.games' (in the title file). There is no way yet to
  give your copy's colours where they differ: that would be a table in
  `game_title.dart` applied in `GameTitle.fromData`.
- Charters and certificates are read by a reader tried on 1844's and 1889's
  only (`lib/processing/play_area_reader.dart`).

### 8. Against your copy of the game

None of this is in tobymao's data, and recognition depends on it:

- **The board.** Does it print hex outlines? Grid matching leans on them;
  1889's board prints none, so its photos need the handles, and the align
  screen names the hexes to drag. A board in two pieces isn't supported.
- **The tiles.** Double-sided (`_doubleSided`)? Towns as dots or bars, and
  how big the circles of two- and three-city tiles are (`_tileStyles`,
  `TileStyle`)? Compare the tile editor's pictures with the real tiles.
- **Cities' places** on the hexes and tiles the report lists
  (`_printedCityLocs`).
- **Token colours**, against 18xx.games'.
- **The first session**: photograph the board empty first, so the app learns
  how each hex looks bare (the mountains, the fold).
- **The stock market and charters**: photograph them once, and keep the
  photos in the data set (`dataset/README.md`).

### 9. Tests

- `test/every_title_test.dart` runs over every title by itself: hexes in
  their own places, track that leads somewhere, tiles in known colours,
  homes on the map, trains and phases that refer to trains the title has,
  market cells with prices.
- Pin a few hexes to your printed board in `test/title_map_test.dart`, as
  1844's and 1889's are there: a hex's neighbours, which side faces where.
  tobymao's side numbering is quiet but ruinous to get wrong.
- Give each hand-kept rule a test beside its kind: `end_game_test.dart`,
  `stock_market_test.dart`, `train_routes_test.dart`.
- Then `flutter test` and `flutter analyze`.

## When it goes wrong

- **GitHub limits requests** (60 an hour to its API, which lists the
  titles): wait, or use `--from` with a clone.
- **"No map.rb found" / "Nothing found"**: the title keeps its map
  somewhere the import doesn't look; read its folder.
- **A layout other than pointy or flat**: not supported.
- **A title imported by mistake**: delete its file from `lib/titles`, then
  `--registry`.

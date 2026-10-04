# Resuming with 1880

Written on 4 October 2026, when 1889 was packed up, for whoever picks the
project up next to test it on 1880: China. The plan doc
(`docs/plans/recognition-and-route-plotting.md`) has the whole story; this
is where to start.

## Where things stand

- **Titles**: 1807, 1844, 1854, 1880 and 1889. 1844 was played through one
  whole game (1-2 October). 1889 had five sessions on 3-4 October (two on
  the iPhone, two on the Mac's webcam, one on the Nokia C32) and is done.
  1880 and 1807 were imported on 4 October and have never met a real board.
- **Last commit**: `eb7166f` ("1889 testing", 4 Oct). Work after it, unless
  committed since: the title importer's report, variants and title list
  (`docs/importing-a-title.md`), `test/every_title_test.dart`, 1807's half
  pay, and these notes. Run `git status` first.
- **The data set** (`dataset/`, not in git, ~675 MB with its Hugging Face
  package): 1,456 labelled hex pictures, 1,037 of 1844 and 419 of 1889. Its
  README says what is there and how to add to it. Nothing has been uploaded
  anywhere.
- **Checks**: `flutter analyze` clean; `flutter test` green (the tests gated
  on `DATASET_DIR` and other photo variables skip without them).

## Picking it up

1. `git status`, `flutter analyze`, `flutter test`.
2. Install a fresh build on the device the session will use
   (`flutter devices`, then `flutter run -d <id>`, or a release build). The
   app is `eighteen_scanner` in `pubspec.yaml`; the bundle id is still
   `com.example.eighteenXxCalculator` (iOS, macOS) and the Android one
   `com.example.eighteen_xx_calculator`.
3. Pick 1880 in the app and start a game **before anything is on the
   board**: the first whole-board photo of a title's empty board is what
   the app compares every later photo with (it is kept for the title, so it
   only has to be done once).

## 1880 in the app

From tobymao's data (`lib/titles/title_1880.dart`): 121 hexes, 57 tiles,
14 companies and the 7 foreign investors (minors, grey tokens), 12 trains,
11 phases, a grid stock market of 9 rows. By hand:

- the "2+2", "3+3" and "4+4" trains run so many cities and up to so many
  towns besides;
- 6E and 8E are expresses, paid for their best 6 or 8 stops, one of them a
  city with the company's token;
- the foreign investors keep what they earn (`MarketRules(minorPayout: 0)`).

Not modelled, from tobymao's 1880 code (`game.rb`, `step/`; the import's
report points at them):

- **The stock-market bonus**, the one that matters most at the end of the
  game: a company whose share value sits in one of the market's coloured
  cells earns more every operating round, on top of its routes -- 50 in a
  `B` cell, 100 in `W`, 150 in `X`, 200 in `Y`, 400 in `Z` ("+5 bonus per
  share" and so on; tobymao adds it to the run in `step/route.rb`). The
  route panel and the end-of-game table leave it out, so a company high on
  the market is short every round, more as its value climbs. A bonus by
  cell letter in `MarketRules`, added to what a company earns in `EndGame`
  (round by round, as the value moves) and shown on the route panel, would
  cover it. Worth doing before the game's end is worked out.
- **Route bonuses and costs**: a route over a ferry (F12, F14, J16) pays 10
  less a ferry unless the company's president owns the ferry company (P2);
  one stopping at Taiwan (N16) pays 20 more if the president owns P3; one
  that runs to both Russia (A3) and Vladivostok (A15) pays 50 more (the
  Trans-Siberian bonus). Each wants a `RouteRules` field and code in
  `TrainRouter` (see `docs/importing-a-title.md`, section 1); the two that
  depend on who owns a private company need the president's privates asked
  for, as the app doesn't track them.
- **Blue hexes count as towns** (`stop_type`): Taiwan and Haikou (Q13) are
  off-boards to the app, so a "+" train counts them against its cities
  rather than its towns.
- **The communist takeover**: from the first 4 train until the first 6,
  share prices don't move with dividends. The game ends long after, so the
  end-of-game table isn't touched by it.
- **The fifth of its cash** a foreign investor hands its owner when the
  game ends: company cash isn't tracked.
- Building permits, the Rocket, and the other private companies: turn and
  money rules the app doesn't follow.

To check against the board and pieces, the first time:

- **Does the board print hex outlines?** 1844's does and grid matching finds
  it by itself; 1889's doesn't, and needed the handles every time.
- **Home tokens** are taken as down for every title, because 1889 prints
  each company's logo in its home city's circle. If 1880's board doesn't,
  every company that hasn't started would show a token at home (four of
  them in Beijing, F8) until cleared: make that a rule per title then.
- **Where the cities sit** on F8 (Beijing, four cities), I9, H8, N4, D12,
  F4, N12 and tiles 235, 8860-8865 and 8886: tobymao places them by its own
  rule. Where the print differs, give the places in `_printedCityLocs`
  (`tool/import_tobymao_title.dart`) and import again.
- **The tiles**: double-sided, as 1889's were? How are towns and the circles
  of two-city tiles drawn (`_tileStyles`)? Track stubs are printed on G7,
  F10, F6 and E9, which the app doesn't draw.
- **Token colours** against tobymao's (in the title file): 1889's TR, 1844's
  NOB, JS and GB were all darker or another shade than 18xx.games'.
- **Charters and certificates**: the play-area reader has only seen 1844's
  and 1889's. Expect to extend it, and keep it from fitting one title (see
  A player's area in the plan doc).
- **The stock market**: one photo of it with the share values known adds a
  case to `test/market_reader_test.dart`, as 1889's did.

## A first session

- Whole board, square on, before play; then again as tiles go down, from a
  high angle and from where a player sits (both matter: real players won't
  stand over the board).
- Close-ups where the app asks for them; note anything it reads wrong, and
  correct it in the app -- corrections land in the device's training log
  and become labels.
- A player's area or two: charters with trains and tokens, certificates.
- The stock market, with the share values written down.
- Run a company's routes once 2+2 or 3+3 trains are about, and check them
  by hand.
- At the end, with the board still standing: a game reconciled hex by hex
  is the truth for every photo taken of that board.

## After the session

- **Files off the devices** (photos, saved games, training logs):
  - Mac webcam: `~/Library/Containers/com.example.eighteenXxCalculator/Data/tmp/board_*.png`,
    games in `.../Data/Documents/sessions/`, logs in `.../Data/Documents/training/`.
  - Nokia C32 (debug build; its clock reads June 2023):
    `~/Library/Android/sdk/platform-tools/adb exec-out run-as com.example.eighteen_xx_calculator tar cf - cache app_flutter/sessions app_flutter/training > nokia.tar`.
    Don't name a folder that doesn't exist: the error corrupts the tar.
  - iPhone SE (development build; unlock it first):
    `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.example.eighteenXxCalculator --source Documents`
    (and `--source tmp` for the photos). Copy the app's own container only.
- **Into the data set**: photos into `dataset/photos/<device>/`, a row each
  in `photos.csv`, the games under `games/`, the reconciled board as a
  truth under `truth/` with `"title": "1880"`, and the photos and games in
  `manifest.json` (hand-picked hex centres where the detector can't place a
  photo). Rebuild with
  `DATASET_DIR=$PWD/dataset flutter test test/build_dataset_test.dart`, look
  at `fits/`, and measure grid matching with
  `DATASET_DIR=$PWD/dataset flutter test test/placement_benchmark_test.dart`.
  Then `.venv/bin/python tool/package_dataset.py` to bring `dataset/hf/` up
  to date.
- **Replaying a photo** against today's code: `test/photo_fit_test.dart`
  (`BOARD_PHOTO`, `BOARD_TITLE=1880`, `BOARD_POINTS`, `BOARD_TRUTH`) and
  `test/closeup_fit_test.dart`; see Verifying in the plan doc.

## Still open

Kept on 4 October, whatever the next tests show:

- Grid matching away from ideal photos: steep and oblique views (none of
  1889's six was placed), a whole board found but registered a hex out
  (both of 1889's square-on boards, with nothing known), snapping on a
  board that prints no grid, the "found" score on a late game's board,
  close-ups at the map's edge.
- A recognizer learned from the data set, for glare and angles.
- 1889's brown tiles read worst once placed (32 of 58).
- For other titles: the junction tiles (80-83, 544-546) that 1817 and the
  1822 family use, and token colours per edition (see
  `docs/importing-a-title.md`).

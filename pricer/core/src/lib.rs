//! Pure, feed-independent pricing core for the weekend-gap layer pricer: the per-market
//! scenario tables and the EL/TVaR95/cost-of-capital premium formula, with zero dependency on
//! Stylus, a deployed contract, or any live feed. Depended on by two things:
//! - `pricer` (../Cargo.toml, `heracles-pricer`), the Stylus contract crate, which wraps
//!   `price_core` with a `quote()` entrypoint that reads live Chainlink feeds for the
//!   volatility scale and is what actually deploys.
//! - `pricer_cli` (../pricer_cli), a plain native binary that calls `price_core` directly, used
//!   by contracts/test/PricerParity.t.sol's `vm.ffi` fuzz test to prove Solidity's
//!   `Pricer.priceCore` and this `price_core` are bit-identical.
//!
//! Split out into its own crate (rather than living directly in ../src/lib.rs) specifically so
//! `pricer_cli` never depends on the `heracles-pricer` package: that package's
//! `[lib] crate-type = ["lib", "cdylib"]` makes rustc always attempt to link the cdylib artifact
//! whenever the package is compiled at all (even as an rlib-only dependency), and that link
//! always fails on a native target (the cdylib references WASM-hostio-only symbols like
//! `read_args`/`storage_flush_cache` that only exist when actually running under Stylus). A pure
//! crate with no cdylib target sidesteps that entirely; `cargo stylus check`/deploy still target
//! wasm32 explicitly and are unaffected either way.
//!
//! Per-market scenario tables: six independently sourced 504-scenario Friday-close-to-Monday-open
//! weekend gap tables. Four equity names (NVDA, AAPL, SPY, TSLA) in whole basis points, fetched from
//! api.nasdaq.com and re-derivable with `scripts/generate_gap_tables.py`; and EUR/USD and XAU/USD in
//! hundredths of a basis point, taken at the contract's own fixing minutes (Friday 16:00 ET, Monday
//! 9:30 ET) from Dukascopy 1-minute bars and re-derivable with
//! `scripts/generate_fx_gold_gap_tables.py` (evidence/gap-tables/{TICKER}.json holds the full
//! detail). Table id 0 is NVDA, 1 AAPL, 2 SPY, 3 TSLA, 4 EUR/USD, 5 XAU/USD. `table_ids[i]` (a caller-
//! supplied, per-deployment array; docs/security/capacity-review.md "Re-review (2026-09-28)" P2)
//! picks market i's table explicitly, so the market a table prices no longer depends on
//! `exposure[i]`'s array position. There is no positional or id-value fallback (P2 re-review):
//! `price_core` fails closed with `MissingTable` if `table_ids` does not cover every market in
//! `exposure`, and with `BadTableId` if any entry is not 0-5, rather than ever silently pricing
//! an unmapped or out-of-range market on the NVDA table.
//!
//! Pricing formula: `premium = el + RISK_LOAD_PPM * (tvar95 - el) + CAPITAL_CHARGE_ANNUAL_PPM *
//! limit * LOCK_DAYS / DAYS_PER_YEAR` (docs/security/capacity-review.md "Re-review
//! (2026-09-28)" item 2 / docs/pricing.md): a per-weekend tail-risk load (not prorated, since
//! a weekend gap is a discrete per-bind event, not a continuous-time process) plus the
//! risk-free rate on the fully collateralised limit for the real 7-day lock. Replaces the
//! prior `el + c * (tvar95 - el)` cost-of-capital-only load, which priced writers a Sharpe
//! ratio near zero (docs/security/capacity-review.md "Pricing (item 2)").
use alloy_primitives::{I256, U256};

extern crate alloc;
use alloc::vec::Vec;

pub const NVDA_GAPS: [i16; 504] = [0,53,-2,68,33,294,14,78,-31,174,-215,-71,208,-219,39,-42,-20,-76,-33,-20,93,73,-150,42,67,-176,2,3,126,42,46,130,130,131,-46,-249,118,86,34,203,84,17,33,70,238,61,47,-122,113,279,-70,113,82,62,45,0,-71,0,30,16,120,30,86,-115,118,232,48,14,-24,-279,141,37,76,-86,68,-92,216,119,12,31,29,177,60,160,-29,54,-20,-67,-171,-119,121,-45,-43,23,-20,14,-67,44,-19,34,-37,-47,112,-125,-22,92,287,-25,-180,-161,337,561,-123,-82,-238,131,170,-142,-78,-1474,44,-120,-27,212,99,63,75,-92,206,-64,-16,18,-410,-315,-254,49,33,155,-5,57,508,-150,51,51,-17,-458,-136,286,195,-175,70,-166,0,61,144,-19,130,86,161,-1,-15,244,-13,-43,85,48,-37,-159,137,-59,-489,-31,36,-143,-812,253,-983,-1181,-2,104,464,-174,187,-67,-6,318,145,-48,-48,-131,42,16,110,71,37,111,120,248,158,27,-704,753,-217,129,133,165,66,-120,99,-7,-94,64,3,32,57,-149,107,122,51,49,100,69,-102,117,-9,7,52,-15,-77,-236,-53,77,-17,-60,147,16,-4,45,-109,174,122,95,-135,-126,103,39,-26,74,86,-4,92,-344,-168,-115,-123,-52,109,32,133,53,161,274,-265,17,-178,137,-244,-253,-447,150,22,-6,-257,-68,-52,-105,20,23,6,-391,-160,-4,-343,-111,-252,90,224,-574,374,109,-240,-197,343,-173,10,-783,-4,-201,-148,62,-13,-141,-20,171,-32,259,34,-40,51,-67,-170,-150,-117,21,1,-87,162,286,0,126,-204,-139,128,-181,165,0,-93,-43,22,-96,-72,-39,33,-55,59,-116,423,-106,111,72,60,51,36,180,95,1,96,-90,276,101,-59,126,-262,-5,122,-201,-88,-38,145,62,-3,3,5,-147,-3,104,28,-56,85,56,94,33,312,65,-92,112,225,-126,290,-37,79,103,250,-16,68,67,137,355,364,-43,84,-263,-6,132,102,205,56,-1418,150,-24,15,-281,199,-194,47,-255,6,124,9,103,134,71,-175,3,42,-244,-5,117,-159,285,-436,105,-1249,-443,19,174,158,-113,-248,88,185,-414,-726,287,-119,-139,456,-222,218,27,104,97,-94,41,27,20,30,83,-36,8,20,-240,32,-121,-78,125,-113,262,-5,200,276,370,-221,34,-127,13,167,162,-148,154,-89,-233,-27,-206,-62,-58,83,-123,-56,151,264,75,-138,-84,66,53,-54,202,56,217,248,182,69,-115,151,66,-152,-25,36,38,61,119,-323,30];
pub const AAPL_GAPS: [i16; 504] = [-30,84,-26,43,-6,114,-66,5,-32,9,-58,-15,0,-2,3,-59,0,-84,4,73,38,35,-30,-21,29,-89,3,18,86,101,5,-6,61,-12,-71,-217,98,61,60,-5,-15,21,27,43,117,0,18,-18,118,14,-125,9,33,58,41,52,-8,-67,8,5,84,-10,52,-241,55,-37,46,-65,-79,-87,134,-22,48,-57,17,-39,190,89,17,67,-12,73,22,91,-52,73,-18,-51,-82,-70,81,10,-40,48,0,8,24,46,34,-16,-76,-39,98,-93,-43,22,134,-153,-268,-182,113,329,-207,-2,-171,147,30,-95,-26,-125,53,38,-42,69,41,149,-17,24,89,-29,-15,5,-352,-480,-290,-3,30,87,8,-12,265,-167,39,52,35,-296,-68,200,159,-111,74,-47,56,95,-33,-55,47,34,59,-71,2,36,1,-26,67,39,-12,-122,42,-48,-259,-168,-183,-295,-504,326,-875,-1296,-51,121,393,-171,-41,3,-65,177,145,-6,-38,-164,46,-11,140,9,118,183,134,101,348,222,-580,243,-215,243,79,264,79,-90,23,152,-29,-14,33,5,16,-129,-217,50,288,136,-53,9,-143,205,-40,31,28,36,-36,-48,38,44,-61,-49,46,38,22,37,-12,23,8,76,-180,-20,34,4,-38,8,27,43,111,-155,-99,-62,-44,-96,-1,-54,9,25,70,163,151,93,-167,15,-179,-90,-147,-10,27,-75,-139,-109,12,-212,-29,-146,15,-81,-41,-60,-150,-106,15,-38,113,-311,141,73,-83,-93,38,-5,-92,62,-34,-107,-151,42,141,-92,-51,1,24,194,-6,-166,-92,-49,-75,-201,-3,38,45,-36,27,65,5,18,-67,-125,-4,-154,68,182,-47,5,-19,-38,-7,-1,-24,-63,34,-67,87,93,17,-28,8,-10,-74,63,77,12,8,10,33,83,-62,106,84,-34,1,-38,-117,-114,48,-15,-31,11,-3,-66,-133,-75,1,-279,50,-202,39,-21,124,-23,-29,-15,-195,129,171,-100,-32,-67,31,240,-56,130,-29,81,34,1,41,11,70,33,258,120,-46,-945,-8,-15,-4,-20,0,-268,-38,99,-101,51,-23,83,-86,-86,11,69,-3,-42,-6,11,-131,39,-140,-260,56,-255,85,-18,-25,-2,-148,-8,125,-41,-593,671,34,-110,627,-159,155,-28,23,43,31,46,-58,44,7,105,-62,5,-56,-124,-16,125,114,-35,-1,168,142,78,2,18,-132,-22,-30,-23,67,-30,-26,-14,-8,-110,139,21,-8,89,-41,-67,-69,79,241,51,-29,4,-183,-17,-46,0,24,-78,46,103,104,54,-7,46,22,-207,9,69,-3,-90,76,-25];
pub const SPY_GAPS: [i16; 504] = [-22,52,-1,48,18,139,28,31,-16,44,-5,9,14,68,-13,-33,-17,-35,-20,25,18,-4,-39,-3,0,-83,3,7,110,25,2,21,25,-15,-8,-12,39,32,45,-7,-4,-4,19,3,60,-3,25,-23,59,17,-12,10,10,10,14,-25,-6,-30,11,2,70,3,60,-17,37,-4,51,-9,-23,-73,89,-40,44,-50,12,-31,158,64,70,24,26,33,18,62,-68,34,9,-59,-47,-65,41,2,-8,3,1,11,18,47,-16,40,-2,-22,48,-27,-14,27,131,20,-21,-25,96,168,-8,-41,-69,73,12,-82,-62,-90,2,27,-32,57,42,29,9,-14,79,-16,3,3,-163,-197,-62,11,1,60,9,8,126,-49,16,15,-4,-155,-57,116,85,-64,37,-42,-24,19,-30,-12,49,44,56,-49,-8,33,9,-14,60,27,3,-60,21,-32,-175,50,-29,-32,-310,66,-745,-1045,-27,90,389,-141,76,-72,-72,236,220,-23,28,-203,-21,45,80,-9,23,55,15,33,78,-7,-171,103,-150,137,66,79,39,-106,112,394,80,55,-23,-22,64,-114,-89,70,21,99,40,34,-76,138,27,7,14,-40,-16,-24,17,51,9,-29,58,60,0,3,45,13,1,-2,-119,-14,42,-1,-31,41,16,-8,72,-148,-25,-29,-16,-43,26,23,25,29,43,111,60,-12,-117,28,-73,-107,-136,-16,18,-12,-54,-131,-14,20,-4,-14,5,-77,-56,2,-152,-43,82,-41,103,-255,165,25,-141,-73,84,17,-69,43,-55,-121,-77,23,54,-86,-42,109,32,178,43,-66,36,-46,-35,-81,-73,21,5,-3,51,59,-1,21,-71,-62,17,-103,88,21,-106,21,60,-13,-2,-5,-11,8,15,0,48,8,24,-46,-14,-8,-8,-3,26,11,43,-21,24,52,-10,61,-7,-29,-20,-46,54,-38,70,18,-31,-6,-14,-76,-11,35,9,-66,11,-30,33,7,-13,-1,-36,9,-16,-24,82,-27,14,84,54,36,48,33,2,16,31,-16,-13,-3,26,14,36,73,29,-399,23,8,19,-57,79,-5,19,-18,-29,28,-13,61,2,27,8,67,7,-2,30,-4,-120,73,-81,52,-216,-152,54,19,35,34,-145,0,121,-105,-318,189,14,-74,304,-103,120,-28,10,57,13,40,-7,19,6,64,4,-9,-20,-117,21,34,-23,38,36,117,44,81,53,93,-33,56,-67,13,58,49,-40,49,-49,-147,18,-35,-17,-24,-23,-106,-89,92,146,95,-30,0,-11,-8,-16,9,59,-15,79,136,103,-33,51,81,32,-9,-2,-12,-26,-15,-69,60];
pub const TSLA_GAPS: [i16; 504] = [405,241,27,46,126,159,-30,1,-59,57,32,0,72,55,-2,-44,46,-17,-13,56,118,-344,-145,46,-34,-97,309,219,118,26,83,-198,63,26,-40,19,97,84,239,-10,-68,56,13,12,189,-47,-22,-45,232,12,59,42,-203,-51,138,-53,30,-94,-40,-73,-1,-16,42,-42,21,-18,39,-18,-88,-168,184,-30,41,-81,44,-151,192,36,-45,36,-16,116,75,163,-12,86,153,-77,-105,499,100,-225,-374,-43,-78,159,-452,-149,-156,381,-175,-21,1549,98,11,26,199,-171,-61,57,-25,272,57,-101,-196,117,127,-141,85,-139,25,190,-43,109,113,-22,21,-182,99,99,35,31,-196,-314,-390,30,19,281,26,62,302,-80,119,22,-42,-202,-86,194,104,-68,112,33,-26,36,-70,0,54,-18,48,202,21,339,-16,21,116,153,-37,-57,321,387,-404,355,694,520,-688,648,-1394,-1411,142,-80,650,-281,172,-5,-353,358,216,275,376,-187,-9,97,740,121,127,129,-32,159,372,44,-1490,221,248,424,199,184,149,-214,154,222,11,284,281,98,148,-414,-348,141,99,262,205,23,-239,216,43,5,454,-50,128,-273,159,-79,-111,-241,12,41,-121,38,19,-3,41,80,-222,118,186,158,-169,76,39,88,54,-328,-16,275,27,104,449,278,-592,-153,222,176,-133,-157,-235,861,-263,-219,-415,311,5,18,-267,63,215,-185,106,539,44,-440,-259,-115,-337,-32,-134,187,419,-390,362,149,-188,53,203,-1,139,237,59,-160,-183,91,35,-107,-127,-405,39,246,-402,-102,57,-163,-241,-159,-278,-165,251,-459,-382,522,269,184,8,159,-126,-159,262,38,-345,-114,210,-364,71,-26,-69,215,-19,31,359,179,145,37,-255,562,74,186,-160,39,-95,-286,281,167,0,635,-118,-61,-216,-200,-43,-94,96,183,44,-11,61,-129,-45,11,77,64,-57,-173,3,130,-194,-75,-191,17,-193,6,394,-121,269,-47,-441,1196,144,91,6,-158,3,-80,-5,107,159,-151,312,209,232,-1081,-49,44,-71,54,260,-43,183,-55,-43,107,-82,30,-178,781,624,215,209,216,111,236,-284,311,-292,144,-290,-443,-150,-23,10,251,-386,-197,377,-540,-654,240,141,-92,796,-391,236,-85,-311,184,167,-115,135,144,76,213,162,-28,-33,-169,108,687,118,90,254,243,104,144,-12,235,-139,283,-113,-166,228,180,-130,226,-85,-186,-90,-212,-29,-122,-110,-296,-168,128,139,111,32,49,-112,-15,-145,-70,100,-190,136,146,55,-77,137,7,-8,-60,-46,-40,-44,85,-155,202];

/// EUR/USD and XAU/USD tables, in hundredths of a basis point (centi-bps) so Dukascopy's two-decimal
/// bps survive exactly; they do not fit i16 for gold (-404.88 bps is -40488). Sourced and checked in
/// evidence/gap-tables/{EUR,XAU}.gaps.txt (a test below compares each constant to its file).
pub const EUR_GAPS: [i32; 504] = [1168,-5197,76,-3309,2711,-5058,-5557,-1824,641,3750,-1225,-2124,987,9543,-544,-642,3213,15538,1469,-5092,4904,3579,474,-2526,2001,-2170,1125,-5428,-1508,-584,-2425,-1250,492,-2985,1590,335,3127,-4066,285,-5534,-5482,60,-1447,-3151,862,-1964,26,-2238,1576,-4054,1785,4237,-5705,7524,2160,-5008,-3451,1079,-2394,643,-941,-788,2124,4618,1104,2629,4166,-3607,-4773,-3370,4211,433,-3782,4848,2958,-990,2462,-6286,2614,2380,-930,2916,-2074,2298,-402,1342,431,3989,5488,4979,-999,-5190,2622,-2164,-2621,-430,-6315,1585,2056,1828,-964,3681,5520,-253,5209,-445,-431,-473,-1815,-3135,1974,2471,-2569,1816,1996,1611,1676,4582,867,507,870,-1277,2591,457,-1704,1969,-1588,2838,906,-2550,-846,-479,214,-108,5509,1303,316,-1894,-2547,2150,-4993,-3267,-4131,528,-1594,-251,993,-1495,1216,624,-1297,2142,1130,2879,515,1754,2983,-45,-838,-308,-3255,-1690,120,-1401,7801,13427,945,8588,-8415,-2849,-2761,-488,4024,-4855,-609,2524,-514,1775,1390,-204,3594,4302,7791,3611,-1128,8040,-5782,-1892,1817,3782,3396,-2035,3049,-6675,3759,4944,-1657,5163,-3591,-1211,3250,-144,3011,3052,808,3251,-2572,-6208,-1076,-1989,-2983,-266,520,2352,-870,-3525,-3236,1260,-831,1828,672,3764,-1876,2504,534,280,2413,443,608,1528,2882,-1692,-354,-1726,949,1410,1416,170,-1492,3273,-229,-993,-1744,-1398,-1664,2725,-86,629,-2757,1367,251,-577,-3960,-4707,-1318,-2209,5046,186,-4386,-6179,-981,-3906,3632,-2558,-2566,1174,-4705,-1033,3795,-823,-2549,-5458,726,-546,-6226,-4057,-427,1990,9018,2730,-914,-5942,2373,2273,2321,-11259,6011,3594,2779,1945,-3733,-3655,3863,-2743,7616,-3556,-3550,-2796,-3810,5602,-2809,-6392,3203,-4760,-7419,2729,2383,2792,1624,1112,-2251,6622,-932,-433,1786,-3752,852,-542,3556,2294,6271,5759,3262,2821,-4650,-4683,2420,508,1770,2506,287,-1594,-2157,2094,-1152,2103,46,-602,-347,-4090,-27,-427,-5472,1849,241,2478,3318,891,-3100,-4673,-4089,2302,812,2866,1538,-936,1256,-1197,-5276,-1477,3259,1481,-858,-330,-4183,-4753,-1632,-872,2569,1218,-841,73,2184,-1094,425,667,-2562,-84,1774,2980,-846,378,92,-5555,1027,4340,4127,277,816,55,-3877,7697,714,907,-2681,1484,-3535,4757,-2625,949,-164,-2085,-1031,1890,6008,-5766,3315,10629,-8354,1458,-610,-2531,-2398,7316,-3299,12126,2049,-10893,-2091,-1754,507,10603,-230,1645,416,-767,2129,-3139,9901,-555,4715,-11824,9911,1426,4658,-35,3957,-3995,982,-3227,-907,3468,-8992,1478,-1830,-2179,-1988,1017,2808,2070,2962,3178,-4472,-3608,-1448,671,-1527,121,-2392,1216,3164,661,971,4074,255,-3328,3550,3095,3900,-3366,7977,-1027,840,-9420,-2421,5200,2526,-3317,3708,-2439,365,2628,-1050,263,2444,3274,-3181,2117,3906,-3425,1563,-1382,771,-1888,827,9,-770,2360,-754,1191,887,-5278,-461,-2580];
pub const XAU_GAPS: [i32; 504] = [401,8672,-13821,4011,4389,-7523,1324,-6528,-3205,-1939,1798,-2782,-286,-46,-3454,4281,2405,-2847,3633,2900,3653,-573,-13864,-8078,4763,-8245,1675,5267,5601,4059,4191,1317,8071,-7017,1721,228,-1454,-434,2738,9220,-451,-3416,-12352,-4409,578,5940,1955,-276,2550,-1932,-4768,-9760,-12754,-2213,5532,2230,-1450,-1666,-6289,2147,4877,6492,-9710,-6784,-3625,-3497,4540,-296,-5179,298,826,2343,-4436,-3605,-778,3749,-947,2578,676,-3759,3451,3664,-1143,2769,-260,-3990,-113,3625,308,2209,-7959,-8719,-479,1161,-2013,-2036,2841,632,312,-2660,-3617,6622,-515,-2691,-270,-3140,-7673,2489,-85,1157,402,5302,1928,-3138,-13898,7628,-3979,-2839,-3076,-4017,-900,9290,-3247,2350,7187,-198,5653,2940,-880,-785,-4358,-7938,3717,2243,-2808,-2638,2725,4732,3196,8211,-5206,-3950,-527,9941,-1221,895,6438,-8971,1039,5888,-11941,250,-2212,479,3268,14880,2541,-10251,1564,230,3087,10029,1550,-8771,-5207,3076,1809,-4490,-2302,1502,1916,-3071,1668,1027,3093,2006,17482,-3867,1948,8419,-4802,2909,-202,23788,9789,6293,-40488,17990,-809,9990,1491,-4588,2620,-1750,2340,-4271,843,5265,-13661,6815,72,7183,3645,17084,-2327,2117,11855,4654,1947,-2883,6170,-17938,5057,2540,-2826,6398,306,6801,-37070,452,-3446,1602,-3589,-1187,-6768,5487,5453,13792,12828,-1252,9018,7308,-3333,4816,-6301,-4918,-3398,-2602,1527,11890,6775,3667,710,531,-1149,-14362,9700,573,1848,-3086,503,383,-2723,-10186,1889,12545,-2802,-2665,1590,2997,3335,-5315,-1333,628,5544,4549,3703,-1557,-15812,-2861,2122,457,-11983,-2212,2263,4029,4504,3608,-177,-1610,13270,3949,-10930,584,-11147,4624,9755,-17477,-18751,-6893,-2072,6395,3869,1505,-19269,1811,3144,1671,-2271,7286,-299,5118,4680,-11083,-6330,656,1515,7826,-6055,1296,4213,-12548,12972,-4134,-6322,-1356,-2003,-2060,-4062,-3711,-279,5044,-3272,-4989,398,3876,-3921,2454,3021,-1157,16232,2545,-13649,3665,-2434,-847,6628,2012,2541,-1948,138,-1155,-1444,-1592,4669,1769,-1983,-2421,202,3221,-233,-4104,3236,2,-974,5206,2731,-1101,-6926,8796,-5756,-510,-3151,-3553,-770,-7310,-12325,-6052,2566,-11494,2309,-3787,7164,-9160,-5091,2465,-4218,6293,441,-338,4201,4111,4664,-21035,-2547,10177,-7464,898,7067,2562,6822,-3717,3659,1182,-5774,1380,-921,3048,-21118,6937,-7118,5862,-1379,2807,295,3250,-4258,-1697,-1051,6090,-1204,3164,-21204,16467,-22338,13812,3852,-1830,-1155,-4769,-8277,3451,-7350,4812,15263,4345,2689,6703,-2822,1103,1477,12173,-3923,-8082,-1407,26344,-27187,12348,-6799,18449,459,-4714,903,3724,-295,11551,-2683,5484,-14009,1173,-2693,7333,8137,2645,10511,14650,12366,19970,22278,-17162,2202,20596,-5050,2082,1599,5977,20000,-31117,20663,17496,18833,19553,-25801,13645,-8002,13379,13390,-11401,971,-20399,11790,-5526,-6178,-3446,-10758,919,5737,11903,-17679,2997,33911,-8277,-11188,-1664,5496,-4096,-2086,2406,11983,-2725,-6955,-17274,-2811,-34679];
/// Centi-bps per bp for the FX and gold tables; the equity tables are whole bps (unit 1).
pub const FX_UNIT: i128 = 100;
/// Highest real table id: 0 NVDA, 1 AAPL, 2 SPY, 3 TSLA, 4 EUR/USD, 5 XAU/USD.
pub const MAX_TABLE_ID: u8 = 5;

pub const SCENARIOS: usize = 504;
pub const TAIL: usize = 25; // ceil(504 * 0.05), the worst 5% of scenarios
pub const PPM: i128 = 1_000_000;

/// Per-weekend tail-risk load, see contracts/src/Pricer.sol's doc comment and
/// docs/security/capacity-review.md "Pricing (item 2)" for the full derivation: a flat 3% of
/// (TVaR95 - EL), not prorated by time, since a weekend gap prices as a discrete per-bind event.
pub const RISK_LOAD_PPM: i128 = 30_000; // 3.00%
/// Risk-free rate on the fully collateralised limit for the real capital-lock duration
/// (LOCK_DAYS / DAYS_PER_YEAR), replacing the old cost-of-capital-only load.
pub const CAPITAL_CHARGE_ANNUAL_PPM: i128 = 40_000; // 4.00%
pub const LOCK_DAYS: i128 = 7;
pub const DAYS_PER_YEAR: i128 = 365;

pub const VOL_ROUNDS: u64 = 8;
pub const NORMAL_ROUND_MOVE_BPS: u64 = 50;
/// Floor at 1.0x (docs/security/capacity-review.md P4): the vol scale may only raise a quote
/// above the static historical table, never cut it below, closing the buyer's bind-timing
/// option (a heartbeat-quiet weekday priced a materially cheaper premium than a livelier one).
pub const MIN_SCALE_PPM: u64 = 1_000_000;
pub const MAX_SCALE_PPM: u64 = 3_000_000;

/// Table id 0 NVDA, 1 AAPL, 2 SPY, 3 TSLA, 4 EUR/USD, 5 XAU/USD. `table_ids[i]` selects market i's
/// table explicitly (docs/security/capacity-review.md P2 re-review). Callers must ensure
/// `i < table_ids.len()` and `table_ids[i] <= MAX_TABLE_ID`; `price_core` validates both before ever
/// calling this, so there is no positional or id-value fallback left to silently mis-table a market.
/// Returns scenario `s`'s raw gap and that table's unit (raw units per bp): whole bps for the
/// equity tables, centi-bps for FX and gold.
pub fn gap_for(i: usize, table_ids: &[u8], s: usize) -> (i128, i128) {
    match table_ids[i] {
        1 => (AAPL_GAPS[s] as i128, 1),
        2 => (SPY_GAPS[s] as i128, 1),
        3 => (TSLA_GAPS[s] as i128, 1),
        4 => (EUR_GAPS[s] as i128, FX_UNIT),
        5 => (XAU_GAPS[s] as i128, FX_UNIT),
        _ => (NVDA_GAPS[s] as i128, 1), // id == 0; any other value was already rejected by price_core
    }
}

pub fn c(v: i128) -> I256 {
    I256::try_from(v).unwrap()
}

/// Deterministic pricing core: given exposure and an already-known per-market volatility scale
/// (parts-per-million, 1_000_000 = 1.0x = the stored historical table unscaled), no feed reads
/// happen here at all.
pub fn price_core(
    exposure: &[I256],
    vol_scale_ppm: &[U256],
    retention: U256,
    limit: U256,
    table_ids: &[u8],
) -> Result<(U256, U256, U256), Vec<u8>> {
    if exposure.is_empty() {
        return Err(b"EmptyExposure".to_vec());
    }
    if vol_scale_ppm.len() != exposure.len() {
        return Err(b"BadFeeds".to_vec());
    }
    // P2 re-review (docs/security/capacity-review.md): fail closed instead of silently pricing
    // an unmapped market on NVDA. `table_ids` must cover every market in `exposure`, and every
    // entry must be a real table id (0-5); both are the single root check every caller of
    // `table_for` below relies on (the Stylus constructor performs the same id check again at
    // deploy time so a misconfigured deploy reverts immediately, not just on first quote).
    if table_ids.len() < exposure.len() {
        return Err(b"MissingTable".to_vec());
    }
    if table_ids.iter().any(|&id| id > MAX_TABLE_ID) {
        return Err(b"BadTableId".to_vec());
    }
    let retention = I256::from_raw(retention);
    let limit = I256::from_raw(limit);
    let bps = c(10_000);
    let ppm = c(PPM);
    let overflow = || b"Overflow".to_vec();

    let mut payout = [I256::ZERO; SCENARIOS];
    let mut sum_payout = I256::ZERO;
    for s in 0..SCENARIOS {
        let mut loss = I256::ZERO;
        for (i, e) in exposure.iter().enumerate() {
            let (raw, unit) = gap_for(i, table_ids, s);
            let raw_gap = c(raw);
            let scale = I256::from_raw(vol_scale_ppm[i]);
            // L1-style checked arithmetic throughout (SECURITY-REVIEW.md): a pathological
            // exposure or scale reverts here instead of silently wrapping.
            let gap = raw_gap.checked_mul(scale).ok_or_else(overflow)?.checked_div(ppm).ok_or_else(overflow)?;
            let pnl = e
                .checked_mul(gap)
                .ok_or_else(overflow)?
                .checked_div(bps.checked_mul(c(unit)).ok_or_else(overflow)?)
                .ok_or_else(overflow)?;
            if pnl < I256::ZERO {
                loss = loss.checked_sub(pnl).ok_or_else(overflow)?;
            }
        }
        let mut p = loss.checked_sub(retention).ok_or_else(overflow)?;
        if p < I256::ZERO {
            p = I256::ZERO;
        }
        if p > limit {
            p = limit;
        }
        payout[s] = p;
        sum_payout = sum_payout.checked_add(p).ok_or_else(overflow)?;
    }
    let el = sum_payout / c(SCENARIOS as i128);

    // Worst-5% tail via partial selection (pull the TAIL largest payouts, not a full sort):
    // matches the Solidity side.
    let mut used = [false; SCENARIOS];
    let mut tail_sum = I256::ZERO;
    for _ in 0..TAIL {
        let mut best_idx: Option<usize> = None;
        let mut best_val = I256::ZERO;
        for s in 0..SCENARIOS {
            if used[s] {
                continue;
            }
            if best_idx.is_none() || payout[s] > best_val {
                best_val = payout[s];
                best_idx = Some(s);
            }
        }
        let idx = best_idx.unwrap();
        used[idx] = true;
        tail_sum = tail_sum.checked_add(best_val).ok_or_else(overflow)?;
    }
    let tvar95 = tail_sum / c(TAIL as i128);

    // premium = el + RISK_LOAD_PPM * (tvar95 - el) + CAPITAL_CHARGE_ANNUAL_PPM * limit *
    // LOCK_DAYS / DAYS_PER_YEAR; each term fully multiplied before its single final division.
    let risk_load = tvar95
        .checked_sub(el)
        .ok_or_else(overflow)?
        .checked_mul(c(RISK_LOAD_PPM))
        .ok_or_else(overflow)?
        .checked_div(ppm)
        .ok_or_else(overflow)?;
    let capital_charge = limit
        .checked_mul(c(CAPITAL_CHARGE_ANNUAL_PPM))
        .ok_or_else(overflow)?
        .checked_mul(c(LOCK_DAYS))
        .ok_or_else(overflow)?
        .checked_div(c(DAYS_PER_YEAR * PPM))
        .ok_or_else(overflow)?;
    let premium = el.checked_add(risk_load).ok_or_else(overflow)?.checked_add(capital_charge).ok_or_else(overflow)?;

    let premium = U256::try_from(premium).map_err(|_| b"NegativePremium".to_vec())?;
    let el = U256::try_from(el).map_err(|_| b"NegativeEl".to_vec())?;
    let tvar95 = U256::try_from(tvar95).map_err(|_| b"NegativeTvar".to_vec())?;
    Ok((premium, el, tvar95))
}

#[cfg(test)]
mod test {
    use super::*;

    fn neutral(n: usize) -> Vec<U256> {
        alloc::vec![U256::from(PPM as u64); n]
    }

    #[test]
    fn test_zero_exposure_quotes_capital_charge_only() {
        // EL and TVaR95 are both zero with no exposure, but the capital charge is a function of
        // `limit` alone (rent on the fully collateralised capital, not of realised loss), so the
        // premium is no longer zero: it floors at the capital charge on a $60,000 limit for a
        // 7-day lock, 40,000/1e6 annual rate (docs/security/capacity-review.md "Pricing (item
        // 2)"): 60_000e6 * 40_000 * 7 / (365 * 1e6) = 46_027_397 (46.027397 USDG).
        let (premium, el, tvar95) = price_core(
            &[I256::ZERO],
            &neutral(1),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
            &[0],
        )
        .unwrap();
        assert_eq!(el, U256::ZERO);
        assert_eq!(tvar95, U256::ZERO);
        assert_eq!(premium, U256::from(46_027_397u64));
    }

    #[test]
    fn test_empty_exposure_reverts() {
        let result = price_core(&[], &[], U256::from(0u64), U256::from(1u64), &[]);
        assert!(result.is_err());
    }

    #[test]
    fn test_bad_feeds_length_reverts() {
        let result = price_core(&[I256::ZERO], &neutral(2), U256::from(0u64), U256::from(1u64), &[0]);
        assert!(result.is_err());
    }

    /// L1: an exposure large enough that exposure*gap overflows I256 must revert, not wrap.
    #[test]
    fn test_overflow_reverts() {
        let result = price_core(&[I256::MIN], &neutral(1), U256::from(0u64), U256::from(40_000_000u64), &[0]);
        assert!(result.is_err(), "overflowing exposure must revert, not wrap");
    }

    /// P2 re-review (docs/security/capacity-review.md): a market index past `table_ids`'s length
    /// (including the old empty-array default) must revert, never silently price on
    /// `default_table_id(i)`'s old positional guess.
    #[test]
    fn test_missing_table_reverts_on_empty_table_ids() {
        let result = price_core(
            &[I256::try_from(2_000_000_000_000i128).unwrap()],
            &neutral(1),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
            &[],
        );
        assert!(result.is_err(), "empty table_ids with nonempty exposure must revert, not default by position");
    }

    /// P2 re-review: a market index past `table_ids`'s length must revert even when other
    /// indices are covered (three markets, only two table ids supplied).
    #[test]
    fn test_missing_table_reverts_when_table_ids_shorter_than_exposure() {
        let exposure = [I256::ZERO, I256::ZERO, I256::try_from(2_000_000_000_000i128).unwrap()];
        let result =
            price_core(&exposure, &neutral(3), U256::from(20_000_000_000u64), U256::from(60_000_000_000u64), &[0, 1]);
        assert!(result.is_err(), "table_ids shorter than exposure must revert, not default the missing index by position");
    }

    /// P2 re-review: any table id above 3 (the highest real table) must revert, never silently
    /// price that market on NVDA (the old catch-all fallback).
    #[test]
    fn test_bad_table_id_reverts() {
        let result = price_core(
            &[I256::try_from(2_000_000_000_000i128).unwrap()],
            &neutral(1),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
            &[MAX_TABLE_ID + 1],
        );
        assert!(result.is_err(), "table id 6 must revert, not silently price on the NVDA table");
    }

    /// Acceptance number (docs/security/capacity-review.md "Pricing (item 2)" README example:
    /// long $2M, NVDA table, retention $20k, limit $60k, 1.0x scale). The reviewer's rounded
    /// figure (5,040.08 + 1,490.64 + 46.03 = 6,576.75) sums three components independently
    /// rounded to cents; this integer-exact computation is 6,576.744381 (displays 6,576.74), a
    /// benign $0.01 rounding-accumulation artifact, not a formula error (the SPY case below
    /// matches the reviewer's rounded figure exactly, with zero discrepancy).
    #[test]
    fn test_nvda_premium_matches_reviewer_acceptance_number() {
        let exposure = [I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium, el, tvar95) = price_core(
            &exposure,
            &neutral(1),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
            &[0], // explicit table id: NVDA
        )
        .unwrap();
        assert_eq!(el, U256::from(5_040_079_365u64));
        assert_eq!(tvar95, U256::from(54_728_000_000u64));
        assert_eq!(premium, U256::from(6_576_744_381u64));
    }

    /// Same layer, SPY table: matches the reviewer's rounded figure exactly (1,051.19 + 579.50 +
    /// 46.03 = 1,676.72).
    #[test]
    fn test_spy_premium_matches_reviewer_acceptance_number() {
        let exposure = [I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium, el, tvar95) = price_core(
            &exposure,
            &neutral(1),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
            &[2], // explicit table id: SPY
        )
        .unwrap();
        assert_eq!(el, U256::from(1_051_190_476u64));
        assert_eq!(tvar95, U256::from(20_368_000_000u64));
        assert_eq!(premium, U256::from(1_676_722_158u64));
    }

    /// P2 (docs/security/capacity-review.md "Re-review (2026-09-28)"): a single SPY feed
    /// configured with an explicit table id must price on the SPY table, matching a 3-market
    /// exposure that places the same notional at index 2 (SPY) with the other two markets flat.
    /// Without an explicit table id, a single feed at position 0 would wrongly default to the
    /// NVDA table (`test_RR3_singleSpyFeedMustPriceOnSpyTable` in the reviewer's scratch suite).
    #[test]
    fn test_rr3_single_spy_feed_must_price_on_spy_table() {
        let exposure1 = [I256::try_from(2_000_000_000_000i128).unwrap()];
        let quote_single =
            price_core(&exposure1, &neutral(1), U256::from(20_000_000_000u64), U256::from(60_000_000_000u64), &[2])
                .unwrap();

        let exposure3 = [I256::ZERO, I256::ZERO, I256::try_from(2_000_000_000_000i128).unwrap()];
        let quote_multi = price_core(
            &exposure3,
            &neutral(3),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
            &[0, 1, 2],
        )
        .unwrap();

        assert_eq!(quote_single, quote_multi, "single SPY feed with table id 2 must match a 3-market SPY-at-index-2 quote");
        assert_eq!(quote_single.0, U256::from(1_676_722_158u64), "must be the SPY acceptance number, not NVDA's");
    }

    #[test]
    fn test_per_market_table_selection_differs() {
        // Same exposure/retention/limit, different market index (0=NVDA vs 2=SPY): SPY's
        // materially calmer historical table (evidence/auction-and-pricing.md: SPY std 0.93% vs
        // NVDA 2.12%) must price a lower premium, proving the table selection is actually wired
        // in and not silently falling back to one shared table for every index.
        let exposure = [I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium_nvda, ..) = price_core(
            &exposure,
            &neutral(1),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
            &[0],
        )
        .unwrap();
        let exposure3 = [I256::ZERO, I256::ZERO, I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium_spy, ..) = price_core(
            &exposure3,
            &neutral(3),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
            &[0, 1, 2],
        )
        .unwrap();
        assert!(premium_spy < premium_nvda, "SPY's calmer table must price lower than NVDA's at the same exposure");
    }

    #[test]
    fn test_vol_scale_up_increases_premium() {
        let exposure = [I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium_neutral, ..) =
            price_core(&exposure, &neutral(1), U256::from(0u64), U256::from(1_000_000_000_000u64), &[0]).unwrap();
        let scaled_up = alloc::vec![U256::from(MAX_SCALE_PPM)];
        let (premium_scaled, ..) =
            price_core(&exposure, &scaled_up, U256::from(0u64), U256::from(1_000_000_000_000u64), &[0]).unwrap();
        assert!(premium_scaled > premium_neutral, "3x volatility scale must price a higher premium");
    }

    /// Parses a `.gaps.txt` bps list (whole or two-decimal bps, comma or newline separated) into
    /// centi-bps without floats.
    fn centibps(text: &str) -> Vec<i32> {
        text.split(|ch: char| ch == ',' || ch.is_whitespace())
            .filter(|t| !t.is_empty())
            .map(|t| {
                let neg = t.starts_with('-');
                let t = t.trim_start_matches('-');
                let (whole, frac) = t.split_once('.').unwrap_or((t, ""));
                assert!(frac.len() <= 2, "more than two decimals: {t}");
                let v = whole.parse::<i32>().unwrap() * 100 + format!("{frac:0<2}").parse::<i32>().unwrap();
                if neg { -v } else { v }
            })
            .collect()
    }

    /// The compiled FX and gold tables are exactly the evidence files: a table that fails to load
    /// (a dropped, shifted or edited row) is red here, and so is a file regenerated without the
    /// constant being refreshed.
    #[test]
    fn test_fx_and_gold_tables_equal_the_evidence_files() {
        let eur = centibps(include_str!("../../../evidence/gap-tables/EUR.gaps.txt"));
        let xau = centibps(include_str!("../../../evidence/gap-tables/XAU.gaps.txt"));
        assert_eq!(eur.len(), SCENARIOS);
        assert_eq!(xau.len(), SCENARIOS);
        assert_eq!(eur.as_slice(), EUR_GAPS.as_slice(), "EUR table differs from evidence/gap-tables/EUR.gaps.txt");
        assert_eq!(xau.as_slice(), XAU_GAPS.as_slice(), "XAU table differs from evidence/gap-tables/XAU.gaps.txt");
        assert_eq!(EUR_GAPS.iter().min(), Some(&-11_824), "EUR worst weekend, -118.24 bps");
        assert_eq!(XAU_GAPS.iter().min(), Some(&-40_488), "XAU worst weekend, -404.88 bps");
    }

    /// Fair premiums for known layers at the 1.0x scale, from scripts/fx_gold_fair_premium.py, which
    /// reads the .gaps.txt files and shares no code with this crate (its `integer` lines).
    fn fx_gold_layer(exposure_usd: i128, table_id: u8, retention_usd: u64, limit_usd: u64) -> (u64, u64, u64) {
        let (p, el, tv) = price_core(
            &[I256::try_from(exposure_usd * 1_000_000).unwrap()],
            &neutral(1),
            U256::from(retention_usd * 1_000_000),
            U256::from(limit_usd * 1_000_000),
            &[table_id],
        )
        .unwrap();
        (u64::try_from(p).unwrap(), u64::try_from(el).unwrap(), u64::try_from(tv).unwrap())
    }

    #[test]
    fn test_eur_usd_fair_premium() {
        assert_eq!(fx_gold_layer(2_000_000, 4, 2_000, 20_000), (1_977_298_772, 1_648_960_317, 12_082_160_000));
        // The vault short the same size loses on up gaps instead: a different, higher number.
        assert_eq!(fx_gold_layer(-2_000_000, 4, 2_000, 20_000), (2_256_830_799, 1_866_075_396, 14_379_840_000));
    }

    #[test]
    fn test_xau_usd_fair_premium() {
        assert_eq!(fx_gold_layer(1_000_000, 5, 5_000, 30_000), (1_635_305_987, 1_173_676_587, 15_794_200_000));
        assert_eq!(fx_gold_layer(-1_000_000, 5, 5_000, 30_000), (1_498_328_232, 1_106_575_396, 13_397_880_000));
    }

    /// An equity table (TSLA, id 3, whole bps) against the figures the Python pricer computes from
    /// evidence/gap-tables/TSLA.gaps.txt, so the equity unit is pinned next to the FX unit.
    #[test]
    fn test_tsla_fair_premium() {
        assert_eq!(fx_gold_layer(500_000, 3, 5_000, 30_000), (2_398_667_943, 1_847_519_841, 19_452_000_000));
        assert_eq!(fx_gold_layer(-500_000, 3, 5_000, 30_000), (3_169_479_609, 2_526_686_507, 23_186_000_000));
    }

    /// The same notional on the same layer prices differently on each table, so ids 4 and 5 are
    /// wired to their own data and not to one shared fallback.
    #[test]
    fn test_fx_gold_tables_are_distinct_from_each_other_and_from_equities() {
        let p: Vec<u64> = [0u8, 2, 4, 5].iter().map(|&id| fx_gold_layer(1_000_000, id, 5_000, 30_000).0).collect();
        for i in 0..p.len() {
            for j in i + 1..p.len() {
                assert_ne!(p[i], p[j], "tables {i} and {j} priced identically: {p:?}");
            }
        }
    }

    /// FX and gold in one layer, each market on its own table: swapping the ids changes the price.
    #[test]
    fn test_fx_and_gold_in_one_layer_use_their_own_tables() {
        let e = [I256::try_from(2_000_000_000_000i128).unwrap(), I256::try_from(1_000_000_000_000i128).unwrap()];
        let (p, ..) =
            price_core(&e, &neutral(2), U256::from(5_000_000_000u64), U256::from(30_000_000_000u64), &[4, 5]).unwrap();
        let (swapped, ..) =
            price_core(&e, &neutral(2), U256::from(5_000_000_000u64), U256::from(30_000_000_000u64), &[5, 4]).unwrap();
        assert_ne!(p, swapped, "swapping the table ids must change the price");
    }

    /// P4 (docs/security/capacity-review.md): MIN_SCALE_PPM floors at 1.0x, so scale may only
    /// raise a quote above the static table, never cut it below.
    #[test]
    fn test_min_scale_floors_at_one() {
        assert_eq!(MIN_SCALE_PPM, PPM as u64);
    }
}

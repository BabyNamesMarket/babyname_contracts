#!/usr/bin/env node
/**
 * generate.js
 * Renders onchain SVG previews for Baby Name Market bet slip NFTs using
 * the compiled contract ABI + an Anvil fork (or simulated call).
 *
 * This script calls `tokenURI()` on a locally-deployed BabyNameMarket
 * contract (via forge script or a hardcoded ABI call) and writes the
 * resulting SVG files to the `previews/` directory.
 *
 * Usage: node scripts/preview/generate.js
 */

'use strict';

const fs   = require('fs');
const path = require('path');

const REPO_ROOT  = path.resolve(__dirname, '../..');
const PREVIEW_DIR = path.join(REPO_ROOT, 'previews');

// ---------------------------------------------------------------------------
// Inline SVG generator – mirrors BetSlipSVG.sol logic in JavaScript so we
// can render previews without running a full EVM node.
// ---------------------------------------------------------------------------

const STATUS_ACTIVE = 0;
const STATUS_CLOSED = 1;
const STATUS_WON    = 2;
const STATUS_LOST   = 3;

const CAT_LABELS = {
  0: (gender, pos) => `${gender} #${pos}`,
  1: (gender)      => `${gender} EXACTA`,
  2: (gender)      => `${gender} TRIFECTA`,
  3: (gender, pos) => `${gender} TOP-${pos}`,
};

function formatDate(ts) {
  if (!ts) return 'TBD';
  const d = new Date(ts * 1000);
  const months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
  const dd  = String(d.getUTCDate()).padStart(2, '0');
  const mon = months[d.getUTCMonth()];
  const yy  = String(d.getUTCFullYear()).slice(-2);
  return `${dd}-${mon}-${yy}`;
}

function formatDeadline(ts) {
  if (!ts) return 'TBD';
  const d = new Date(ts * 1000);
  if (d.getUTCMonth() === 4) { // May (0-indexed)
    return `MOTHERS DAY ${d.getUTCFullYear()}`;
  }
  return formatDate(ts);
}

function formatAmount(normalized, decimals = 6) {
  const scaleFactor = 10 ** (18 - decimals);
  const native      = normalized / BigInt(scaleFactor);
  const denom       = 10 ** decimals;
  const whole       = native / BigInt(denom);
  const frac        = Number(native % BigInt(denom)) * 100 / denom;
  return `$${whole}.${String(Math.floor(frac)).padStart(2, '0')}`;
}

function formatMultiplier(catCollateral, poolCollateral) {
  if (poolCollateral === 0n) return '—';
  const prize   = catCollateral * 90n / 100n;
  const mult100 = prize * 100n / poolCollateral;
  const whole   = mult100 / 100n;
  const frac    = mult100 % 100n;
  return `${whole}.${String(Number(frac) / 10 | 0)}x`;
}

function statusLabel(slip) {
  if (slip.resolved) return slip.won ? 'WON' : 'LOST';
  if ((slip.currentTime || Date.now() / 1000) >= slip.deadline) return 'CLOSED';
  return 'ACTIVE';
}

function statusColor(label) {
  if (label[0] === 'A' || label[0] === 'W') return '#74C69D';
  if (label[0] === 'L') return '#FCA5A5';
  return '#FDE68A';
}

function zeroPad8(n) {
  return String(n).padStart(8, '0');
}

function barcodeLines(tokenId) {
  let bars = '';
  let x    = 20;
  let seed = tokenId === 0 ? 1 : tokenId;
  // Tile the pattern until it reaches the full barcode width (x=380)
  for (let i = 0; x < 380; i++) {
    const idx = i % 32;
    const w   = 1 + ((seed >> idx) & 0x3);
    const gap = 1 + ((seed >> ((idx + 5) % 32)) & 0x1);
    bars += `<rect x="${x}" y="458" width="${w}" height="12" fill="#374151"/>`;
    x += w + gap;
  }
  return bars;
}

function renderSVG(slip) {
  const gender   = slip.gender === 0 ? 'GIRL' : 'BOY';
  const catFn    = CAT_LABELS[slip.categoryType] || CAT_LABELS[0];
  const category = catFn(gender, slip.position);
  const status   = statusLabel(slip);
  const color    = statusColor(status);

  const amount = formatAmount(
    BigInt(slip.amount),
    slip.tokenDecimals || 6
  );
  const multiplier = formatMultiplier(
    BigInt(slip.categoryCollateral),
    BigInt(slip.poolCollateral)
  );
  const poolTotal = formatAmount(
    BigInt(slip.categoryCollateral),
    slip.tokenDecimals || 6
  );

  const row = (key, val, highlight) =>
    `<text x="20" y="{Y}" fill="#374151" font-family="monospace" font-size="12">${key}</text>` +
    `<text x="380" y="{Y}" text-anchor="end" fill="${highlight ? '#1B4332' : '#374151'}"` +
    ` font-family="monospace" font-size="${highlight ? 14 : 12}"${highlight ? ' font-weight="bold"' : ''}>${val}</text>`;

  const rows = (items) =>
    items.map(([k, v, h, y]) =>
      row(k, v, h).replaceAll('{Y}', y)
    ).join('\n  ');

  return `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="560" viewBox="0 0 400 560">
  <defs>
    <filter id="paper" x="0%" y="0%" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="0.65" numOctaves="3" stitchTiles="stitch" result="noise"/>
      <feColorMatrix type="saturate" values="0" in="noise" result="grayNoise"/>
      <feBlend in="SourceGraphic" in2="grayNoise" mode="multiply"/>
    </filter>
  </defs>
  <rect width="400" height="560" fill="#F7F2E8" rx="16" filter="url(#paper)"/>
  <rect width="400" height="96" fill="#1B4332" rx="16"/>
  <rect y="80" width="400" height="16" fill="#1B4332"/>
  <text x="20" y="42" fill="white" font-family="monospace" font-size="20" font-weight="bold">BABY NAME MARKET</text>
  <text x="20" y="68" fill="#74C69D" font-family="monospace" font-size="11">PREDICTION SLIP</text>
  <text x="380" y="68" text-anchor="end" fill="${color}" font-family="monospace" font-size="11" font-weight="bold">${status}</text>
  <circle cx="0" cy="112" r="14" fill="#F7F2E8"/>
  <circle cx="400" cy="112" r="14" fill="#F7F2E8"/>
  <line x1="25" y1="112" x2="375" y2="112" stroke="#C9BA9B" stroke-width="1" stroke-dasharray="5,4"/>
  <text x="20" y="134" fill="#9CA3AF" font-family="monospace" font-size="9" letter-spacing="2">MARKET</text>
  ${rows([
    ['Year',   String(slip.year),          false, 156],
    ['Placed', formatDate(slip.purchasedAt), false, 178],
  ])}
  <line x1="20" y1="196" x2="380" y2="196" stroke="#E5D9C3" stroke-width="1"/>
  <text x="20" y="218" fill="#9CA3AF" font-family="monospace" font-size="9" letter-spacing="2">BET</text>
  ${rows([
    ['Amount',   amount,            true,  240],
    ['Category', category,          false, 262],
    ['Name',     slip.poolName,     true,  284],
  ])}
  <line x1="20" y1="308" x2="380" y2="308" stroke="#E5D9C3" stroke-width="1"/>
  <text x="20" y="326" fill="#9CA3AF" font-family="monospace" font-size="9" letter-spacing="2">RESOLUTION</text>
  ${rows([
    ['Resolves On', formatDeadline(slip.deadline), false, 348],
  ])}
  <line x1="20" y1="362" x2="380" y2="362" stroke="#E5D9C3" stroke-width="1"/>
  <text x="20" y="382" fill="#9CA3AF" font-family="monospace" font-size="9" letter-spacing="2">PAYOUT</text>
  ${rows([
    ['Pool Total',     poolTotal,   false, 404],
    ['Win Multiplier', multiplier,  true,  420],
  ])}
  <circle cx="0" cy="428" r="14" fill="#F7F2E8"/>
  <circle cx="400" cy="428" r="14" fill="#F7F2E8"/>
  <line x1="25" y1="428" x2="375" y2="428" stroke="#C9BA9B" stroke-width="1" stroke-dasharray="5,4"/>
  <text x="20" y="449" fill="#9CA3AF" font-family="monospace" font-size="9" letter-spacing="2">SLIP ID</text>
  ${barcodeLines(slip.tokenId)}
  <text x="380" y="476" text-anchor="end" fill="#1B4332" font-family="monospace" font-size="22" font-weight="bold">${zeroPad8(slip.tokenId)}</text>
  <text x="200" y="530" text-anchor="middle" fill="#9CA3AF" font-family="monospace" font-size="9" letter-spacing="1">BABYNAMES.MARKET</text>
</svg>`;
}

// ---------------------------------------------------------------------------
// Preview scenarios
// ---------------------------------------------------------------------------

const SCENARIOS = [
  {
    name: 'active-single-bet',
    slip: {
      tokenId:           1,
      poolName:          'OLIVIA',
      year:              2025,
      categoryType:      0,        // CAT_SINGLE
      gender:            0,        // Female
      position:          1,
      amount:            5_000_000_000_000_000_000n,   // $5 (normalized 1e18)
      tokenDecimals:     6,
      purchasedAt:       1735689600,  // 2025-01-01
      deadline:          1778371200,  // 2026-05-10 (Mothers Day 2026)
      currentTime:       1738368000,  // 2025-02-01
      poolCollateral:    15_000_000_000_000_000_000n,  // $15 in pool
      categoryCollateral:120_000_000_000_000_000_000n, // $120 category total
      resolved:          false,
      won:               false,
    },
  },
  {
    name: 'won-topn-bet',
    slip: {
      tokenId:           42,
      poolName:          'THEO',
      year:              2025,
      categoryType:      3,        // CAT_TOP_N
      gender:            1,        // Male
      position:          10,
      amount:            10_000_000_000_000_000_000n,  // $10
      tokenDecimals:     6,
      purchasedAt:       1735689600,
      deadline:          1778371200,  // 2026-05-10 (Mothers Day 2026)
      currentTime:       1780272000, // after deadline
      poolCollateral:    30_000_000_000_000_000_000n,
      categoryCollateral:240_000_000_000_000_000_000n,
      resolved:          true,
      won:               true,
    },
  },
  {
    name: 'lost-exacta-bet',
    slip: {
      tokenId:           7,
      poolName:          'CHARLOTTE',
      year:              2025,
      categoryType:      1,        // CAT_EXACTA
      gender:            0,        // Female
      position:          2,
      amount:            25_000_000_000_000_000_000n,  // $25
      tokenDecimals:     6,
      purchasedAt:       1735689600,
      deadline:          1778371200,  // 2026-05-10 (Mothers Day 2026)
      currentTime:       1780272000,
      poolCollateral:    50_000_000_000_000_000_000n,
      categoryCollateral:200_000_000_000_000_000_000n,
      resolved:          true,
      won:               false,
    },
  },
  {
    name: 'closed-trifecta-bet',
    slip: {
      tokenId:           99,
      poolName:          'EMMA',
      year:              2025,
      categoryType:      2,        // CAT_TRIFECTA
      gender:            0,        // Female
      position:          3,
      amount:            1_000_000_000_000_000_000n,   // $1
      tokenDecimals:     6,
      purchasedAt:       1735689600,
      deadline:          1778371200,  // 2026-05-10 (Mothers Day 2026)
      currentTime:       1780272000,  // after deadline
      poolCollateral:    5_000_000_000_000_000_000n,
      categoryCollateral:50_000_000_000_000_000_000n,
      resolved:          false,
      won:               false,
    },
  },
];

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  if (!fs.existsSync(PREVIEW_DIR)) {
    fs.mkdirSync(PREVIEW_DIR, { recursive: true });
  }

  for (const scenario of SCENARIOS) {
    const svg  = renderSVG(scenario.slip);
    const file = path.join(PREVIEW_DIR, `${scenario.name}.svg`);
    fs.writeFileSync(file, svg, 'utf8');
    console.log(`✓ Generated: previews/${scenario.name}.svg`);
  }

  console.log(`\n✓ ${SCENARIOS.length} previews written to ${PREVIEW_DIR}`);
}

main();

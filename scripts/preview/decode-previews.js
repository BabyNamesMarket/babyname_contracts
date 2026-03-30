#!/usr/bin/env node
/**
 * decode-previews.js
 *
 * Reads .uri files from previews/ (data:application/json;base64,… output from
 * the Forge GeneratePreviews script), decodes the JSON, extracts the base64 SVG
 * image, and writes .svg files.
 *
 * Usage: node scripts/preview/decode-previews.js
 */
'use strict';

const fs   = require('fs');
const path = require('path');

const PREVIEW_DIR = path.resolve(__dirname, '../../previews');

const uriFiles = fs.readdirSync(PREVIEW_DIR).filter(f => f.endsWith('.uri'));
if (uriFiles.length === 0) {
  console.error('No .uri files found in previews/');
  process.exit(1);
}

for (const file of uriFiles) {
  const raw = fs.readFileSync(path.join(PREVIEW_DIR, file), 'utf8').trim();

  // Format: data:application/json;base64,<base64-json>
  const jsonB64 = raw.replace(/^data:application\/json;base64,/, '');
  const json = JSON.parse(Buffer.from(jsonB64, 'base64').toString('utf8'));

  // json.image = "data:image/svg+xml;base64,<base64-svg>"
  const svgB64 = json.image.replace(/^data:image\/svg\+xml;base64,/, '');
  const svg = Buffer.from(svgB64, 'base64').toString('utf8');

  const outName = file.replace('.uri', '.svg');
  fs.writeFileSync(path.join(PREVIEW_DIR, outName), svg, 'utf8');
  console.log(`Decoded: ${file} -> ${outName}`);
}

console.log(`\n${uriFiles.length} SVGs extracted.`);

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const SOURCE_ROOT = path.resolve(ROOT, "../babynames_market/public/data/name-ranks");
const OUTPUT_ROOT = path.join(ROOT, "data");
const { StandardMerkleTree } = require(path.join(
  ROOT,
  "../babynames_market/node_modules/@openzeppelin/merkle-tree"
));

function collectNames(genderDir) {
  const dir = path.join(SOURCE_ROOT, genderDir);
  const files = fs.readdirSync(dir).filter((file) => file.endsWith(".json")).sort();
  const names = new Set();

  for (const file of files) {
    const entries = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
    for (const entry of entries) {
      const rawName = entry[0];
      if (typeof rawName !== "string") continue;
      const normalized = rawName.trim().toLowerCase();
      if (normalized) names.add(normalized);
    }
  }

  return Array.from(names).sort();
}

function sampleNameFor(genderDir, names) {
  const preferred = genderDir === "boys" ? "liam" : "olivia";
  if (names.includes(preferred)) return preferred;
  return names[0];
}

function proofFor(tree, targetName) {
  for (const [index, value] of tree.entries()) {
    if (value[0] === targetName) {
      return tree.getProof(index);
    }
  }
  throw new Error(`Missing proof target: ${targetName}`);
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2) + "\n");
}

function buildGenderArtifacts(genderDir) {
  const names = collectNames(genderDir);
  const genderValue = genderDir === "boys" ? 0 : 1;
  const tree = StandardMerkleTree.of(
    names.map((name) => [name, genderValue]),
    ["string", "uint8"]
  );
  const sampleName = sampleNameFor(genderDir, names);

  return {
    names,
    tree: tree.dump(),
    root: tree.root,
    count: names.length,
    sampleName,
    sampleProof: proofFor(tree, sampleName),
  };
}

function main() {
  const boys = buildGenderArtifacts("boys");
  const girls = buildGenderArtifacts("girls");

  writeJson(path.join(OUTPUT_ROOT, "name-list-boys.json"), boys.names);
  writeJson(path.join(OUTPUT_ROOT, "name-list-girls.json"), girls.names);
  writeJson(path.join(OUTPUT_ROOT, "merkle-tree-boys.json"), boys.tree);
  writeJson(path.join(OUTPUT_ROOT, "merkle-tree-girls.json"), girls.tree);
  writeJson(path.join(OUTPUT_ROOT, "name-merkle-roots.json"), {
    generatedAt: new Date().toISOString(),
    source: "../babynames_market/public/data/name-ranks",
    boys: {
      root: boys.root,
      count: boys.count,
      sampleName: boys.sampleName,
      sampleProof: boys.sampleProof,
    },
    girls: {
      root: girls.root,
      count: girls.count,
      sampleName: girls.sampleName,
      sampleProof: girls.sampleProof,
    },
  });

  process.stdout.write(
    `boys=${boys.count} root=${boys.root}\ngirls=${girls.count} root=${girls.root}\n`
  );
}

main();

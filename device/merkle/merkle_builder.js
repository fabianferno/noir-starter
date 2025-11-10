#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { program } = require('commander');
const { stringify: tomlStringify } = require('@iarna/toml');
const { buildPoseidon } = require('circomlibjs');

const FIELD_PRIME = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');
const TREE_HEIGHT = 16;

function hexToField(hex) {
  const clean = hex.startsWith('0x') ? hex.slice(2) : hex;
  if (clean.length === 0) {
    return BigInt(0);
  }
  const value = BigInt(`0x${clean}`);
  return value % FIELD_PRIME;
}

function bigintToHex(value) {
  return `0x${value.toString(16).padStart(64, '0')}`;
}

function bigintToDecimal(value) {
  return value.toString(10);
}

function padToPowerOfTwo(leaves, height) {
  const targetSize = 1 << height;
  if (leaves.length > targetSize) {
    throw new Error(`Too many leaves (got ${leaves.length}, max ${targetSize}) for height ${height}`);
  }
  const padded = leaves.slice();
  while (padded.length < targetSize) {
    padded.push(BigInt(0));
  }
  return padded;
}

function buildMerkleTree(poseidon, leaves, height) {
  let currentLevel = padToPowerOfTwo(leaves, height);
  const layers = [currentLevel];
  for (let level = 0; level < height; level += 1) {
    const nextLevel = [];
    for (let i = 0; i < currentLevel.length; i += 2) {
      const left = currentLevel[i];
      const right = currentLevel[i + 1];
      const parent = poseidonHash(poseidon, [left, right]);
      nextLevel.push(parent);
    }
    layers.push(nextLevel);
    currentLevel = nextLevel;
  }
  return layers;
}

function poseidonHash(poseidon, inputs) {
  const hash = poseidon(inputs);
  return poseidon.F.toObject(hash);
}

function buildPath(layers, index) {
  const pathElements = [];
  const pathIndices = [];
  let idx = index;
  for (let level = 0; level < layers.length - 1; level += 1) {
    const layer = layers[level];
    const isRight = idx % 2 === 1;
    const siblingIndex = isRight ? idx - 1 : idx + 1;
    pathElements.push(layer[siblingIndex]);
    pathIndices.push(isRight ? 1 : 0);
    idx = Math.floor(idx / 2);
  }
  const root = layers[layers.length - 1][0];
  return { root, pathElements, pathIndices };
}

function generateMockFrame(frameIndex, nonceHex) {
  const fakeFrame = crypto.createHash('sha256').update(`frame-${frameIndex}`).digest();
  const fakeImu = crypto.createHash('sha256').update(`imu-${frameIndex}`).digest();
  const depthMeanQ = 42000 + frameIndex * 137;
  const depthStdQ = 73000 + frameIndex * 53;
  return {
    frame_index: frameIndex,
    frame_hash_hex: fakeFrame.toString('hex'),
    depth_mean_q: depthMeanQ,
    depth_std_q: depthStdQ,
    imu_hash_hex: fakeImu.toString('hex'),
    nonce_hex: nonceHex,
  };
}

async function buildPoseidonInstance() {
  const poseidon = await buildPoseidon();
  return poseidon;
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function loadFrames(inputPath, frameCount, nonceHex) {
  if (inputPath) {
    const raw = fs.readFileSync(inputPath, 'utf8');
    const data = JSON.parse(raw);
    if (!Array.isArray(data)) {
      throw new Error('Input JSON must be an array of frame metadata objects');
    }
    return data;
  }
  const frames = [];
  for (let i = 0; i < frameCount; i += 1) {
    frames.push(generateMockFrame(i, nonceHex));
  }
  return frames;
}

function frameToLeafInputs(frame) {
  const frameHashEl = hexToField(frame.frame_hash_hex);
  const imuHashEl = hexToField(frame.imu_hash_hex);
  const nonceField = hexToField(frame.nonce_hex);
  return {
    frameHashEl,
    imuHashEl,
    nonceField,
    depthMeanQ: BigInt(frame.depth_mean_q),
    depthStdQ: BigInt(frame.depth_std_q),
  };
}

function computeLeaf(poseidon, frame) {
  const { frameHashEl, imuHashEl, nonceField, depthMeanQ, depthStdQ } = frameToLeafInputs(frame);
  const leaf = poseidonHash(poseidon, [frameHashEl, depthMeanQ, depthStdQ, imuHashEl, nonceField]);
  return {
    leaf,
    frameHashEl,
    imuHashEl,
    nonceField,
    depthMeanQ,
    depthStdQ,
  };
}

async function main() {
  program
    .option('-i, --input <path>', 'Path to frame metadata JSON input file')
    .option('-o, --out-dir <path>', 'Directory to write bundle outputs', path.join(process.cwd(), 'bundle_mock'))
    .option('-n, --count <number>', 'Number of mock frames to generate when no input supplied', (value) => parseInt(value, 10), 4)
    .option('-t, --target-index <number>', 'Zero-based leaf index to export for Noir inputs', (value) => parseInt(value, 10), 0)
    .option('--nonce <hex>', 'Optional override for nonce hex (defaults to random 32 bytes)')
    .option('--no-write', 'Skip writing files to disk, just print to stdout')
    .parse(process.argv);

  const opts = program.opts();
  const targetIndex = opts.targetIndex || 0;
  const nonceHex = opts.nonce ? opts.nonce.replace(/^0x/, '') : crypto.randomBytes(32).toString('hex');

  const poseidon = await buildPoseidonInstance();
  const frames = loadFrames(opts.input, opts.count, nonceHex);
  const leaves = frames.map((frame) => computeLeaf(poseidon, frame));
  const leafValues = leaves.map((entry) => entry.leaf);
  const layers = buildMerkleTree(poseidon, leafValues, TREE_HEIGHT);
  const { root, pathElements, pathIndices } = buildPath(layers, targetIndex);

  const target = leaves[targetIndex];
  if (!target) {
    throw new Error(`No target leaf at index ${targetIndex}`);
  }

  const rootHex = bigintToHex(root);
  const rootDecimal = bigintToDecimal(root);
  const bundle = {
    tree_height: TREE_HEIGHT,
    nonce_hex: nonceHex,
    root_hex: rootHex,
    root_decimal: rootDecimal,
    frames: frames.map((frame, idx) => ({
      ...frame,
      leaf_hex: bigintToHex(leaves[idx].leaf),
      leaf_decimal: bigintToDecimal(leaves[idx].leaf),
    })),
    witness: {
      target_index: targetIndex,
      frame_hash_el: bigintToDecimal(target.frameHashEl),
      depth_mean_q: target.depthMeanQ.toString(),
      depth_std_q: target.depthStdQ.toString(),
      imu_hash_el: bigintToDecimal(target.imuHashEl),
      nonce_pub: bigintToDecimal(target.nonceField),
      path: pathElements.map((el) => bigintToDecimal(el)),
      path_indices: pathIndices.map((i) => i.toString()),
    },
  };

  const proverTomlStrict = {
    root: bundle.root_decimal,
    nonce_pub: bundle.witness.nonce_pub,
    frame_hash_el: bundle.witness.frame_hash_el,
    depth_mean_q: bundle.witness.depth_mean_q,
    depth_std_q: bundle.witness.depth_std_q,
    imu_hash_el: bundle.witness.imu_hash_el,
    path: bundle.witness.path,
    path_indices: bundle.witness.path_indices,
  };

  const proverTomlContent = tomlStringify(proverTomlStrict);

  if (!opts.write) {
    console.log(JSON.stringify(bundle, null, 2));
    console.log('\n--- Prover.toml ---');
    console.log(proverTomlContent);
    return;
  }

  ensureDir(opts.outDir);
  const bundlePath = path.join(opts.outDir, 'bundle.json');
  fs.writeFileSync(bundlePath, JSON.stringify(bundle, null, 2));
  const proverPath = path.join(opts.outDir, 'Prover.toml');
  fs.writeFileSync(proverPath, proverTomlContent);
  const publicPath = path.join(opts.outDir, 'public.json');
  fs.writeFileSync(publicPath, JSON.stringify({
    root_decimal: bundle.root_decimal,
    root_hex: bundle.root_hex,
    nonce_pub: bundle.witness.nonce_pub,
  }, null, 2));

  console.log(`Bundle written to ${bundlePath}`);
  console.log(`Prover inputs written to ${proverPath}`);
  console.log(`Public inputs written to ${publicPath}`);
  console.log(`Merkle root (hex): ${bundle.root_hex}`);
  console.log(`Merkle root (decimal): ${bundle.root_decimal}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

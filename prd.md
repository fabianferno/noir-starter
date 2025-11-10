# Project Spec and Implementation Plan

**Project:** IRL Video Proofing for EthGlobal hackathon
**Owner:** Fabian
**Purpose:** Build a Raspberry Pi device with two cameras that produces cryptographic proofs a frame was recorded in real life and not a generative replay. The device will capture stereo frames and sensor data, compute depth metrics, commit frame-level evidence into a Merkle tree, sign roots with the TPM, and produce a zero knowledge proof that a sampled frame met physical-world checks.

---

## 1. One-line summary for dev

Build a Pi-based capture device that: capture stereo frames + IMU + nonce, compute per-frame commitment (frame hash + quantized depth stats + imu hash + nonce), append leaves to a Poseidon Merkle tree, sign Merkle root with TPM, generate a SNARK proving a leaf meets threshold and is included in signed root, and provide a verifier that checks TPM signature and SNARK. Deliver artifacts: signed root, proof, public inputs, and a small verification UI/CLI.

---

## 2. Threat model and goals

* Goal: Make it difficult to claim a generated or replayed video is IRL-captured by this device.
* Attacker capabilities: Has prior high quality replays, knows system design, might try to replay a recorded video on a screen, or try to forge data.
* Defenses:

  * TPM-backed signing so private key cannot be exported.
  * Stereo depth and IMU correlation as sensor evidence.
  * Server-issued short-lived nonce to prevent pre-recording.
  * ZK proof of inclusion and simple predicates so verifier can accept compact proof without raw data.

---

## 3. High-level architecture

* Device (Raspberry Pi)

  * Two USB cameras or two Pi cameras (dev choice: two USB cameras as per decision)
  * IMU (optional but recommended)
  * TPM or TEE for signing (non-exportable key)
  * Local storage for frames and metadata
  * Optional small display or LED for showing server nonce in scene
* Server or prover host (optional)

  * Issue short nonces on request to device
  * (Optional) More powerful machine for proof generation if Pi is too slow
* Verifier

  * Validates TPM signature on Merkle root
  * Verifies SNARK proof and public inputs
  * Shows audit info: depth std, IMU vs optical flow charts, inclusion proof path

High level data flow:

1. Capture frame pair + IMU + timestamp + visible nonce
2. Compute per-frame frame_hash = SHA256(image), compute disparity -> depth_mean and depth_std, quantize depth metrics
3. Compute imu_hash = SHA256(imu chunk)
4. Compute leaf = Poseidon(frame_hash_el, depth_mean_q, depth_std_q, imu_hash_el, nonce_q)
5. Append leaf to Poseidon Merkle tree and produce merkle_root for chunk
6. TPM signs merkle_root
7. Generate SNARK that proves a leaf with depth_std_q >= THRESH exists and is included in merkle_root
8. Verifier checks TPM signature and SNARK proof

---

## 4. Hardware checklist

* Raspberry Pi 4 or Pi 5 with sufficient RAM and SD/SSD storage
* Two identical USB webcams (or two Pi Camera Modules; we will implement with USB webcams)
* Rigid stereo mount and baseline approx 50-150 mm depending on expected scene distances
* IMU sensor module (e.g., MPU6050) connected via I2C
* TPM chip or module supported by tpm2-tools and Linux (e.g., Infineon TPM or Raspberry Pi HAT with TPM)
* Small display or LED array to show nonce inside the scene (optional but recommended)
* Power supply and cabling, USB hub if needed

---

## 5. Software stack and libs

* Pi device

  * OS: Raspberry Pi OS (64-bit recommended)
  * Python 3 with OpenCV (cv2) for capture and stereo disparity
  * numpy, pycryptodome or hashlib for hashing
  * Node.js for Poseidon and Merkle tree helpers (or use a Python Poseidon lib if available)
  * tpm2-tools (tpm2_sign, tpm2_create, etc.) for TPM signing
  * Optional: nargo / Noir and Barretenberg (bb) or circom + snarkjs depending on final ZK choice (user selected Noir earlier). Use Noir and Barretenberg per walkthrough.
* Verifier

  * Node.js/Browser UI or CLI
  * Verify TPM signature with device public key certificate
  * Verify SNARK proof using Barretenberg verify or a precompiled verifier

---

## 6. Exact on-device steps to implement

This is the sequence to run for each recording chunk. The dev should implement these components as modular scripts or services.

A. Capture pipeline

1. Initialize camera devices and IMU. Use `cap.grab()` on both cameras then `cap.retrieve()` to minimize desync.
2. Lock camera settings: exposure, white balance, gain. Turn off auto settings if possible.
3. Before starting capture request a nonce from server or generate a secure random nonce locally and make it visible to camera via overlay or LED display. Ensure nonce is visible in frames.
4. For each frame pair:

   * Read left and right frames
   * Rectify frames using precomputed calibration maps
   * Convert to grayscale for disparity if needed
   * Compute disparity with `StereoSGBM` or `StereoBM`
   * Compute depth values from disparity or use disparity directly
   * Compute `depth_mean` and `depth_std` from valid depth pixels
   * Quantize metrics: `depth_mean_q = round(depth_mean * 1000)` and `depth_std_q = round(depth_std * 1000)`
   * Compute `frame_hash = SHA256(frame_bytes)` (store frame as JPEG then hash the bytes)
   * Compute `imu_hash = SHA256(imu_chunk_bytes)` covering the same timestamps
   * Build per-frame JSON metadata with timestamp, depth stats, nonce, imu sample
   * Compute Poseidon-compatible field elements for `frame_hash` and `imu_hash` (see Poseidon conversion guidance below)
   * Compute leaf = Poseidon([frame_hash_el, depth_mean_q, depth_std_q, imu_hash_el, nonce_q])
   * Append leaf to local Merkle tree builder and store per-frame hash and leaf index

B. Merkle tree and signing

1. After N frames or on-demand compute the `merkle_root` for the chunk
2. Use TPM to sign `merkle_root`. Example:

   * convert root hex to binary: `echo -n "<root_hex>" | xxd -r -p > root.bin`
   * sign: `tpm2_sign -c <key_handle> -g sha256 -o root.sig root.bin`
   * export signature: `base64 root.sig > root.sig.b64`
3. Persist `root`, `root.sig.b64`, and a compact bundle of per-frame metadata (`frame_index`, `frame_hash`, `depth_mean_q`, `depth_std_q`, `leaf_index`, `path` if you produce it) and some representative frames and disparity snapshots.

C. Witness and proof generation (Noir)

1. Convert required witness inputs into the format Noir expects:

   * `root` as public Field
   * `nonce_pub` as public Field
   * Private witness: `frame_hash_el`, `depth_mean_q`, `depth_std_q`, `imu_hash_el`, `path` array (sibling nodes) and `path_indices`
2. Run `nargo execute` to generate witness (this runs the Noir program to create witness)
3. Run Barretenberg `bb prove` on the ACIR produced by Noir or use the recommended Noir + Barretenberg flow to create the proof. Note Pi proof generation can be slow. For hackathon initial flow produce witness on Pi and run proof generation on a faster machine if needed. Keep clear logs documenting where the proof was generated.

---

## 7. Important code snippets and examples for dev

A. Stereo capture and depth metrics (Python)

```python
import cv2
import numpy as np
import hashlib
import json
import time

# assume left_map1,left_map2,right_map1,right_map2 loaded from calibration npz
capL = cv2.VideoCapture(0)
capR = cv2.VideoCapture(1)
capL.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
capL.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
capR.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
capR.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

stereo = cv2.StereoSGBM_create(minDisparity=0, numDisparities=128, blockSize=5)
def sha256_hex(b): return hashlib.sha256(b).hexdigest()

retL, retR = False, False
while True:
    capL.grab(); capR.grab()
    retL, frameL = capL.retrieve()
    retR, frameR = capR.retrieve()
    if not retL or not retR: break
    # rectify
    rectL = cv2.remap(frameL, left_map1, left_map2, cv2.INTER_LINEAR)
    rectR = cv2.remap(frameR, right_map1, right_map2, cv2.INTER_LINEAR)
    grayL = cv2.cvtColor(rectL, cv2.COLOR_BGR2GRAY)
    grayR = cv2.cvtColor(rectR, cv2.COLOR_BGR2GRAY)
    disp = stereo.compute(grayL, grayR).astype(np.float32) / 16.0
    valid = disp > 0
    depths = disp[valid]
    depth_mean = float(np.mean(depths))
    depth_std = float(np.std(depths))
    depth_mean_q = int(round(depth_mean * 1000))
    depth_std_q = int(round(depth_std * 1000))
    _, jpg = cv2.imencode('.jpg', rectL, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
    frame_bytes = jpg.tobytes()
    frame_hash = sha256_hex(frame_bytes)
    # imu_bytes should be collected and hashed similarly
    # persist metadata and compute next steps
```

B. Merkle root creation (Python conceptual)

* Use a Poseidon JS lib or Python Poseidon to compute leaves. Use the same Poseidon parameters for Noir and JS.
* Simple Merkle root builder can be implemented by hashing sibling pairs with Poseidon repeatedly. Save path siblings and indices for each leaf.

C. TPM sign commands

```bash
# root_hex is hex string of bytes
echo -n "<root_hex>" | xxd -r -p > root.bin
tpm2_sign -c 0x81010002 -g sha256 -o root.sig root.bin
base64 root.sig > root.sig.b64
```

D. Noir program skeleton (save as src/main.nr)

```rust
use "std::hashes.poseidon" as poseidon;
const THRESH: Field = 50;
const TREE_HEIGHT: u32 = 16u32;

fn merkle_verify(root: Field, leaf: Field, path: [Field; TREE_HEIGHT], path_indices: [Field; TREE_HEIGHT]) -> bool {
    let mut h = leaf;
    let mut i = 0u32;
    while i < TREE_HEIGHT {
        let left = if path_indices[i] == 0 { h } else { path[i] };
        let right = if path_indices[i] == 0 { path[i] } else { h };
        h = poseidon::hash2(left, right);
        i = i + 1u32;
    }
    return h == root;
}

fn main(
    root: pub Field,
    nonce_pub: pub Field,
    frame_hash_el: Field,
    depth_mean_q: Field,
    depth_std_q: Field,
    imu_hash_el: Field,
    path: [Field; TREE_HEIGHT],
    path_indices: [Field; TREE_HEIGHT],
) -> pub bool {
    let leaf = poseidon::hash5(frame_hash_el, depth_mean_q, depth_std_q, imu_hash_el, nonce_pub);
    let ok = merkle_verify(root, leaf, path, path_indices);
    let depth_ok = depth_std_q >= THRESH;
    constrain(ok == true);
    constrain(depth_ok == true);
    return true;
}
```

E. Node.js Poseidon + Merkle helper conceptual steps

* Convert SHA256 hex to field element in the same field Noir uses (truncate safely or compress with Poseidon)
* Use a Poseidon implementation matching Noir params to compute leaf
* Insert leaf into Merkle tree and export path siblings and indices
* Write `Prover.toml` or `input.json` with strings representing big integers

F. Noir / Barretenberg commands (dev machine)

```bash
nargo new real_frame_proof
# put src/main.nr
nargo check
nargo compile
# create Prover.toml or pass inputs to nargo execute
nargo execute --input Prover.toml
# use Barretenberg to produce proof
# example conceptual commands; adapt to produced target paths
bb prove -b ./target/circuits.json -w ./target/witness -o ./target/proof
bb write_vk -b ./target/circuits.json -o ./target/vk
bb verify -p ./target/proof -k ./target/vk
```

---

## 8. Verifier workflow (what verifier should do)

1. Receive bundle: `merkle_root`, `root.sig.b64`, `device_id` or device public key certificate, `proof`, `public_inputs` (root, index, nonce), and optionally a small sample frame if needed.
2. Verify TPM signature on `merkle_root` using the device public key. If this fails reject.
3. Verify SNARK proof against the `public_inputs` using Barretenberg verify (or the verifier API). If this fails reject.
4. If both pass, present audit details: depth_std, depth_mean, imu vs optical flow correlation graph and inclusion proof details. Accept frame as proven IRL under stated thresholds.

---

## 9. Testing plan and experiments to run

* Initial unit tests

  * Calibrate stereo pair using chessboard. Save calibration maps and verify rectification results.
  * Capture static scenes and compute disparity and depth stats. Log expected ranges.
* Replay test

  * Record a real scene, play it on a monitor, re-record the screen with the stereo rig. Compare `depth_std` values for real vs replay cases. Expect significant drop for replay.
* IMU vs optical flow correlation

  * Record camera motion and log IMU samples. Compute average optical flow magnitude. Confirm correlation. Replay test should break correlation.
* End-to-end cryptographic test

  * Create leaves, compute merkle_root, sign with TPM and verify signature.
  * Create a small Noir circuit and prove locally that a leaf with depth_std_q >= threshold is included in root. Verify proof.
* Integration test

  * Generate a full bundle: signed root + proof + public inputs. Run verifier to confirm acceptance. Test both real and replay cases.

---

## 10. Acceptance criteria for deliverables

These are the things to be delivered and what constitutes "done."

A. Device capture module

* Implementation that captures synchronized left/right frames and IMU samples and outputs per-frame metadata including timestamps, `frame_hash`, `depth_mean_q`, `depth_std_q`, `imu_hash`, `nonce`.
* Saves representative frames and disparity snapshots.

B. Merkle builder and TPM signing

* Poseidon-based leaf builder that matches Noir poseidon parameters.
* Merkle builder that records path and index for each leaf.
* TPM signing command integrated and producing `root.sig.b64`. Verified by a test script with the device public key.

C. Noir circuit and proof generator

* Noir program source implementing leaf build verification and `depth_std_q >= THRESH` and Merkle inclusion.
* Script to generate `Prover.toml` or `input.json` from device outputs.
* End-to-end proof generation that produces `proof` and `public.json` with `root` and `nonce`. Document if proof generation is done on Pi or offloaded.

D. Verifier

* CLI or minimal web UI that:

  * Verifies TPM signature for `merkle_root` with device public key.
  * Verifies SNARK proof with public inputs.
  * Displays depth stats and verdict PASS/FAIL.

E. Documentation and test logs

* README.md with exact install steps, commands, and expected outputs.
* Short test report showing real vs replay metrics and test evidence.
* Note: Document which steps ran on Pi vs remote machine for proof generation.

---

## 11. Pitfalls, gotchas and mitigations

* Camera sync: USB cams are not hardware-synced. Mitigate via `grab` then `retrieve` pattern and using identical models. If sync issues hurt depth quality, consider switching to Pi cameras or stereo sync board later.
* Poseidon param mismatch: Must use same Poseidon implementation and parameters for Noir and device-side leaf computation. Test vectors are critical.
* TPM key handling: Create non-exportable TPM keys and store public cert for verifier. Test signing and verification early.
* Proof generation speed: Barretenberg proving is heavy on Pi. Consider generating proof on a stronger machine but document and sign merkle_root on the Pi to anchor trust.
* Quantization thresholds: Choose quantization scale and threshold after empirical tests. Document chosen values and reasoning.

---

## 12. Suggested file layout and git repo structure

```
/device
  /capture
    capture.py                   # stereo capture + depth summary + imu logging
    calibrate.py                 # stereo calibration utility
  /merkle
    merkle_builder.js            # Poseidon leaf + merkle tree
    poseidon_helpers.js
  /sign
    tpm_sign.sh                  # sign root script
  /bundles
    bundle_<timestamp>.tar.gz    # produced audit bundle
/noir
  src/main.nr                    # noir circuit
  Prover.toml                    # example input for nargo execute
  build_and_prove.sh             # compile, execute, prove scripts
/verifier
  verify_cli.js                  # verify TPM sig + proof
  ui/                            # optional simple web UI
README.md
TESTS.md
```

---

## 13. Immediate action items for your dev

1. Get hardware and test capture

* Connect two USB cams, mount them rigidly, run `calibrate.py` and produce rectification maps.

2. Implement capture.py

* Capture left/right, compute disparity, compute depth_mean and depth_std, hash frame, log IMU and nonce presence.

3. Implement Poseidon leaf builder and JS merkle tree

* Ensure Poseidon params match Noir. Produce tree, path and root.

4. Create TPM key and test signing flow

* Use tpm2-tools to create a persistent key handle and test `tpm2_sign` and signature verification.

5. Implement Noir program file `src/main.nr` and local test harness

* Start with only depth threshold check then add merkle inclusion.

6. Wire up proof flow

* Generate witness with nargo, create proof with bb on dev machine or Pi if feasible, verify locally.

7. Build verifier CLI/UI that verifies both TPM signature and SNARK proof
8. Run replay experiment and adjust threshold quantization value
9. Prepare README and a short demo script that produces one signed bundle and proof and runs the verifier.

---

## 14. Helpful debugging commands and tips

* Camera frames: `ffmpeg -f v4l2 -list_formats all -i /dev/video0` to inspect supported formats
* Capture test: run the Python capture loop and save 10 frames with disparity arrays to inspect quality
* TPM test: `tpm2_createprimary`, `tpm2_create`, `tpm2_load`, `tpm2_sign` and `tpm2_readpublic` for key lifecycle management
* Noir compile: `nargo check`, `nargo compile`
* Barretenberg proof: `bb prove`, `bb verify` — run on a beefy machine if Pi is slow

---

## 15. Deliverables checklist to hand to dev (copy/paste)

* [ ] Stereo calibration maps produced and checked
* [ ] `capture.py` that produces: rectified left/right frames, disparity snapshots, `depth_mean_q`, `depth_std_q`, `frame_hash`, `imu_hash`, and timestamped JSON for each frame
* [ ] `merkle_builder.js` producing Poseidon leaves, merkle_root, and per-leaf path + index
* [ ] `tpm_sign.sh` that signs merkle_root and outputs `root.sig.b64`
* [ ] Noir program `src/main.nr` implementing Poseidon leaf check, merkle inclusion, and `depth_std_q >= THRESH`
* [ ] `build_and_prove.sh` to compile Noir, execute witness and produce `proof` using Barretenberg, documented where proof runs
* [ ] `verifier/verify_cli.js` that validates TPM signature and SNARK proof and prints PASS/FAIL and metrics
* [ ] Basic demo script `demo_run.sh` that runs a full flow and outputs the final bundle with proof and signed root
* [ ] README.md with exact install and run instructions and test record showing real vs replay numbers

---

If you want, I will now generate the following artifacts immediately in this chat for your dev to copy:

* `README.md` skeleton with exact commands for install and run
* `capture.py` minimal working script for stereo capture + depth metrics
* `merkle_builder.js` skeleton that uses Poseidon and creates a Merkle root and path
* `src/main.nr` Noir program file (full ready-to-run)
* `build_and_prove.sh` script with the exact nargo and bb commands

Pick which of those you want first and I will paste them here.

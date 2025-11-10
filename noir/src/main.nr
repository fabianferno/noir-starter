use dep::std::hashes::poseidon;

const TREE_HEIGHT: u32 = 16;
const MIN_DEPTH_STD_Q: Field = 65000;
const MAX_DEPTH_STD_Q: Field = 200000;
const MAX_DEPTH_MEAN_Q: Field = 500000;

fn merkle_verify(root: Field, leaf: Field, path: [Field; TREE_HEIGHT], path_indices: [Field; TREE_HEIGHT]) -> bool {
    let mut acc = leaf;
    let mut level: u32 = 0;

    while level < TREE_HEIGHT {
        let idx = path_indices[level];
        // Enforce that idx is binary (0 or 1)
        assert(idx * (idx - 1) == 0, "path index must be binary");
        let sibling = path[level];
        let is_right = idx == 1;
        let left = if is_right { sibling } else { acc };
        let right = if is_right { acc } else { sibling };
        acc = poseidon::hash2(left, right);
        level = level + 1;
    }

    return acc == root;
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
    assert(nonce_pub != 0, "nonce must not be zero");
    assert(depth_std_q >= MIN_DEPTH_STD_Q, "depth std below threshold");
    assert(depth_std_q <= MAX_DEPTH_STD_Q, "depth std exceeds bound");
    assert(depth_mean_q <= MAX_DEPTH_MEAN_Q, "depth mean exceeds bound");

    let leaf = poseidon::hash5(frame_hash_el, depth_mean_q, depth_std_q, imu_hash_el, nonce_pub);
    let inclusion_ok = merkle_verify(root, leaf, path, path_indices);
    assert(inclusion_ok, "merkle path invalid");

    return true;
}

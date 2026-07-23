"""Normalized Maximum Eigengap Spectral Clustering (NME-SC) for speaker diarization.

Ported from NVIDIA NeMo's `offline_clustering.py` (Tae Jin Park et al., "Auto-Tuning
Spectral Clustering for Speaker Diarization Using Normalized Maximum Eigengap",
IEEE Signal Processing Letters 27 (2019), https://arxiv.org/abs/2003.02405).
Single-scale only: NeMo's multiscale fusion and synthetic anchor-embedding
enhancement (for very short recordings) are not ported, since sherpa-onnx
extracts one embedding per segment at a single scale.

sherpa-onnx's own clustering (FastClusteringConfig) is a fixed-threshold
complete-linkage AHC, which the merge policy in processing.py compensates for
after the fact. NME-SC replaces that decision with a clustering pass that
auto-estimates both the neighbor-graph density (p) and the speaker count (K)
from the eigenstructure of the affinity graph, rather than a fixed distance
cutoff.

k-means selection deviates from NeMo's reference: NeMo runs k-means++ for
several random restarts and picks the run whose per-point labels most often
match the majority vote across restarts, which assumes cluster indices are
comparable across independently seeded restarts. This picks the lowest-inertia
restart instead, which is well-defined regardless of label permutation.
"""

from __future__ import annotations

import numpy as np

EPS = 1e-10


def cosine_affinity_matrix(embeddings: np.ndarray) -> np.ndarray:
    """Cosine similarity among embeddings, min-max scaled to [0, 1]."""
    n = embeddings.shape[0]
    if n == 1:
        return np.ones((1, 1), dtype=np.float64)
    norms = np.linalg.norm(embeddings, axis=1, keepdims=True)
    normalized = embeddings / np.maximum(norms, EPS)
    similarity = normalized @ normalized.T
    np.fill_diagonal(similarity, 1.0)
    v_min, v_max = similarity.min(), similarity.max()
    if v_max - v_min < EPS:
        return np.ones_like(similarity)
    return (similarity - v_min) / (v_max - v_min)


def _binarize_top_p(affinity: np.ndarray, p: int) -> np.ndarray:
    n = affinity.shape[0]
    p = max(1, min(p, n))
    binarized = np.zeros_like(affinity)
    top_p_indices = np.argpartition(-affinity, p - 1, axis=1)[:, :p]
    rows = np.repeat(np.arange(n), p)
    binarized[rows, top_p_indices.ravel()] = 1.0
    return binarized


def build_affinity_graph(affinity: np.ndarray, p: int) -> np.ndarray:
    """Binarize top-p neighbors per row, then symmetrize."""
    binarized = _binarize_top_p(affinity, p)
    return 0.5 * (binarized + binarized.T)


def laplacian(affinity_graph: np.ndarray) -> np.ndarray:
    graph = affinity_graph.copy()
    np.fill_diagonal(graph, 0.0)
    degree = np.sum(np.abs(graph), axis=1)
    return np.diag(degree) - graph


def is_fully_connected(affinity_graph: np.ndarray) -> bool:
    n = affinity_graph.shape[0]
    if n <= 1:
        return True
    adjacency = affinity_graph > 0
    visited = np.zeros(n, dtype=bool)
    stack = [0]
    visited[0] = True
    count = 1
    while stack:
        node = stack.pop()
        neighbors = np.nonzero(adjacency[node] & ~visited)[0]
        if neighbors.size:
            visited[neighbors] = True
            count += neighbors.size
            stack.extend(neighbors.tolist())
    return count == n


def eigengap_estimate(affinity_graph: np.ndarray, max_num_speakers: int) -> tuple[int, np.ndarray, np.ndarray]:
    """Estimate speaker count K from the Laplacian's eigengap.

    Returns (K, ascending eigenvalues, gaps between consecutive eigenvalues).
    """
    eigenvalues = np.linalg.eigvalsh(laplacian(affinity_graph))
    gaps = eigenvalues[1:] - eigenvalues[:-1]
    capped = gaps[:max_num_speakers]
    num_speakers = int(np.argmax(capped)) + 1
    return num_speakers, eigenvalues, gaps


def _p_value_list(n: int, max_rp_threshold: float, sparse_search_volume: int) -> np.ndarray:
    max_n = max(int(np.floor(n * max_rp_threshold)), 2)
    search_volume = min(max_n, sparse_search_volume)
    steps = max(min(max_n, search_volume), 2)
    return np.unique(np.linspace(1, max_n, steps).astype(int))


def estimate_speaker_count_and_p(
    cos_affinity: np.ndarray,
    max_num_speakers: int,
    max_rp_threshold: float = 0.15,
    sparse_search_volume: int = 30,
) -> tuple[int, int]:
    """Sweep candidate p values, pick the one minimizing g_p, return (p, K).

    A low p that splits the graph into exactly K disconnected components is
    the *desired* signal for K, not a defect: the Laplacian then has K exact
    zero eigenvalues and the eigengap lands cleanly after them. Connectivity
    is only patched up afterwards to give k-means a non-degenerate embedding
    graph to run on, and K is re-read at whatever p that patch lands on
    (bounded by the same swept range - never past the largest candidate p).
    """
    n = cos_affinity.shape[0]
    p_values = _p_value_list(n, max_rp_threshold, sparse_search_volume)
    best_p = int(p_values[0])
    best_g_p = None
    k_by_p: dict[int, int] = {}
    for p in p_values:
        p = int(p)
        graph = build_affinity_graph(cos_affinity, p)
        num_speakers, eigenvalues, gaps = eigengap_estimate(graph, max_num_speakers)
        k_by_p[p] = num_speakers
        capped_gaps = gaps[:max_num_speakers]
        max_gap = float(np.max(capped_gaps)) if capped_gaps.size else 0.0
        max_eigenvalue = float(np.max(eigenvalues))
        max_eig_gap = max_gap / (max_eigenvalue + EPS)
        g_p = (p / n) / (max_eig_gap + EPS)
        if best_g_p is None or g_p < best_g_p:
            best_g_p = g_p
            best_p = p

    final_p = best_p
    if not is_fully_connected(build_affinity_graph(cos_affinity, final_p)):
        for p in p_values:
            p = int(p)
            final_p = p
            if is_fully_connected(build_affinity_graph(cos_affinity, p)):
                break

    return final_p, k_by_p[final_p]


def spectral_embedding(affinity_graph: np.ndarray, num_speakers: int) -> np.ndarray:
    """Eigenvectors of the smallest `num_speakers` eigenvalues of the Laplacian."""
    eigenvalues, eigenvectors = np.linalg.eigh(laplacian(affinity_graph))
    return eigenvectors[:, :num_speakers]


def _kmeans_plus_plus_init(points: np.ndarray, k: int, rng: np.random.Generator) -> np.ndarray:
    n = points.shape[0]
    centers = np.empty((k, points.shape[1]), dtype=points.dtype)
    first = rng.integers(n)
    centers[0] = points[first]
    closest_dist_sq = np.sum((points - centers[0]) ** 2, axis=1)
    for i in range(1, k):
        total = closest_dist_sq.sum()
        if total <= 0:
            remaining = rng.integers(n)
            centers[i] = points[remaining]
        else:
            probabilities = closest_dist_sq / total
            chosen = rng.choice(n, p=probabilities)
            centers[i] = points[chosen]
        new_dist_sq = np.sum((points - centers[i]) ** 2, axis=1)
        closest_dist_sq = np.minimum(closest_dist_sq, new_dist_sq)
    return centers


def _kmeans_once(points: np.ndarray, k: int, rng: np.random.Generator, max_iter: int = 300) -> tuple[np.ndarray, float]:
    centers = _kmeans_plus_plus_init(points, k, rng)
    labels = np.zeros(points.shape[0], dtype=int)
    for _ in range(max_iter):
        distances = np.sum((points[:, None, :] - centers[None, :, :]) ** 2, axis=2)
        new_labels = np.argmin(distances, axis=1)
        if np.array_equal(new_labels, labels) and _ > 0:
            break
        labels = new_labels
        for cluster_index in range(k):
            members = points[labels == cluster_index]
            if members.shape[0] == 0:
                centers[cluster_index] = points[rng.integers(points.shape[0])]
            else:
                centers[cluster_index] = members.mean(axis=0)
    distances = np.sum((points[:, None, :] - centers[None, :, :]) ** 2, axis=2)
    inertia = float(np.sum(np.min(distances, axis=1)))
    return labels, inertia


def kmeans(points: np.ndarray, k: int, *, random_seed: int = 0, n_init: int = 10) -> np.ndarray:
    if k <= 1:
        return np.zeros(points.shape[0], dtype=int)
    k = min(k, points.shape[0])
    rng = np.random.default_rng(random_seed)
    best_labels = None
    best_inertia = None
    for _ in range(n_init):
        labels, inertia = _kmeans_once(points, k, rng)
        if best_inertia is None or inertia < best_inertia:
            best_inertia = inertia
            best_labels = labels
    assert best_labels is not None
    return best_labels


def cluster_embeddings(
    embeddings: np.ndarray,
    *,
    max_num_speakers: int = 20,
    oracle_num_speakers: int | None = None,
    random_seed: int = 0,
) -> np.ndarray:
    """Cluster segment embeddings into speaker labels via NME-SC.

    If `oracle_num_speakers` is given, it overrides the estimated speaker
    count for the final k-means step, but the eigengap search still runs (at
    that count as its cap) to pick the neighbor-graph density p.
    """
    n = embeddings.shape[0]
    if n <= 1:
        return np.zeros(n, dtype=int)
    effective_cap = max(2, min(oracle_num_speakers or max_num_speakers, n - 1))
    cos_affinity = cosine_affinity_matrix(embeddings)
    p_star, estimated_k = estimate_speaker_count_and_p(cos_affinity, effective_cap)
    num_speakers = oracle_num_speakers if oracle_num_speakers else estimated_k
    num_speakers = max(1, min(num_speakers, n))
    graph = build_affinity_graph(cos_affinity, p_star)
    embedding = spectral_embedding(graph, num_speakers)
    return kmeans(embedding, num_speakers, random_seed=random_seed)

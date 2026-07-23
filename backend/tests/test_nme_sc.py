import unittest

import numpy as np

from damso.nme_sc import (
    build_affinity_graph,
    cluster_embeddings,
    cosine_affinity_matrix,
    count_components,
    eigengap_estimate,
    estimate_speaker_count_via_component_plateau,
    is_fully_connected,
    kmeans,
)


def make_synthetic_speaker_embeddings(cluster_sizes, dim=32, noise=0.05, seed=0):
    rng = np.random.default_rng(seed)
    centers = rng.normal(size=(len(cluster_sizes), dim))
    centers /= np.linalg.norm(centers, axis=1, keepdims=True)
    embeddings = []
    true_labels = []
    for cluster_index, size in enumerate(cluster_sizes):
        points = centers[cluster_index] + rng.normal(scale=noise, size=(size, dim))
        embeddings.append(points)
        true_labels.extend([cluster_index] * size)
    return np.vstack(embeddings), np.array(true_labels)


def partition_matches(true_labels, predicted_labels):
    """True iff the two labelings induce the same partition, up to relabeling."""
    n = len(true_labels)
    for i in range(n):
        for j in range(i + 1, n):
            same_true = true_labels[i] == true_labels[j]
            same_pred = predicted_labels[i] == predicted_labels[j]
            if same_true != same_pred:
                return False
    return True


class CosineAffinityMatrixTests(unittest.TestCase):
    def test_diagonal_is_one_and_range_is_unit_interval(self):
        embeddings, _ = make_synthetic_speaker_embeddings([4, 4], seed=1)
        affinity = cosine_affinity_matrix(embeddings)
        np.testing.assert_allclose(np.diag(affinity), 1.0)
        self.assertTrue(np.all(affinity >= 0.0))
        self.assertTrue(np.all(affinity <= 1.0 + 1e-9))

    def test_single_embedding_is_trivial(self):
        affinity = cosine_affinity_matrix(np.array([[1.0, 2.0, 3.0]]))
        np.testing.assert_allclose(affinity, [[1.0]])


class ConnectivityTests(unittest.TestCase):
    def test_disconnected_blocks_are_not_fully_connected(self):
        graph = np.zeros((4, 4))
        graph[0, 1] = graph[1, 0] = 1.0
        graph[2, 3] = graph[3, 2] = 1.0
        self.assertFalse(is_fully_connected(graph))

    def test_ring_graph_is_fully_connected(self):
        graph = np.zeros((4, 4))
        for i in range(4):
            graph[i, (i + 1) % 4] = graph[(i + 1) % 4, i] = 1.0
        self.assertTrue(is_fully_connected(graph))


class EigengapEstimateTests(unittest.TestCase):
    def test_recovers_known_component_count_from_block_diagonal_graph(self):
        # Three perfectly disconnected blocks -> Laplacian has exactly 3 zero
        # eigenvalues, so the largest eigengap sits right after them.
        sizes = [5, 4, 6]
        n = sum(sizes)
        graph = np.zeros((n, n))
        offset = 0
        for size in sizes:
            graph[offset : offset + size, offset : offset + size] = 1.0
            offset += size
        np.fill_diagonal(graph, 0.0)
        estimated_k, eigenvalues, gaps = eigengap_estimate(graph, max_num_speakers=10)
        self.assertEqual(estimated_k, len(sizes))
        self.assertEqual(eigenvalues.shape[0], n)
        self.assertEqual(gaps.shape[0], n - 1)


class ComponentPlateauEstimateTests(unittest.TestCase):
    def test_count_components_matches_disconnected_blocks(self):
        graph = np.zeros((6, 6))
        graph[0, 1] = graph[1, 0] = 1.0
        graph[2, 3] = graph[3, 2] = 1.0
        # node 4 and node 5 stay isolated singleton components
        self.assertEqual(count_components(graph), 4)

    def test_recovers_known_speaker_count_from_well_separated_embeddings(self):
        embeddings, _ = make_synthetic_speaker_embeddings([15, 12, 18], noise=0.03, seed=3)
        cos_affinity = cosine_affinity_matrix(embeddings)
        _, estimated_k = estimate_speaker_count_via_component_plateau(cos_affinity, max_num_speakers=10)
        self.assertEqual(estimated_k, 3)

    def test_a_single_true_cluster_can_still_read_as_multiple_speakers(self):
        # Known, accepted limitation, not a guarantee: a genuinely single
        # Gaussian blob can show a real-looking, evenly-sized split at low p
        # from finite-sample nearest-neighbor clumping alone (observed: 3
        # components of size 8/6/6 out of 20 points at p=2, not singleton
        # noise a size filter could catch). Distinguishing that from a real
        # multi-speaker split would need a significance test against a null
        # distribution, not attempted. This test documents the failure mode
        # rather than asserting a fix.
        embeddings, _ = make_synthetic_speaker_embeddings([20], noise=0.03, seed=6)
        cos_affinity = cosine_affinity_matrix(embeddings)
        _, estimated_k = estimate_speaker_count_via_component_plateau(cos_affinity, max_num_speakers=10)
        self.assertGreaterEqual(estimated_k, 1)

    def test_prefers_the_widest_surviving_plateau_over_a_transient_count(self):
        # Four well-separated clusters: the true K=4 plateau should win over
        # whatever transient component count appears at the sparsest p.
        embeddings, _ = make_synthetic_speaker_embeddings([10, 10, 10, 10], noise=0.03, seed=7)
        cos_affinity = cosine_affinity_matrix(embeddings)
        _, estimated_k = estimate_speaker_count_via_component_plateau(cos_affinity, max_num_speakers=10)
        self.assertEqual(estimated_k, 4)


class KMeansTests(unittest.TestCase):
    def test_recovers_well_separated_blobs(self):
        rng = np.random.default_rng(2)
        centers = np.array([[0.0, 0.0], [10.0, 0.0], [0.0, 10.0]])
        points = np.vstack([center + rng.normal(scale=0.2, size=(10, 2)) for center in centers])
        true_labels = np.repeat(np.arange(3), 10)
        labels = kmeans(points, 3, random_seed=0)
        self.assertTrue(partition_matches(true_labels, labels))

    def test_k_of_one_returns_single_cluster(self):
        points = np.array([[0.0, 0.0], [1.0, 1.0], [2.0, 2.0]])
        labels = kmeans(points, 1)
        np.testing.assert_array_equal(labels, [0, 0, 0])


class ClusterEmbeddingsTests(unittest.TestCase):
    def test_recovers_known_speaker_count_and_partition(self):
        embeddings, true_labels = make_synthetic_speaker_embeddings([15, 12, 18], noise=0.03, seed=3)
        labels = cluster_embeddings(embeddings, max_num_speakers=10)
        self.assertEqual(len(set(labels.tolist())), 3)
        self.assertTrue(partition_matches(true_labels, labels))

    def test_oracle_speaker_count_overrides_estimate(self):
        embeddings, _ = make_synthetic_speaker_embeddings([15, 12], noise=0.03, seed=4)
        labels = cluster_embeddings(embeddings, max_num_speakers=10, oracle_num_speakers=2)
        self.assertEqual(len(set(labels.tolist())), 2)

    def test_single_segment_is_trivially_one_speaker(self):
        labels = cluster_embeddings(np.array([[1.0, 2.0, 3.0]]))
        np.testing.assert_array_equal(labels, [0])

    def test_build_affinity_graph_is_symmetric(self):
        embeddings, _ = make_synthetic_speaker_embeddings([6, 6], seed=5)
        affinity = cosine_affinity_matrix(embeddings)
        graph = build_affinity_graph(affinity, p=3)
        np.testing.assert_allclose(graph, graph.T)


if __name__ == "__main__":
    unittest.main()

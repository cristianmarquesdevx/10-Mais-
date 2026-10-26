"""Testes do motor de despacho (funções puras).

    python -m unittest scripts/test_dispatch.py
"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

import dispatch as d  # noqa: E402


ORIGIN = (-8.7607, -63.9039)  # Centro de Porto Velho


def cand(pid: str, *, dlat=0.0, dlon=0.0, **kw) -> d.Candidate:
    return d.Candidate(
        partner_id=pid,
        lat=ORIGIN[0] + dlat,
        lon=ORIGIN[1] + dlon,
        **kw,
    )


class WeightsTest(unittest.TestCase):
    def test_weights_sum_to_one(self):
        total = (d.W_ETA + d.W_RATING + d.W_ACCEPTANCE + d.W_IDLE
                 + d.W_EXPERIENCE + d.W_ROUTE)
        self.assertAlmostEqual(total, 1.0, places=9)

    def test_score_stays_in_range(self):
        best = d.evaluate_candidate(
            cand("a", rating=5.0, rating_count=100, acceptance_rate=1.0,
                 idle_seconds=99999, completed_rides=0, route_deviation_m=0),
            origin=ORIGIN, fare=20, service="MOTO", max_distance_km=8)
        worst = d.evaluate_candidate(
            cand("b", dlat=0.5, rating=1.0, rating_count=100,
                 idle_seconds=0, completed_rides=999, route_deviation_m=9999),
            origin=ORIGIN, fare=20, service="MOTO", max_distance_km=8)
        self.assertTrue(0.0 <= best.score <= 1.0)
        self.assertTrue(0.0 <= worst.score <= 1.0)
        self.assertGreater(best.score, worst.score)


class RankingTest(unittest.TestCase):
    def test_closer_driver_wins_all_else_equal(self):
        near = cand("near", dlat=0.002)
        far = cand("far", dlat=0.02)
        ranked = d.rank_candidates(
            [far, near], origin=ORIGIN, fare=20, service="MOTO",
            max_distance_km=8)
        self.assertEqual(ranked[0].candidate.partner_id, "near")
        self.assertGreater(ranked[0].score, ranked[1].score)

    def test_idle_breaks_tie_in_favor_of_who_waited_longer(self):
        fresh = cand("fresh", idle_seconds=10)
        waiting = cand("waiting", idle_seconds=1700)
        ranked = d.rank_candidates(
            [fresh, waiting], origin=ORIGIN, fare=20, service="MOTO",
            max_distance_km=8)
        self.assertEqual(ranked[0].candidate.partner_id, "waiting")

    def test_newcomer_wins_small_edge_when_everything_else_equal(self):
        veteran = cand("veteran", completed_rides=480)
        rookie = cand("rookie", completed_rides=0)
        ranked = d.rank_candidates(
            [veteran, rookie], origin=ORIGIN, fare=20, service="MOTO",
            max_distance_km=8)
        self.assertEqual(ranked[0].candidate.partner_id, "rookie")

    def test_min_fare_blocks_cheap_ride(self):
        expensive = cand("picky", min_fare=12.0)
        flexible = cand("flex", dlat=0.02, min_fare=5.0)
        evals = d.evaluate_candidates(
            [expensive, flexible], origin=ORIGIN, fare=9.0, service="MOTO",
            max_distance_km=8)
        picky = next(e for e in evals if e.candidate.partner_id == "picky")
        self.assertFalse(picky.eligible)
        self.assertEqual(picky.reason, "below_min_fare")
        ranked = d.rank_candidates(
            [expensive, flexible], origin=ORIGIN, fare=9.0, service="MOTO",
            max_distance_km=8)
        self.assertEqual([r.candidate.partner_id for r in ranked], ["flex"])

    def test_vehicle_must_match_service(self):
        car = cand("car", vehicle="Carro")
        moto = cand("moto", vehicle="Moto")
        evals = d.evaluate_candidates(
            [car, moto], origin=ORIGIN, fare=20, service="MOTO",
            max_distance_km=8)
        by_id = {e.candidate.partner_id: e for e in evals}
        self.assertEqual(by_id["car"].reason, "vehicle_mismatch")
        self.assertTrue(by_id["moto"].eligible)

    def test_disabled_service_is_filtered(self):
        off = cand("off", services=("MOTO_NEGOCIA",))
        on = cand("on", services=("MOTO", "MOTO_NEGOCIA"))
        evals = d.evaluate_candidates(
            [off, on], origin=ORIGIN, fare=20, service="MOTO",
            max_distance_km=8)
        by_id = {e.candidate.partner_id: e for e in evals}
        self.assertEqual(by_id["off"].reason, "service_disabled")
        self.assertTrue(by_id["on"].eligible)

    def test_out_of_radius(self):
        far = cand("far", dlat=0.2)  # ~22 km
        evals = d.evaluate_candidates(
            [far], origin=ORIGIN, fare=20, service="MOTO", max_distance_km=8)
        self.assertEqual(evals[0].reason, "out_of_radius")

    def test_already_offered_is_not_ranked(self):
        a = cand("a")
        b = cand("b", dlat=0.01)
        ranked = d.rank_candidates(
            [a, b], origin=ORIGIN, fare=20, service="MOTO", max_distance_km=8,
            exclude={"a"})
        self.assertEqual([r.candidate.partner_id for r in ranked], ["b"])

    def test_tie_is_deterministic_by_id(self):
        x = cand("x", idle_seconds=100)
        y = cand("y", idle_seconds=100)
        order = [r.candidate.partner_id for r in d.rank_candidates(
            [y, x], origin=ORIGIN, fare=20, service="MOTO", max_distance_km=8)]
        self.assertEqual(order, ["x", "y"])

    def test_monetization_mode_never_affects_score(self):
        # Invariante de auditoria (SPECS §5): Candidate não tem esse campo.
        self.assertFalse(hasattr(cand("a"), "monetization_mode"))
        self.assertNotIn("monetization", d.__doc__.lower().replace(
            "não olhar o modo de monetização", ""))


if __name__ == "__main__":
    unittest.main()

"""Testes do congelamento da cotação (GET /quote → POST /rides).

    python -m unittest scripts/test_quotes.py

O preço do pedido TARIFF vem da cotação emitida pelo servidor. O
`quoted_fare` do corpo nunca é aceito: com `quote_id` vale o valor gravado
(e só até `expires_in`); sem id, o servidor recalcula pela rota.
"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

import demo_api as api  # noqa: E402


ORIGIN = {"lat": -8.7607, "lon": -63.9039}
DEST = {"lat": -8.7647, "lon": -63.8969}


class QuoteFreezeTest(unittest.TestCase):
    def setUp(self) -> None:
        api.STATE["quotes"].clear()
        api.STATE["rides"].clear()
        api.STATE["offers"].clear()
        api.STATE["heatmap_hits"].clear()

    def _quote(self) -> dict:
        return api._quote(1.2, ORIGIN["lat"], ORIGIN["lon"],
                          DEST["lat"], DEST["lon"])

    def test_quote_emits_id_and_deadline(self) -> None:
        quote = self._quote()
        self.assertTrue(quote.get("quote_id"))
        self.assertEqual(quote["expires_in"], api.QUOTE_TTL_S)
        stored = api.STATE["quotes"][quote["quote_id"]]
        self.assertEqual(stored["fare_total"], quote["fare_total"])
        self.assertGreater(stored["expires_at"], api.now())

    def test_valid_quote_is_honored(self) -> None:
        quote = self._quote()
        fare, error = api._resolve_quote(
            {"quote_id": quote["quote_id"],
             "quoted_fare": quote["fare_total"]},
            ORIGIN, DEST, 1.2)
        self.assertIsNone(error)
        self.assertEqual(fare, quote["fare_total"])
        # Cotação é de uso único: o segundo pedido não a reaproveita.
        self.assertNotIn(quote["quote_id"], api.STATE["quotes"])

    def test_reused_quote_is_rejected(self) -> None:
        quote = self._quote()
        body = {"quote_id": quote["quote_id"]}
        api._resolve_quote(body, ORIGIN, DEST, 1.2)
        fare, error = api._resolve_quote(body, ORIGIN, DEST, 1.2)
        self.assertIsNone(fare)
        self.assertEqual(error[0], 422)
        self.assertEqual(error[1]["code"], "quote_not_found")

    def test_expired_quote_is_rejected(self) -> None:
        quote = self._quote()
        api.STATE["quotes"][quote["quote_id"]]["expires_at"] = api.now() - 1
        fare, error = api._resolve_quote(
            {"quote_id": quote["quote_id"]}, ORIGIN, DEST, 1.2)
        self.assertIsNone(fare)
        self.assertEqual(error[1]["code"], "quote_expired")
        self.assertNotIn(quote["quote_id"], api.STATE["quotes"])

    def test_quote_for_another_route_is_rejected(self) -> None:
        quote = self._quote()
        fare, error = api._resolve_quote(
            {"quote_id": quote["quote_id"]},
            {"lat": -8.7465, "lon": -63.8940}, DEST, 1.2)
        self.assertIsNone(fare)
        self.assertEqual(error[1]["code"], "quote_mismatch")

    def test_tampered_fare_is_rejected(self) -> None:
        quote = self._quote()
        fare, error = api._resolve_quote(
            {"quote_id": quote["quote_id"], "quoted_fare": 0.01},
            ORIGIN, DEST, 1.2)
        self.assertIsNone(fare)
        self.assertEqual(error[1]["code"], "quote_fare_mismatch")

    def test_without_quote_id_server_recalculates(self) -> None:
        expected = api._quote_fare(1.2, ORIGIN["lat"], ORIGIN["lon"])
        fare, error = api._resolve_quote(
            {"quoted_fare": 999.0}, ORIGIN, DEST, 1.2)
        self.assertIsNone(error)
        self.assertEqual(fare, expected["fare_total"])
        self.assertNotEqual(fare, 999.0)

    def test_post_rides_snapshots_server_fare(self) -> None:
        quote = self._quote()
        status, body = api._route(
            "POST", "/rides", {},
            {"origin": ORIGIN, "destination": DEST, "pricing_mode": "TARIFF",
             "quoted_fare": quote["fare_total"],
             "quote_id": quote["quote_id"]},
            distance_km=1.2)
        self.assertEqual(status, 201, body)
        ride = next(iter(api.STATE["rides"].values()))
        self.assertEqual(ride["fare_total"], quote["fare_total"])

    def test_post_rides_records_the_honored_quote(self) -> None:
        """A corrida guarda a cotação honrada: é a auditoria do preço."""
        quote = self._quote()
        status, _ = api._route(
            "POST", "/rides", {},
            {"origin": ORIGIN, "destination": DEST, "pricing_mode": "TARIFF",
             "quoted_fare": quote["fare_total"],
             "quote_id": quote["quote_id"]},
            distance_km=1.2)
        self.assertEqual(status, 201)
        ride = next(iter(api.STATE["rides"].values()))
        self.assertEqual(ride["quote_id"], quote["quote_id"])
        view = api.ride_view(ride)
        self.assertEqual(view["quote_id"], quote["quote_id"])
        self.assertEqual(view["fare_total"], quote["fare_total"])

    def test_post_rides_without_quote_records_no_quote(self) -> None:
        """Sem cotação o servidor recalcula — e não há id para auditar."""
        status, _ = api._route(
            "POST", "/rides", {},
            {"origin": ORIGIN, "destination": DEST, "pricing_mode": "TARIFF",
             "quoted_fare": 0.01},
            distance_km=1.2)
        self.assertEqual(status, 201)
        ride = next(iter(api.STATE["rides"].values()))
        self.assertIsNone(ride["quote_id"])
        self.assertIsNone(api.ride_view(ride)["quote_id"])

    def test_post_rides_ignores_client_value_without_quote(self) -> None:
        status, body = api._route(
            "POST", "/rides", {},
            {"origin": ORIGIN, "destination": DEST, "pricing_mode": "TARIFF",
             "quoted_fare": 0.01},
            distance_km=1.2)
        self.assertEqual(status, 201, body)
        ride = next(iter(api.STATE["rides"].values()))
        self.assertGreater(ride["fare_total"], 1.0)


if __name__ == "__main__":
    unittest.main()

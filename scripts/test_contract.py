"""O contrato não pode divergir entre o código, o SQL e a documentação.

    python -m unittest scripts/test_contract.py

Por que este teste existe
-------------------------
Os parâmetros que definem o comportamento de rua estavam escritos em vários
lugares (SPECS, `seed.sql`, migrations, API de demonstração, simulador).
Um deles divergiu: o banco local ficou com a janela da oferta em **60 s**
enquanto todos os outros diziam **15 s**. O passageiro passava a esperar
4× mais por um motorista que talvez nunca visse a oferta, e o E2E "passava"
só porque a janela estava inflada — o roteiro levava 43 s para responder e
ninguém reparou.

Agora o valor vive em `scripts/contract.py`, e este teste confere que o
SQL e a documentação continuam dizendo a mesma coisa.
"""
from __future__ import annotations

import os
import re
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import contract  # noqa: E402


def read(rel: str) -> str:
    with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
        return fh.read()


class ContratoTest(unittest.TestCase):

    def test_valores_do_contrato(self):
        # Os números do contrato (SPECS §1.1 e §1.5).
        self.assertEqual(contract.OFERTA_TIMEOUT_S, 15)
        self.assertEqual(contract.PRESENCE_HEARTBEAT_S, 30)
        self.assertEqual(contract.PRESENCE_FRESH_S, 90)
        self.assertEqual(contract.MATCH_R0_KM, 2.0)
        self.assertEqual(contract.MATCH_PASSO_KM, 1.0)
        self.assertEqual(contract.MATCH_RMAX_KM, 8.0)

    def test_seed_diz_a_janela_do_contrato(self):
        # O seed é a configuração da cidade piloto: precisa ser o contrato.
        seed = read("supabase/seed.sql")
        achou = re.search(
            r"\('PRM-oferta\.timeout',\s*'(\d+)'::jsonb\)", seed)
        self.assertIsNotNone(achou, "seed.sql sem PRM-oferta.timeout")
        self.assertEqual(
            int(achou.group(1)), contract.OFERTA_TIMEOUT_S,
            "o seed da cidade piloto diverge do contrato",
        )

    def test_migration_tranca_a_janela_do_contrato(self):
        # A migration que corrige o desvio e trava a config no contrato.
        mig = read("supabase/migrations/20261110000400_oferta_timeout_contrato.sql")
        achou = re.search(r"v_contrato\s+int\s*:=\s*(\d+)", mig)
        self.assertIsNotNone(achou, "migration sem o valor do contrato")
        self.assertEqual(int(achou.group(1)), contract.OFERTA_TIMEOUT_S)

    def test_spec_diz_a_janela_do_contrato(self):
        specs = read("docs/fase2/SPECS.md")
        self.assertIn(
            f"PRM-oferta.timeout ({contract.OFERTA_TIMEOUT_S} s)", specs,
            "o SPEC não documenta a janela do contrato",
        )

    def test_demo_usa_o_contrato(self):
        # A API de demonstração herda o valor (não reescreve o número).
        demo = read("scripts/demo_api.py")
        self.assertIn("OFFER_TIMEOUT_S = contract.OFERTA_TIMEOUT_S", demo)
        self.assertIn("PRESENCE_FRESH_S = contract.PRESENCE_FRESH_S", demo)
        # E nenhum número solto sobrou na demo (o que reabriria o desvio).
        soltos = re.findall(
            r"(?:OFFER_TIMEOUT_S|PRESENCE_FRESH_S)\s*=\s*(\d+)", demo)
        self.assertEqual(soltos, [], "a demo ainda fixa o valor na mão")

    def test_harness_confere_a_janela_no_servidor(self):
        # O E2E confere a janela no servidor: é a guarda que pega o desvio
        # no caminho do produto (não só no código).
        harness = read("scripts/e2e_emulator.py")
        self.assertIn(
            "OFERTA_TIMEOUT_CONTRATO_S = 15.0", harness)
        self.assertIn("def offer_window_s", harness)


if __name__ == "__main__":
    unittest.main()

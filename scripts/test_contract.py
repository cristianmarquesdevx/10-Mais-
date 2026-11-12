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
        # Os números do contrato (SPECS §1.1, §1.5 e §6).
        self.assertEqual(contract.OFERTA_TIMEOUT_S, 15)
        self.assertEqual(contract.PRESENCE_HEARTBEAT_S, 30)
        self.assertEqual(contract.PRESENCE_FRESH_S, 90)
        self.assertEqual(contract.MATCH_R0_KM, 2.0)
        self.assertEqual(contract.MATCH_PASSO_KM, 1.0)
        self.assertEqual(contract.MATCH_RMAX_KM, 8.0)
        self.assertEqual(contract.KYC_REVIEW_START_H, 7)
        self.assertEqual(contract.KYC_REVIEW_END_H, 23)
        self.assertEqual(contract.KYC_SLA_LEAD_H, 2)
        self.assertEqual(contract.KYC_STORAGE_BUCKET, "kyc-docs")
        self.assertEqual(contract.KYC_STORAGE_PATH_PREFIX, "kyc")

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

    # --- KYC (SPECS §6) -----------------------------------------------------

    #: Os três parâmetros que definem o prazo de um caso do KYC.
    KYC_PARAMS = (
        ("PRM-kyc.review_inicio_h", "KYC_REVIEW_START_H"),
        ("PRM-kyc.review_fim_h", "KYC_REVIEW_END_H"),
        ("PRM-kyc.sla_antecedencia_h", "KYC_SLA_LEAD_H"),
    )

    def test_seed_diz_a_janela_kyc(self):
        # A janela humana e a antecedência do SLA moram na config da cidade:
        # o seed da praça piloto precisa ser o contrato.
        seed = read("supabase/seed.sql")
        for chave, attr in self.KYC_PARAMS:
            achou = re.search(
                rf"\('{re.escape(chave)}',\s*'(\d+)'::jsonb\)", seed)
            self.assertIsNotNone(achou, f"seed.sql sem {chave}")
            self.assertEqual(
                int(achou.group(1)), getattr(contract, attr),
                f"{chave} no seed diverge do contrato",
            )

    def test_migration_kyc_usa_a_janela_do_contrato(self):
        # A função do SLA lê a config com o valor do contrato como default:
        # sem o default, uma config ausente mudaria a promessa do app.
        mig = read("supabase/migrations/20261110000500_kyc_api.sql")
        for chave, attr in self.KYC_PARAMS:
            achou = re.search(
                rf"city_param\(p_city,'{re.escape(chave)}','(\d+)'\)", mig)
            self.assertIsNotNone(achou, f"migration do KYC sem {chave}")
            self.assertEqual(
                int(achou.group(1)), getattr(contract, attr),
                f"{chave} na migration diverge do contrato",
            )

    def test_spec_diz_a_janela_kyc(self):
        specs = read("docs/fase2/SPECS.md")
        self.assertIn(f"{contract.KYC_REVIEW_START_H}h", specs)
        self.assertIn(f"{contract.KYC_REVIEW_END_H}h", specs)
        self.assertIn(
            f"antecedência mínima **{contract.KYC_SLA_LEAD_H} h**", specs,
            "o SPEC não documenta a antecedência mínima do SLA do KYC",
        )

    def test_openapi_tem_a_fila_e_a_decisao_kyc(self):
        # O contrato publicado precisa ter as rotas que o app e a operação
        # usam — inclusive as que chegaram na migração do KYC no Postgres.
        api = read("docs/fase2/openapi.yaml")
        for rota in ("/kyc/cases:", "/kyc/cases/{caseId}:",
                     "/kyc/cases/{caseId}/review:", "/kyc/queue:",
                     "/kyc/me:"):
            self.assertIn(rota, api, f"openapi sem {rota}")
        self.assertIn("APPROVED, IN_REVIEW, REJECTED, RESUBMIT", api)

    # --- KYC: o Storage dos documentos ----------------------------------------

    #: A migration que cria o bucket, a RLS e a conferência do objeto.
    KYC_STORAGE_MIGRATION = "supabase/migrations/20261110000600_kyc_storage.sql"

    def test_migration_kyc_storage_usa_o_bucket_do_contrato(self):
        # O bucket é CONTRATO: uma migration com outro nome de bucket
        # escreveria o app num lugar que o servidor não valida.
        mig = read(self.KYC_STORAGE_MIGRATION)
        # Só literais entre aspas contam como bucket — o id do evento
        # `kyc.resubmitted` (`kyc-resubmit:...`) não é bucket.
        buckets = set(re.findall(r"'(kyc-[a-z0-9-]+)'", mig))
        self.assertEqual(
            buckets, {contract.KYC_STORAGE_BUCKET},
            "a migration do KYC usa um bucket diferente do contrato",
        )

    def test_migration_kyc_storage_usa_o_prefixo_do_contrato(self):
        # O prefixo da pasta do parceiro é contrato (é dele que a RLS tira o
        # dono do objeto).
        mig = read(self.KYC_STORAGE_MIGRATION)
        achou = re.search(r"starts_with\(p_path,\s*'([^']+)/'\s*\|\|", mig)
        self.assertIsNotNone(achou, "migration sem o predicado de dono do path")
        self.assertEqual(achou.group(1), contract.KYC_STORAGE_PATH_PREFIX)

    def test_migration_kyc_storage_cria_o_bucket_privado(self):
        # O bucket nasce PRIVADO: `public = false` é o que fecha o acesso
        # anônimo ao documento do parceiro.
        mig = read(self.KYC_STORAGE_MIGRATION)
        achou = re.search(
            r"INSERT INTO storage\.buckets[^;]*?VALUES\s*\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*false\s*\)",
            mig, re.S)
        self.assertIsNotNone(achou, "migration sem a criação do bucket privado")
        self.assertEqual(achou.group(1), contract.KYC_STORAGE_BUCKET)
        self.assertEqual(achou.group(2), contract.KYC_STORAGE_BUCKET)

    def test_ci_do_kyc_storage_prova_o_comportamento(self):
        # O CI tem que PROVAR o comportamento (bucket privado, políticas e as
        # três recusas), não só checar que o arquivo existe.
        ci = read("scripts/ci_migrations.sh")
        self.assertIn("scripts/supabase_storage_stub.sql", ci)
        self.assertIn(contract.KYC_STORAGE_BUCKET, ci)
        for marca in ("storage_path_not_owned", "document_not_found",
                      "storage_unavailable", "kyc_docs_select"):
            self.assertIn(marca, ci, f"CI sem o assert de {marca}")

    def test_stub_do_storage_tem_a_forma_do_supabase(self):
        # O stub do CI precisa ter a MESMA forma do Storage do Supabase —
        # senão o CI prova um predicado que a nuvem não aplica.
        stub = read("scripts/supabase_storage_stub.sql")
        self.assertIn("CREATE SCHEMA IF NOT EXISTS storage;", stub)
        self.assertIn("storage.buckets", stub)
        self.assertIn("storage.objects", stub)
        self.assertIn("CREATE OR REPLACE FUNCTION storage.foldername(name text)", stub)
        self.assertIn("string_to_array(name, '/')", stub)

    def test_smoke_do_kyc_sobe_arquivo_de_verdade(self):
        # O smoke do KYC sobe um objeto no bucket pelo REST do Storage e
        # registra o documento — e usa o contrato para o path.
        smoke = read("scripts/kyc_smoke.py")
        self.assertIn("contract.KYC_STORAGE_BUCKET", smoke)
        self.assertIn("contract.KYC_STORAGE_PATH_PREFIX", smoke)
        self.assertIn("/storage/v1/object/", smoke)
        for marca in ("storage_path_not_owned", "document_not_found"):
            self.assertIn(marca, smoke, f"smoke sem o caso negativo {marca}")

    def test_console_oferece_os_motivos_do_contrato(self):
        # A pessoa da operação ESCOLHE o motivo da recusa numa lista (não
        # digita): se a lista do app divergir do contrato, o parceiro recebe
        # um motivo que ninguém reconhece.
        console = read("app/console/lib/src/api/console_api.dart")
        bloco = re.search(
            r"static const List<\(String, String\)> all = \[(.*?)\];",
            console, re.S)
        self.assertIsNotNone(bloco, "console sem a lista de motivos")
        codigos = re.findall(r"\('([A-Z_]+)',\s*'", bloco.group(1))
        self.assertEqual(
            codigos, list(contract.KYC_REJECTION_CODES),
            "a lista de motivos do console diverge do contrato",
        )

    def test_rota_do_console_no_backend(self):
        # O console confere o papel da conta ANTES da fila: a rota `/me` é o
        # que dá essa verdade (vem do `users.role`, que só o banco escreve).
        fn = read("supabase/functions/kyc/index.ts")
        self.assertIn('path === "/me"', fn)
        self.assertIn("api_kyc_me", fn)
        mig = read("supabase/migrations/20261110000700_kyc_console.sql")
        self.assertIn("FUNCTION api_kyc_me()", mig)

    def test_limiares_de_qualidade_da_foto_iguais_ao_app(self):
        # Os limiares de borrão e reflexo são CONTRATO: o app mede e o
        # servidor vê a mesma medida. Se os números divergirem, a tela
        #-avisa de uma coisa e a operação lê outra.
        app = read("app/parceiro/lib/src/media/document_quality.dart")
        blur = re.search(
            r"const double kycBlurThreshold\s*=\s*([0-9.]+)\s*;", app)
        glare = re.search(
            r"const double kycGlareRatioThreshold\s*=\s*([0-9.]+)\s*;", app)
        self.assertIsNotNone(blur, "app sem o limiar de borrão")
        self.assertIsNotNone(glare, "app sem o limiar de reflexo")
        self.assertEqual(
            float(blur.group(1)), contract.KYC_BLUR_THRESHOLD,
            "o limiar de borrão do app diverge do contrato",
        )
        self.assertEqual(
            float(glare.group(1)), contract.KYC_GLARE_RATIO_THRESHOLD,
            "o limiar de reflexo do app diverge do contrato",
        )

    def test_bucket_e_prefixo_iguais_ao_app_do_parceiro(self):
        # O app do parceiro escreve no MESMO bucket e na MESMA pasta que o
        # servidor valida: um nome divergente faria o upload ser recusado.
        app = read("app/parceiro/lib/src/api/kyc_storage.dart")
        bucket = re.search(
            r"const String kycStorageBucket\s*=\s*'([^']+)'\s*;", app)
        prefixo = re.search(
            r"const String kycStoragePathPrefix\s*=\s*'([^']+)'\s*;", app)
        self.assertIsNotNone(bucket, "app sem o bucket do KYC")
        self.assertIsNotNone(prefixo, "app sem o prefixo do path do KYC")
        self.assertEqual(bucket.group(1), contract.KYC_STORAGE_BUCKET)
        self.assertEqual(prefixo.group(1), contract.KYC_STORAGE_PATH_PREFIX)

    def test_spec_documenta_o_console_e_o_bucket(self):
        # O SPEC §6 é a fonte de verdade do KYC: o console da operação, o
        # bucket privado e o vocabulário de recusa precisam estar lá.
        specs = read("docs/fase2/SPECS.md")
        self.assertIn("/kyc/me", specs, "o SPEC não documenta a rota do console")
        self.assertIn(contract.KYC_STORAGE_BUCKET, specs,
                      "o SPEC não documenta o bucket privado do KYC")
        self.assertIn("KYC_REJECTION_CODES", specs,
                      "o SPEC não documenta o vocabulário de recusa")
        for codigo in contract.KYC_REJECTION_CODES:
            self.assertIn(codigo, specs,
                          f"o SPEC não documenta o motivo {codigo}")


if __name__ == "__main__":
    unittest.main()

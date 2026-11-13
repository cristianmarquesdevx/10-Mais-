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


def bloco_do_schema(api: str, nome: str) -> str:
    """O bloco YAML de um schema, do nome dele até o PRÓXIMO schema.

    Por que não um slice fixo (`api[api.index("KycCase:"):api.index
    ("KycQueueItem:")]`): ele engolia qualquer schema que caísse no
    meio — e um schema novo, legitimamente anulável, faria o assert
    rejeitar um contrato CORRETO (falso positivo). Aqui o bloco termina
    no próximo schema (mesma indentação), e não num nome escolhido.
    """
    m = re.search(r"(?m)^    %s:\s*$" % re.escape(nome), api)
    if not m:
        raise AssertionError("o openapi não tem o schema %s" % nome)
    ini = m.end()
    fim = re.search(r"(?m)^    [A-Za-z0-9_]+:\s*$", api[ini:])
    return api[ini:ini + fim.start()] if fim else api[ini:]


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

    # --- KYC: o console vê o documento e identifica o parceiro ----------------

    #: A migration que libera a leitura do bucket para a operação e devolve
    #: a identidade do parceiro + o caminho do arquivo.
    KYC_CONSOLE_DOCS_MIGRATION = (
        "supabase/migrations/20261110000800_kyc_console_docs.sql")

    #: A migration que conserta os DOIS defeitos da 00800: o `has_file`
    #: mentindo (virava "ARQUIVO OK" para um path que não aponta para
    #: objeto nenhum) e a fila sem `ORDER BY` antes do `LIMIT` (o caso mais
    #: urgente podia ficar de fora).
    KYC_CONSOLE_FIX_MIGRATION = (
        "supabase/migrations/20261110000900_kyc_console_docs_fix.sql")

    #: A migration que alinha a POSIÇÃO do caso com a ORDEM da fila (a
    #: comparação de linha tratava o prazo nulo como "desconhecido", e o
    #: caso sem prazo recebia posição 0 sendo o último da fila).
    KYC_QUEUE_POSITION_MIGRATION = (
        "supabase/migrations/20261113001000_kyc_queue_position_null.sql")

    def test_console_usa_o_bucket_do_contrato(self):
        # O console lê o documento do MESMO bucket que o app do parceiro
        # escreve: um nome divergente faria a tela mostrar "sem arquivo"
        # com o arquivo lá no bucket.
        console = read("app/console/lib/src/api/console_api.dart")
        bucket = re.search(
            r"const String kycStorageBucket\s*=\s*'([^']+)'\s*;", console)
        self.assertIsNotNone(bucket, "console sem o bucket do KYC")
        self.assertEqual(bucket.group(1), contract.KYC_STORAGE_BUCKET)

    def test_console_baixa_o_documento_com_o_proprio_token(self):
        # O console baixa o objeto do bucket PRIVADO pelo REST do Storage,
        # com o token da sessão (a RLS autoriza) — e nunca com service role
        # nem com URL assinada (que vazaria o documento).
        console = read("app/console/lib/src/api/console_api.dart")
        self.assertIn("/object/", console)
        self.assertIn("Bearer ", console)
        self.assertNotIn("service_role", console)
        self.assertNotIn("signed", console.lower())

    def test_politica_do_storage_libera_a_operacao(self):
        # A operação precisa LER o documento do parceiro: sem `app_is_agent()`
        # na política de SELECT, o console aprova uma CNH que nunca viu.
        mig = read(self.KYC_CONSOLE_DOCS_MIGRATION)
        self.assertIn("kyc_docs_select", mig)
        self.assertIn("app_is_agent()", mig)
        self.assertIn(contract.KYC_STORAGE_BUCKET, mig)

    def test_api_kyc_devolve_a_identidade_e_o_arquivo(self):
        # A fila e o detalhe precisam trazer o NOME, o TELEFONE e o CAMINHO
        # do arquivo: sem eles, o console mostra "Parceiro 77777777" e
        # aprova sem ver a foto.
        mig = read(self.KYC_CONSOLE_DOCS_MIGRATION)
        for campo in ("partner_name", "partner_phone", "storage_path",
                      "has_file"):
            self.assertIn(campo, mig,
                          f"a API do KYC não devolve {campo}")

    def test_has_file_pergunta_ao_bucket_e_nao_ao_nome_do_caminho(self):
        # O `has_file` precisa ser a RESPOSTA DO BUCKET, não "o caminho não
        # é o marcador PENDENTE": a 00800 mentia, pintava "ARQUIVO OK"
        # (verde) e o preview falhava logo abaixo — duas afirmações
        # contrárias na mesma tela.
        mig = read(self.KYC_CONSOLE_FIX_MIGRATION)
        # A função que pergunta ao bucket tem que existir...
        self.assertIn("CREATE OR REPLACE FUNCTION fn_kyc_storage_object_present",
                      mig)
        self.assertIn("storage.objects", mig,
                      "o has_file não consulta a tabela de objetos")
        # ...E TEM QUE SER USADA pelo `api_kyc_case_get` no campo `has_file`.
        # Assert só da DEFINIÇÃO é inerte: a função existir sem ninguém
        # chamá-la é exatamente a mentira que a 00900 veio consertar.
        caso = mig[mig.index("CREATE OR REPLACE FUNCTION api_kyc_case_get"):]
        caso = caso[:caso.index("END $$;")]
        self.assertIn(
            "'has_file', fn_kyc_storage_object_present(",
            caso,
            "o api_kyc_case_get não USA a função do bucket no has_file")
        # E a mentira antiga não pode voltar: o campo não pode ser
        # calculado pelo NOME do caminho (o assert olha só o bloco do
        # `api_kyc_case_get` — é ali que o `has_file` é montado).
        self.assertNotIn("NOT LIKE 'PENDENTE/%'", caso,
                         "o has_file voltou a ser calculado pelo nome do caminho")

    def test_fila_ordena_antes_do_limite(self):
        # A fila tinha `LIMIT` sem `ORDER BY`: o Postgres devolvia 50
        # linhas arbitrárias e o caso que vence primeiro podia não estar
        # na tela — esconder trabalho numa fila de atendimento.
        mig = read(self.KYC_CONSOLE_FIX_MIGRATION)
        self.assertIn("CREATE OR REPLACE FUNCTION api_kyc_queue", mig,
                      "a api_kyc_queue não existe na migration")
        fila = mig[mig.index("CREATE OR REPLACE FUNCTION api_kyc_queue"):]
        self.assertIn("ORDER BY c.sla_due_at, c.created_at, c.id", fila,
                      "a fila não ordena por (prazo, entrada, id)")
        self.assertIn("LIMIT", fila, "a fila não tem limite")
        order = fila.index("ORDER BY c.sla_due_at, c.created_at, c.id")
        limite = fila.index("LIMIT")
        self.assertLess(order, limite,
                        "o ORDER BY da fila precisa vir ANTES do LIMIT")

    def test_console_nao_marca_arquivo_ok_sem_objeto(self):
        # A tela decide pelo `has_file`: sem ele, ela não pode pintar
        # "ARQUIVO OK". E o documento só é ABERTÁVEL com arquivo de verdade.
        console = read("app/console/lib/src/api/console_api.dart")
        self.assertIn("isViewable", console)
        self.assertIn("hasFile &&", console)

    def test_console_tem_permissao_de_internet(self):
        # A permissão de rede tem que estar no manifest MAIN: no `debug`
        # ela é herdada, mas o APK de RELEASE sairia sem rede (e a fila
        # nunca carregaria).
        manifest = read(
            "app/console/android/app/src/main/AndroidManifest.xml")
        self.assertIn("android.permission.INTERNET", manifest,
                      "o manifest main do console não pede INTERNET "
                      "(o APK de release sairia sem rede)")

    def test_ci_prova_a_politica_e_a_identidade(self):
        # O CI não pode só contar as políticas: ele precisa provar que a
        # operação lê o bucket e que a API devolve a identidade.
        ci = read("scripts/ci_migrations.sh")
        self.assertIn("app_is_agent()", ci)
        self.assertIn("partner_name", ci)
        self.assertIn("storage_path", ci)

    def test_ci_prova_o_has_file_honesto(self):
        # O CI precisa provar os DOIS lados do `has_file`: o path com
        # objeto é "COM arquivo" e o path SEM objeto é "sem arquivo". Um
        # assert que só prova o lado feliz deixa a mentira passar.
        ci = read("scripts/ci_migrations.sh")
        self.assertIn("INSERT INTO storage.objects", ci,
                      "o CI não cria o objeto no bucket — o has_file "
                      "honesto não é provado")
        self.assertIn("IS DISTINCT FROM false", ci,
                      "o CI não exige has_file=false para o path sem objeto")

    def test_seed_do_console_deixa_caso_na_fila(self):
        # A prova VISUAL do console precisa de um caso de verdade na fila:
        # o smoke apaga o caso dele, e o seed é quem deixa um.
        seed = read("scripts/kyc_console_seed.py")
        self.assertIn("contract.KYC_STORAGE_BUCKET", seed)
        self.assertIn("contract.KYC_STORAGE_PATH_PREFIX", seed)
        self.assertIn("/functions/v1/kyc", seed)

    def test_a_funcao_do_bucket_nao_e_publica(self):
        # `fn_kyc_storage_object_present` vive em `public`: sem o revoke,
        # ela é executável por PUBLIC/anon e vira um oráculo de existência
        # de documento de parceiro (num bucket PRIVADO).
        mig = read(self.KYC_CONSOLE_FIX_MIGRATION)
        self.assertIn("REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon", mig,
                      "a função do bucket não revoga PUBLIC/anon")
        self.assertIn(
            "GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role", mig,
            "a função do bucket não dá execute para authenticated")

    def test_ci_prova_o_revoke_da_funcao_do_bucket(self):
        # O CI precisa conferir o `pg_proc.proacl`: o revoke pode estar no
        # arquivo e não ter sido aplicado (ou ter sido sobrescrito).
        ci = read("scripts/ci_migrations.sh")
        self.assertIn("fn_kyc_storage_object_present", ci,
                      "o CI não confere as permissões da função do bucket")
        self.assertIn("pg_proc", ci,
                      "o CI não confere o ACL real da função")

    def test_ci_prova_a_fila_ordenada_comportamentalmente(self):
        # O `ORDER BY` antes do `LIMIT` não pode ser provado só por grep: o
        # CI precisa criar MAIS casos que o limite e exigir que o mais
        # urgente apareça (é o defeito que escondia trabalho).
        ci = read("scripts/ci_migrations.sh")
        m = re.search(r"generate_series\(1,\s*(\d+)\)", ci)
        self.assertIsNotNone(m, "o CI não cria uma fila maior que o limite")
        self.assertGreater(int(m.group(1)), 50,
                           "o CI não cria uma fila maior que o limite de 50")
        self.assertIn("api_kyc_queue(50)", ci,
                      "o CI não exercita a fila no limite")
        self.assertIn("caso mais URGENTE", ci,
                      "o CI não exige o caso mais urgente na tela")
        # E o teste tem que ser INDEPENDENTE DO PLANO: sem forçar o seq
        # scan, o índice (ou o scan pela PK) entrega as linhas já
        # ordenadas e o defeito passaria batido.
        #
        # A linha precisa estar **ATIVA**: um grep de substring crua
        # aceitava `# SET enable_indexscan = off;` (comentado) — e o
        # guard passaria sem a neutralização existir. Por isso o regex
        # ancora no início da linha (um comentário começa com `#`).
        self.assertRegex(
            ci, r"(?m)^\s*SET enable_indexscan = off;\s*$",
            "o CI não neutraliza o plano de execução (a linha precisa "
            "estar ATIVA, não comentada)")
        self.assertRegex(
            ci, r"(?m)^\s*DROP INDEX IF EXISTS idx_kyc_queue;\s*$",
            "o CI não neutraliza o índice que mascara o defeito (a linha "
            "precisa estar ATIVA, não comentada)")

    def test_o_openapi_nao_promete_um_null_que_nao_existe(self):
        # O `KycCase` é montado com `jsonb_strip_nulls`: um campo nulo é
        # **OMITIDO**, nunca enviado como `null`. Marcar `nullable: true`
        # faz o leitor esperar a chave presente com `null` — uma promessa
        # que o servidor não cumpre.
        api = read("docs/fase2/openapi.yaml")
        caso = bloco_do_schema(api, "KycCase")
        # Regex, e não substring: `nullable:  true` (dois espaços) ou
        # `nullable : true` passariam num `assertNotIn("nullable: true")`.
        self.assertIsNone(
            re.search(r"\bnullable\s*:\s*true\b", caso),
            "o KycCase promete campos nulos que são omitidos")
        # E a frase antiga (falsa) do `storage_path` não pode voltar: o
        # marcador `PENDENTE/...` volta **como está**, não omitido.
        self.assertNotIn("OMITTED when the document has no object", api,
                         "o openapi volta a prometer a omissão do marcador")
        self.assertIn("the LEGACY MARKER as-is", api,
                      "o openapi não diz que o marcador legado volta como está")

    def test_a_posicao_da_fila_concorda_com_a_ordem(self):
        # O `fn_kyc_queue_position` contava com comparação de LINHA, e
        # numa comparação de linha um NULL torna o resultado
        # desconhecido (não "NULL é o maior", como no ORDER BY): um caso
        # SEM prazo recebia posição 0 sendo o ÚLTIMO da fila — a tela
        # mostrava "#1" em cima de "#0".
        #
        # A correção está na migration `20261113001000`; o CI prova o
        # invariante inteiro (a `position` de cada caso é o índice dele
        # na fila + 1).
        mig = read(self.KYC_QUEUE_POSITION_MIGRATION)
        self.assertIn("v.sla_due_at IS NULL", mig,
                      "a posição da fila não trata o caso sem prazo")
        self.assertIn("q.sla_due_at IS NOT NULL", mig,
                      "a posição da fila não trata o caso sem prazo")
        ci = read("scripts/ci_migrations.sh")
        self.assertIn("a posição não bate com a ordem da fila", ci,
                      "o CI não prova que a posição concorda com a ordem")
        # E o CI tem que EXERCITAR o desempate por `id` no caminho "sem
        # prazo": sem o PAR de casos sem prazo com a MESMA entrada, a
        # mutação que tira o `id` da comparação `(q.created_at, q.id) <=
        # (v.created_at, v.id)` passa com o CI VERDE (medido na 5ª
        # verificação adversarial: um guard que não exercita o defeito é
        # um guard inerte).
        #
        # A presença do par é um guard TEXTUAL — e por isso é ANCORADO
        # (a linha precisa ser um INSERT ATIVO: um par comentado não
        # prova nada, e o regex não casa comentário). A prova de
        # comportamento é o CI rodando com a função mutada.
        par_empatido = re.search(
            r"(?ms)^\s*INSERT INTO kyc_cases \(partner_user_id, status, "
            r"sla_due_at, created_at\)\s*\n"
            r"\s*VALUES \('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', "
            r"'IN_REVIEW',\s*\n"
            r"\s*NULL, now\(\) \+ interval '2 minutes'\),\s*\n"
            r"\s*\('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'IN_REVIEW',\s*\n"
            r"\s*NULL, now\(\) \+ interval '2 minutes'\);",
            ci)
        # `assertIsNotNone` e não `assertRegex`: o `assertRegex` despeja
        # o arquivo INTEIRO na falha (40 KB de ruído), e uma mensagem
        # de erro que esconde a própria mensagem é um guard ruim.
        self.assertIsNotNone(
            par_empatido,
            "o CI não cria o PAR de casos sem prazo com a mesma entrada — "
            "sem ele, o desempate por id nesse caminho fica sem prova")
        self.assertIn("v_emp_max - v_emp_min <> 1", ci,
                      "o CI não exige que os casos empatados sejam "
                      "consecutivos na fila")
        self.assertIn("a fila embaralhou os grupos", ci,
                      "o CI não prova que os casos sem prazo vêm todos "
                      "depois dos casos com prazo")
        # E o openapi promete o mesmo (o contrato não pode dizer uma coisa
        # e o servidor fazer outra). O texto é conferido com o whitespace
        # normalizado: o YAML quebra as linhas como quiser.
        api = " ".join(read("docs/fase2/openapi.yaml").split())
        self.assertIn("sorts LAST (NULLS LAST)", api,
                      "o openapi não diz que o caso sem prazo é o último")
        self.assertIn(
            "the `position` is the index of the case in this very list", api,
            "o openapi não diz que a posição é o índice do caso na fila")

    def test_a_fila_desempata_pelo_id(self):
        # A ordenação FINAL (o `jsonb_agg` externo) precisa usar a MESMA
        # chave do ranking: prazo, entrada e **id**. Sem o desempate, dois
        # casos com o mesmo prazo e a mesma entrada saíam em ordem
        # arbitrária na tela da operação.
        mig = read(self.KYC_CONSOLE_FIX_MIGRATION)
        self.assertIn("ORDER BY q.sla_due_at, q.created_at, q.case_id", mig,
                      "a ordenação final da fila não desempata pelo id")

    def test_openapi_documenta_o_documento_e_a_identidade(self):
        # O contrato publicado precisa contar o que o console consome.
        api = read("docs/fase2/openapi.yaml")
        for campo in ("partner_name:", "partner_phone:", "storage_path:",
                      "has_file:"):
            self.assertIn(campo, api,
                          f"o openapi não documenta {campo}")

    def test_openapi_diz_que_o_campo_nulo_e_omitido(self):
        # A API usa `jsonb_strip_nulls`: um campo NULO não vem como
        # `null`, ele **some**. O openapi precisa dizer isso — senão um
        # cliente novo acha que o campo sempre vem.
        api = read("docs/fase2/openapi.yaml")
        self.assertIn("jsonb_strip_nulls", api,
                      "o openapi não avisa que o campo nulo é OMITIDO")
        self.assertIn("OMITTED when null", api,
                      "o openapi não marca os campos nulos como omitidos")


if __name__ == "__main__":
    unittest.main()

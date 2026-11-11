#!/usr/bin/env python3
"""E2E automatizado do fluxo passageiro ↔ parceiro no emulador Android.

Sobe uma API de demo isolada, compila/instala os dois APKs apontando para ela
e conduz o fluxo real pela interface (uiautomator + adb):

    parceiro ONLINE
      → passageiro pede corrida
      → oferta chega ao parceiro
      → ACEITAR → A_CAMINHO → CHEGUEI → EM_VIAGEM → FINALIZAR
      → dinheiro declarado
      → passageiro vê "Pagamento confirmado"
      → avalia com 5 estrelas
      → API termina com FINALIZADA/CONFIRMED

Dois backends, o mesmo roteiro:

    --backend demo (padrão)
        API de demonstração (scripts/demo_api.py), login de 4 dígitos, o
        estado final é lido da própria API de demo.

    --backend real
        Stack Supabase local: GoTrue (login com OTP de 6 dígitos lido da
        caixa de entrada) + Postgres (cotação congelada, despacho, fases do
        ciclo) + PSP simulado (o webhook assinado é a ÚNICA porta que
        confirma dinheiro). O estado final é conferido na API real e no
        Postgres (ledger). O que ainda não migrou (radar do passageiro,
        geocoding, perfil) continua na API de demo.

Uso (na raiz do repositório):

    python scripts/e2e_emulator.py                    # sobe o AVD sozinho
    python scripts/e2e_emulator.py --skip-build --skip-install
    python scripts/e2e_emulator.py --serial emulator-5554 --no-emulator
    python scripts/e2e_emulator.py --backend real --payment pix

Requisitos: Flutter, Android SDK/platform-tools e a porta da API livre (padrão
8790). Se nenhum dispositivo estiver conectado, o script sobe o único AVD
instalado, espera o boot e o encerra no fim — `--no-emulator` exige um
dispositivo já conectado, `--headless` sobe o AVD sem janela (CI),
`--keep-emulator` deixa o AVD ligado. A API
usa estado em memória; cada execução começa do zero. O script NÃO mata
processos de outras portas.

No modo `--backend real` o stack local precisa estar no ar (`supabase start`),
com o segredo do PSP e o do JWT disponíveis em `PSP_WEBHOOK_SECRET` e
`SUPABASE_JWT_SECRET` (o padrão local do repositório já vem preenchido).

Cada execução grava `.preview/e2e_auto/<timestamp>-a<N>/` com screenshots, o
log da API, `logcat.txt`/`device.json` (em falha) e `result.json` (pass/fail,
corrida, `failure_kind`, `duration_s`). Exit code 0 = PASS.

Esperas são por condição (o rótulo da próxima tela), nunca por `sleep` fixo, e
um toque que não avança a tela é repetido uma única vez — o caso real é o
primeiro frame do Flutter depois do cold start. `--attempts` (default 3) refaz
a tentativa inteira quando a falha é do ambiente — o emulador 37.x segfaulta de
forma intermitente em Windows (`EMU_EXIT=139`), sempre com o AVD novo e
reaproveitando os APKs já compilados. Se todas as tentativas falharem, o exit
code é 1 e cada tentativa fica com seu próprio diretório de evidências.

O teste é intencionalmente um E2E de UI (não substitui os testes Flutter): ele
prova que os dois apps, juntos, completam o fluxo e que o contrato observado
no servidor é o esperado.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PASSAGEIRO = "app.dezemais.passageiro"
PARCEIRO = "app.dezemais.parceiro"
# Preço isolado na tela (o `brl` do app): "R$ 7,50".
MONEY_RE = re.compile(r"^R\$\s*(\d{1,3}(?:\.\d{3})*,\d{2})$")
# Sem --avd: usa o único AVD instalado (e falha listando os candidatos se houver
# mais de um), para o teste não depender do nome do AVD de cada máquina.
EMULATOR_PORT = 5554

# --- stack local (modo `--backend real`) ------------------------------------
# Os defaults são os do `supabase start` deste repositório: o kong em 54321, o
# Postgres (container) em 54322 e a caixa de entrada do GoTrue em 54324.
#
# Nenhum destes valores é segredo de produção: a chave `publishable` é
# pública por desenho (ela vai dentro do app — quem protege os dados é o
# RLS), o segredo do JWT é o padrão conhecido do stack local e o segredo do
# PSP é o da máquina de desenvolvimento. Todos podem ser trocados por
# ambiente/CLI — é assim que o mesmo harness roda contra um projeto real.
DEFAULT_STACK_BASE = "http://127.0.0.1:54321"
DEFAULT_MAIL_BASE = "http://127.0.0.1:54324/api/v1"
DEFAULT_RIDES_BASE = "http://10.0.2.2:54321/functions/v1/rides"
DEFAULT_AUTH_BASE = "http://10.0.2.2:54321/auth/v1"
DEFAULT_RADAR_BASE = "http://10.0.2.2:54321/functions/v1/radar"
DEFAULT_ANON_KEY = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
DEFAULT_PSP_SECRET = "dev-local-2f8a1c4e6b9d3f70"
DEFAULT_JWT_SECRET = "super-secret-jwt-token-with-at-least-32-characters-long"
DEFAULT_DB_CONTAINER = "supabase_db_10_"
# Contas semeadas no stack local (supabase/seed.sql).
DEV_PASSAGEIRO = "11111111-1111-4111-8111-111111111111"
DEV_PARCEIRO = "22222222-2222-4222-8222-222222222222"
LOGIN_PASSAGEIRO = "passageiro@dezemais.local"
LOGIN_PARCEIRO = "parceiro@dezemais.local"
# Janela da oferta no contrato: `PRM-oferta.timeout` (SPECS §1.1, seed.sql,
# API de demo, `city_param` no Postgres). O E2E confere no servidor — é a
# guarda contra a configuração da cidade divergir do SPEC.
OFERTA_TIMEOUT_CONTRATO_S = 15.0


def _iso(valor: object) -> datetime:
    """Carimbo ISO do servidor → datetime com fuso (UTC quando o texto é Z)."""
    texto = str(valor).strip()
    if texto.endswith("Z"):
        texto = texto[:-1] + "+00:00"
    dt = datetime.fromisoformat(texto)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


class E2EFailure(RuntimeError):
    pass


def find_tool(name: str, explicit: str | None, candidates: list[str]) -> str:
    if explicit:
        return explicit
    found = shutil.which(name)
    if found:
        return found
    for candidate in candidates:
        if Path(candidate).exists():
            return candidate
    raise E2EFailure(
        f"{name} não encontrado. Passe o caminho (--{name}) ou ajuste o PATH."
    )


def run(
    cmd: list[str],
    cwd: Path | None = None,
    capture: bool = False,
    timeout: float | None = None,
) -> str:
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            check=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None,
        )
    except subprocess.TimeoutExpired as exc:
        # `adb logcat -d`/`uiautomator` com o dispositivo sumindo ficam
        # esperando para sempre: sem prazo, o teste inteiro pendura.
        raise E2EFailure(
            f"comando excedeu {timeout:.0f}s: {' '.join(map(str, cmd))}"
        ) from exc
    except FileNotFoundError as exc:
        raise E2EFailure(f"comando não encontrado: {cmd[0]}") from exc
    except subprocess.CalledProcessError as exc:
        output = (exc.stdout or "").strip()
        raise E2EFailure(
            f"comando falhou ({exc.returncode}): {' '.join(map(str, cmd))}"
            + (f"\n{output[-2000:]}" if output else "")
        ) from exc
    return (result.stdout or "").strip()


class Adb:
    def __init__(self, executable: str, serial: str | None):
        self.exe = executable
        self.serial = serial

    def cmd(self, *args: str) -> list[str]:
        return [self.exe] + (["-s", self.serial] if self.serial else []) + list(args)

    def shell(
        self, *args: str, capture: bool = True, timeout: float = 60.0
    ) -> str:
        return run(self.cmd("shell", *args), capture=capture, timeout=timeout)

    def choose_device(self) -> str:
        out = run([self.exe, "devices"], capture=True)
        devices = [
            line.split("\t")[0]
            for line in out.splitlines()[1:]
            if "\tdevice" in line
        ]
        if not devices:
            raise E2EFailure("nenhum emulador/dispositivo adb conectado")
        if self.serial:
            if self.serial not in devices:
                raise E2EFailure(f"dispositivo {self.serial} não está conectado")
            return self.serial
        if len(devices) > 1:
            raise E2EFailure(
                "mais de um dispositivo conectado; use --serial: "
                + ", ".join(devices)
            )
        self.serial = devices[0]
        return self.serial

    def install(self, apk: Path) -> None:
        out = run(self.cmd("install", "-r", str(apk)), capture=True, timeout=300)
        if "Success" not in out:
            raise E2EFailure(f"install falhou para {apk}:\n{out}")

    def clear(self, package: str) -> None:
        out = self.shell("pm", "clear", package)
        if "Success" not in out:
            raise E2EFailure(f"pm clear falhou para {package}: {out}")

    def grant(self, package: str, permission: str) -> None:
        # Permissões variam por API; ausência não deve derrubar o teste.
        run(
            self.cmd("shell", "pm", "grant", package, permission),
            capture=True,
        )

    def launch(self, package: str) -> None:
        """Abre o app e garante que ele fica em primeiro plano.

        O `am start` (intent do launcher) traz a tarefa para a frente sem
        injetar eventos: ~1 s contra ~2 s do `monkey`. A diferença importa:
        a oferta do parceiro vive 15 s (PRM-oferta.timeout) e cada segundo
        do harness sai da janela do produto.

        O `monkey` continua como reserva (se o `am start` não resolver a
        activity). O `monkey` injeta o evento, mas o app às vezes fica
        **por baixo** de outra janela (keyguard, tela de bloqueio, widget
        do launcher): o uiautomator passa a ver a tela errada e o fluxo
        falha como se o produto estivesse quebrado. Aqui a tela é acordada,
        o keyguard sai e o foco é conferido — com uma segunda tentativa.
        """
        for attempt in range(2):
            out = self.shell(
                "am", "start",
                "-a", "android.intent.action.MAIN",
                "-c", "android.intent.category.LAUNCHER",
                "-n", f"{package}/{package}.MainActivity",
            )
            if "Error" in out or "Exception" in out:
                # `am start` não resolveu (activity com outro nome): o
                # monkey resolve pelo intent do launcher.
                out = run(
                    self.cmd(
                        "shell", "monkey", "-p", package,
                        "-c", "android.intent.category.LAUNCHER", "1",
                    ),
                    capture=True,
                    timeout=60,
                )
                if "Events injected: 1" not in out:
                    raise E2EFailure(f"não consegui abrir {package}:\n{out}")
            if self._focused_within(package, timeout=15):
                return
            if attempt == 0:
                print(f"    {package} não ficou em foco; acordando a tela")
                self.shell("input", "keyevent", "KEYCODE_WAKEUP")
                self.shell("wm", "dismiss-keyguard")
                time.sleep(2)
        print(f"    aviso: {package} não ficou em foco (o fluxo vai decidir)")

    def _focused_within(self, package: str, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if self.current_package() == package:
                    return True
            except E2EFailure:
                pass
            time.sleep(1)
        return False

    def state(self) -> str | None:
        """Estado do dispositivo no adb ('device', 'offline' ou None)."""
        try:
            out = run(self.cmd("get-state"), capture=True, timeout=20)
        except E2EFailure:
            out = run([self.exe, "devices"], capture=True, timeout=20)
            for line in out.splitlines():
                parts = line.split("\t")
                if len(parts) == 2 and (not self.serial or parts[0] == self.serial):
                    return parts[1].strip()
            return None
        return out.strip() or None

    def current_package(self) -> str | None:
        out = self.shell("dumpsys", "window")
        match = re.search(r"mCurrentFocus=Window\{\S+ \S+ ([\w.]+)/", out)
        return match.group(1) if match else None


def fix_geo(adb: Adb) -> None:
    """Reposiciona o AVD na praça piloto (Centro de Porto Velho).

    `emu` é comando do **console** do emulador, não do shell do Android:
    `adb shell emu ...` responde "inaccessible or not found" no API 37. O
    caminho certo é `adb emu geo fix <lon> <lat>` (sem `shell`).
    """
    run(adb.cmd("emu", "geo", "fix", "-63.9039", "-8.7607"), capture=True)


def tune_device(adb: Adb) -> None:
    """Deixa o dispositivo determinístico: sem animações, sem diálogo de ANR."""
    settings = {
        # Sem animações: os dumps ficam estáveis e os taps não erram alvo.
        "window_animation_scale": "0",
        "transition_animation_scale": "0",
        "animator_duration_scale": "0",
        # Emulador recém-bootado é lento: o System UI dispara ANR e o diálogo
        # modal esconde o app do dump. Sem diálogos de erro.
        "hide_error_dialogs": "1",
        "show_first_crash_dialog": "0",
        # O freezer congela apps em cache. O app do parceiro fica em segundo
        # plano durante o pedido do passageiro e, congelado, não responde ao
        # evento de modo toque em 5 s — o Android mata por "bg anr" e o login
        # em memória se perde. No teste, manter o processo descongelado.
        "cached_apps_freezer": "disabled",
    }
    for key, value in settings.items():
        run(adb.cmd("shell", "settings", "put", "global", key, value), capture=True)
    run(adb.cmd("shell", "wm", "dismiss-keyguard"), capture=True)
    run(adb.cmd("shell", "input", "keyevent", "82"), capture=True)
    # Sem teclado virtual. O IME cria uma segunda superfície composta junto do
    # Flutter e no AVD x86_64 (API 37) isso derrubava o emulador inteiro no
    # exato momento em que o campo de texto abria — o `input text` continua
    # entrando pelo teclado de hardware do AVD.
    run(adb.cmd("shell", "settings", "put", "secure",
                "show_ime_with_hard_keyboard", "0"), capture=True)
    imes = run(adb.cmd("shell", "ime", "list", "-s"), capture=True)
    for ime in imes.split():
        run(adb.cmd("shell", "ime", "disable", ime), capture=True)
    # GPS dentro da praça piloto (Centro de Porto Velho). Sem isso o AVD
    # responde fora da área de serviço e o radar procura motorista em outra
    # cidade — o teste passaria a acusar "nenhum motorista" sem ser bug.
    try:
        fix_geo(adb)
    except E2EFailure:
        pass  # dispositivo físico: não há geo fix
    # System UI ainda se estabiliza depois do boot_completed.
    time.sleep(3)


class Emulator:
    """Ciclo de vida do AVD: boot headless determinístico e teardown."""

    def __init__(self, exe: str, adb: Adb, artifacts: Path):
        self.exe = exe
        self.adb = adb
        self.artifacts = artifacts
        self.proc: subprocess.Popen | None = None
        self.serial: str | None = None

    def list_avds(self) -> list[str]:
        out = run([self.exe, "-list-avds"], capture=True)
        return [line.strip() for line in out.splitlines() if line.strip()]

    def boot(
        self,
        avd: str,
        timeout: float = 240.0,
        headless: bool = False,
        gpu: str = "",
    ) -> str:
        avds = self.list_avds()
        if not avd:
            if len(avds) == 1:
                avd = avds[0]
            elif not avds:
                raise E2EFailure(
                    "nenhum AVD instalado — crie um com `avdmanager` ou passe --avd."
                )
            else:
                raise E2EFailure(
                    "mais de um AVD; escolha com --avd: " + ", ".join(avds)
                )
        elif avd not in avds:
            raise E2EFailure(
                f"AVD {avd!r} não existe. Disponíveis: "
                + (", ".join(avds) or "nenhum")
                + " — crie um com `avdmanager` ou passe --avd."
            )
        self.serial = f"emulator-{EMULATOR_PORT}"
        log = open(self.artifacts / "emulator.log", "wb")
        # Snapshot desligado: boot do zero, igual em qualquer máquina.
        # Janela por padrão: o emulador headless (swiftshader) se mostrou
        # instável em Windows (morria ~5 min depois do boot, no meio do fluxo).
        args = [
            self.exe, "-avd", avd, "-port", str(EMULATOR_PORT),
            "-no-snapshot", "-no-boot-anim", "-no-audio",
            "-camera-back", "none", "-camera-front", "none",
            # Vulkan do guest pelo llvmpipe do host derrubava o AVD
            # ("Failed to find ColorBuffer" / "invalid color buffer").
            "-feature", "-Vulkan",
            # 2 GB de RAM no guest, não 4: com o host de 12 GB o qemu chegava a
            # 5 GB e, junto do build do Gradle e dos dois apps, esgotava a
            # memória do host — era isso que matava o emulador no meio do fluxo.
            "-memory", "2048",
            # Kernel do guest no stdout: quando o AVD sai sozinho, o
            # emulator.log é o único lugar onde a causa ainda existe.
            "-show-kernel",
        ]
        # GPU: sem --gpu, o emulador escolhe. Em headless (sem janela) o
        # default do emulador no Windows é o rasterizador por software
        # (swiftshader), que deixa cada frame do mapa em ~5 s — o mapa do
        # passageiro vira o gargalo do teste. A GPU do HOST (OpenGL ES
        # Translator) renderiza o mesmo mapa em milissegundos e roda
        # headless sem janela; por isso o default em headless é "host".
        # ( lavapipe/swatchsdl continuam disponíveis por --gpu.)
        if gpu:
            args += ["-gpu", gpu]
        elif headless:
            args += ["-gpu", "host"]
        if headless:
            args.append("-no-window")
        print(f"    subindo AVD {avd} ({self.serial})")
        self.proc = subprocess.Popen(
            args,
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        self.adb.serial = self.serial
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise E2EFailure(
                    f"emulador encerrou durante o boot (código "
                    f"{self.proc.returncode}); veja {self.artifacts / 'emulator.log'}"
                )
            state = run(
                [self.adb.exe, "-s", self.serial, "get-state"], capture=True
            ) if self._connected() else ""
            if state == "device":
                booted = run(
                    [self.adb.exe, "-s", self.serial, "shell",
                     "getprop", "sys.boot_completed"],
                    capture=True,
                )
                if booted.strip() == "1":
                    tune_device(self.adb)
                    print("    AVD pronto")
                    return self.serial
            time.sleep(2)
        raise E2EFailure(f"emulador não concluiu o boot em {timeout:.0f}s")

    def _connected(self) -> bool:
        out = run([self.adb.exe, "devices"], capture=True)
        return any(
            line.split("\t")[0] == self.serial and "\tdevice" in line
            for line in out.splitlines()
        )

    def shutdown(self) -> None:
        if not self.serial:
            return
        try:
            run([self.adb.exe, "-s", self.serial, "emu", "kill"], capture=True)
        except E2EFailure:
            pass
        if self.proc is not None:
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class Ui:
    """Leitor/acionador de UI via uiautomator, com retry para animações."""

    # Diálogos de ANR/crash do sistema que podem cobrir o app. Só "esperar" é
    # seguro: fechar o app derrubaria o próprio teste.
    SYSTEM_DIALOGS = ("Wait", "Aguardar", "Esperar")

    def __init__(self, adb: Adb, artifacts: Path):
        self.adb = adb
        self.artifacts = artifacts

    def dismiss_system_dialogs(self, root: ET.Element | None = None) -> bool:
        """Descarta ANR/crash do sistema; devolve True se agiu na tela."""
        try:
            root = root if root is not None else self.dump(save_on_error=False)
        except E2EFailure:
            return False
        for label, x, y, _ in self.nodes(root):
            if label in self.SYSTEM_DIALOGS:
                print(f"    descartando diálogo do sistema ({label!r})")
                self.adb.shell("input", "tap", str(x), str(y))
                time.sleep(0.8)
                return True
        return False

    def dump(self, save_on_error: bool = True) -> ET.Element:
        last = ""
        raw = ""
        for attempt in range(4):
            self.adb.shell("rm", "-f", "/sdcard/e2e-ui.xml")
            # `--compressed` SEMPRE: medido neste emulador, o dump completo
            # leva ~7 s e o comprimido ~2,2 s (o XML perde nós que não têm
            # rótulo — nada que a busca por texto use). A diferença é
            # decisiva: a oferta do parceiro vive 15 s (PRM-oferta.timeout) e
            # o roteiro fazia 5 dumps no caminho crítico — 35 s de espera
            # quando o teste perdia a corrida por lentidão do harness,
            # não por defeito do produto.
            extra = ("--compressed",)
            t0 = time.monotonic()
            out = self.adb.shell(
                "uiautomator", "dump", *extra, "/sdcard/e2e-ui.xml"
            )
            elapsed = time.monotonic() - t0
            # O dump espera a tela "parada": em tela com animação (o radar
            # pulsando, o cronômetro da oferta) ele espera o tempo de idle do
            # sistema. Medir é o que permite saber onde o tempo foi.
            if elapsed > 1.5:
                print(f"    dump lento: {elapsed:.1f}s")
            last = out
            if "dumped" in out.lower():
                raw = run(
                    self.adb.cmd("exec-out", "cat", "/sdcard/e2e-ui.xml"),
                    capture=True,
                )
                try:
                    return ET.fromstring(raw)
                except ET.ParseError as exc:
                    last = f"XML inválido: {exc}\n{raw[:500]}"
            time.sleep(0.7)
        if save_on_error:
            self.shot("failure-ui")
            if raw:
                (self.artifacts / "failure-ui.xml").write_text(
                    raw, encoding="utf-8", errors="replace"
                )
        state = self.adb.state()
        hint = ""
        if state != "device":
            hint = (
                f" — adb não vê o dispositivo (estado: {state or 'ausente'}). "
                "O emulador caiu durante o teste; veja o emulator.log "
                "desta execução."
            )
        raise E2EFailure(f"uiautomator dump falhou após retries: {last}{hint}")

    def nodes(self, root: ET.Element | None = None):
        root = root if root is not None else self.dump()
        for node in root.iter("node"):
            label = (
                node.attrib.get("content-desc")
                or node.attrib.get("text")
                or ""
            ).strip()
            if not label:
                continue
            x1, y1, x2, y2 = map(int, re.findall(r"-?\d+", node.attrib["bounds"]))
            yield label, (x1 + x2) // 2, (y1 + y2) // 2, node

    def find(
        self,
        text: str,
        *,
        exact: bool = False,
        timeout: float = 10.0,
    ) -> tuple[int, int] | None:
        deadline = time.monotonic() + timeout
        needle = text.lower()
        while time.monotonic() < deadline:
            try:
                root = self.dump(save_on_error=False)
            except E2EFailure:
                time.sleep(0.5)
                continue
            self.remember_labels(root)
            for label, x, y, _ in self.nodes(root):
                match = label == text if exact else needle in label.lower()
                if match:
                    self._remember_pos(text, exact, (x, y))
                    return x, y
            if self.dismiss_system_dialogs(root):
                continue
            time.sleep(0.5)
        return None

    def find_regex(
        self,
        pattern: str,
        *,
        timeout: float = 10.0,
    ) -> str | None:
        """Procura um rótulo que case a expressão regular (e devolve o rótulo).

        Por que existe: `find`/`wait_text` casam por SUBSTRING — "motorista"
        também casa em "Nenhum motorista por perto". O E2E passava com o radar
        vazio por causa disso. A regex exige o número positivo.
        """
        deadline = time.monotonic() + timeout
        rx = re.compile(pattern, re.IGNORECASE)
        while time.monotonic() < deadline:
            try:
                root = self.dump(save_on_error=False)
            except E2EFailure:
                time.sleep(0.5)
                continue
            for label, _x, _y, _ in self.nodes(root):
                if rx.search(label):
                    return label
            if self.dismiss_system_dialogs(root):
                continue
            time.sleep(0.5)
        return None

    def wait_regex(self, pattern: str, *, timeout: float = 30.0) -> str:
        label = self.find_regex(pattern, timeout=timeout)
        if label is None:
            self.shot(
                f"missing-regex-{re.sub(r'[^a-z0-9]+', '-', pattern.lower())[:40]}"
            )
            raise E2EFailure(
                f"timeout esperando /{pattern}/ em {timeout:.0f}s"
                f" — rótulos na tela: {self.visible_summary()}"
            )
        print(f"    ok  /{pattern}/ -> {label!r}")
        return label

    def tap(
        self,
        text: str,
        *,
        exact: bool = False,
        timeout: float = 10.0,
        required: bool = True,
    ) -> bool:
        pos = self._recent_pos(text, exact)
        if pos is None:
            pos = self.find(text, exact=exact, timeout=timeout)
        if pos is None:
            if not required:
                return False
            self.shot(f"missing-{re.sub(r'[^a-z0-9]+', '-', text.lower())[:40]}")
            raise E2EFailure(f"não encontrei {text!r} na tela")
        self.adb.shell("input", "tap", str(pos[0]), str(pos[1]))
        print(f"    tap {text!r} @ {pos}")
        return True

    # A posição vista há pouco pode ser reaproveitada: um `uiautomator dump`
    # leva ~2,2 s neste emulador e a oferta do parceiro vive 15 s. Reaproveitar
    # o dump do `wait_text` que acabou de encontrar o botão poupa ~2 s da
    # janela — sem mudar o que é verificado.
    _LAST_HIT_TTL_S = 4.0
    _recent: dict[tuple[str, bool], tuple[tuple[int, int], float]] = {}

    def _remember_pos(self, text: str, exact: bool, pos: tuple[int, int]) -> None:
        self._recent[(text, exact)] = (pos, time.monotonic())

    def _remember_labels(self, root: ET.Element) -> None:
        """Guarda as posições de todos os rótulos de um dump.

        Serve para o toque seguinte não precisar de OUTRO dump: a tela não
        mudou entre os dois (o harness acabou de ler).
        """
        at = time.monotonic()
        for label, x, y, _ in self.nodes(root):
            # Sobrescreve (não `setdefault`): este dump é mais novo que o
            # anterior, e é ele que vale como posição atual. Sem isso o
            # carimbo ficava no dump velho e o toque seguinte expirava
            # (TTL de 4 s) — gastando um dump inteiro (~2,5 s) da janela.
            self._recent[(label, True)] = ((x, y), at)
            self._recent[(label, False)] = ((x, y), at)

    # Alias público: o roteiro (fora da classe) também guarda o dump que leu.
    remember_labels = _remember_labels

    def _recent_pos(self, text: str, exact: bool) -> tuple[int, int] | None:
        hit = self._recent.get((text, exact))
        if hit is not None:
            pos, at = hit
            if time.monotonic() - at <= self._LAST_HIT_TTL_S:
                return pos
            return None
        if not exact:
            # `find` sem `exact` casa por substring: procura o mesmo jeito.
            needle = text.lower()
            best: tuple[tuple[int, int], float] | None = None
            for (label, was_exact), value in self._recent.items():
                if was_exact or needle not in label.lower():
                    continue
                if best is None or value[1] > best[1]:
                    best = value
            if best is not None and time.monotonic() - best[1] <= self._LAST_HIT_TTL_S:
                return best[0]
        return None

    def wait_text(
        self,
        text: str,
        *,
        exact: bool = False,
        timeout: float = 30.0,
    ) -> None:
        pos = self.find(text, exact=exact, timeout=timeout)
        if pos is None:
            self.shot(f"missing-{re.sub(r'[^a-z0-9]+', '-', text.lower())[:40]}")
            raise E2EFailure(
                f"timeout esperando {text!r} em {timeout:.0f}s"
                f" — rótulos na tela: {self.visible_summary()}"
            )
        self._remember_pos(text, exact, pos)
        print(f"    ok  {text!r}")

    def visible_summary(self, limit: int = 8) -> str:
        """Rótulos visíveis agora — o que faltava para diagnosticar um timeout."""
        try:
            labels = [label for label, *_ in self.nodes(self.dump(save_on_error=False))]
        except E2EFailure as exc:
            return f"(dump indisponível: {exc})"
        unique = list(dict.fromkeys(labels))[:limit]
        return " | ".join(unique) if unique else "(sem rótulos)"

    def price_shown(self, timeout: float = 10.0) -> float | None:
        """Valor da cotação que o passageiro está vendo agora.

        O Flutter **mescla** a semântica do card inteiro num nó só: o
        rótulo vem como "Valor no momento\\nvale por 69s\\nR$ 7,50\\nBase
        R$ 6,10 · ...". Por isso o preço é procurado **linha a linha** e
        precisa ser a linha inteira — a linha "Base R$ 6,10 · ..." é a
        conta, não o valor cobrado.

        É a prova do lado do app: o número que está na tela.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                root = self.dump(save_on_error=False)
            except E2EFailure:
                time.sleep(0.5)
                continue
            self.remember_labels(root)
            valor = self._price_in(root, prefer_card=True)
            if valor is None:
                valor = self._price_in(root, prefer_card=False)
            if valor is not None:
                return valor
            time.sleep(0.5)
        return None

    def _price_in(self, root: ET.Element, *, prefer_card: bool) -> float | None:
        """Preço isolado nos rótulos do dump (card da cotação primeiro)."""
        for label, *_ in self.nodes(root):
            if prefer_card and "Valor no momento" not in label:
                continue
            for line in label.splitlines():
                m = MONEY_RE.match(line.strip())
                if m:
                    return float(m.group(1).replace(".", "").replace(",", "."))
        return None

    def tap_and_wait(
        self,
        tap_text: str,
        expect_text: str,
        *,
        exact: bool = True,
        timeout: float = 45.0,
    ) -> None:
        """Toca e confirma a próxima tela; re-toca **uma** vez se ela demorar.

        Só re-toca quando a tela de origem continua na frente e a de destino
        não chegou: o caso real é o toque perdido no primeiro frame depois do
        cold start. Se o toque já avançou, nada é repetido (evita duplicar
        ações de escrita).
        """
        self.tap(tap_text, exact=exact, timeout=15)
        try:
            self.wait_text(expect_text, exact=exact, timeout=timeout)
            return
        except E2EFailure:
            if self.find(expect_text, exact=exact, timeout=1) is not None:
                print(f"    ok  {expect_text!r}")
                return
            if self.find(tap_text, exact=exact, timeout=1) is None:
                raise  # a tela mudou para algo inesperado: não insista
            print(
                f"    {tap_text!r} não abriu {expect_text!r} em {timeout:.0f}s;"
                " tocando de novo"
            )
        self.tap(tap_text, exact=exact, timeout=10)
        self.wait_text(expect_text, exact=exact, timeout=timeout)

    def tap_edit(self, index: int = 0) -> None:
        edit_nodes = []
        for node in self.dump().iter("node"):
            klass = node.attrib.get("class", "")
            if klass.endswith("EditText"):
                x1, y1, x2, y2 = map(
                    int, re.findall(r"-?\d+", node.attrib["bounds"])
                )
                edit_nodes.append(((x1 + x2) // 2, (y1 + y2) // 2))
        if index >= len(edit_nodes):
            raise E2EFailure(
                f"não encontrei EditText #{index} (achei {len(edit_nodes)})"
            )
        x, y = edit_nodes[index]
        self.adb.shell("input", "tap", str(x), str(y))
        print(f"    tap campo de texto #{index} @ {(x, y)}")

    def clear_focused_text(self) -> None:
        self.adb.shell("input", "keyevent", "123")  # MOVE_END
        self.adb.shell("input", "keyevent", *(["67"] * 24))  # DEL x24
        time.sleep(0.2)

    def field_digits(self) -> list[str]:
        """Só os dígitos dos campos de texto visíveis (a máscara os separa)."""
        found = []
        for node in self.dump(save_on_error=False).iter("node"):
            if node.attrib.get("class", "").endswith("EditText"):
                found.append(re.sub(r"\D", "", node.attrib.get("text", "")))
        return found

    def fill_field(self, text: str, *, label: str, attempts: int = 3) -> None:
        """Digita num campo e confere que os dígitos chegaram lá.

        O toque pode cair antes de o sheet/bottom-sheet terminar de entrar; sem
        editor focado o `input text` descarta os dígitos em silêncio e o fluxo
        só falha na tela seguinte, já sem relação aparente com o campo.
        """
        digits = re.sub(r"\D", "", text)
        for attempt in range(1, attempts + 1):
            self.tap_edit()
            self.clear_focused_text()
            self.type_text(text)
            typed = self.field_digits()
            if any(digits and digits in value for value in typed):
                self.hide_keyboard()
                return
            print(f"    {label}: campo vazio após digitar (tentativa {attempt}) {typed}")
            self.hide_keyboard()
        raise E2EFailure(f"não consegui preencher {label} ({text!r})")

    def type_text(self, text: str) -> None:
        # `input text` não aceita espaço literal; %s é o escape do Android.
        escaped = text.replace("%", "\\%").replace(" ", "%s")
        self.adb.shell("input", "text", escaped)
        print(f"    type {text!r}")

    def hide_keyboard(self) -> None:
        self.adb.shell("input", "keyevent", "4")
        time.sleep(0.4)

    def keyboard_visible(self) -> bool:
        """O teclado (IME) está aberto nesta tela?

        Importa porque o `BACK` (keyevent 4) **volta a rota** quando o
        teclado já está fechado — um `hide_keyboard()` cego pode desandar no
        fluxo. Este helper pergunta ao próprio Android.
        """
        out = self.adb.shell("dumpsys", "input_method")
        for line in out.splitlines():
            if "mInputShown=" in line:
                return "mInputShown=true" in line
        return False

    def dismiss_keyboard(self) -> bool:
        """Fecha o teclado **só** se ele estiver aberto. Devolve o que fez.

        Com o teclado aberto, a tela perde ~40% da altura e o card de cotação
        do destino fica abaixo da dobra — o `uiautomator dump` não enxerga
        o que está fora da área visível, e o E2E lia "não achei a cotação".
        O app já fecha o teclado quando o endereço fica completo (correção
        na raiz); isto é a rede de proteção do harness.
        """
        if not self.keyboard_visible():
            return False
        self.adb.shell("input", "keyevent", "4")
        time.sleep(0.6)
        print("    teclado fechado (a cotação ficava fora da tela)")
        return True

    def back(self) -> None:
        self.adb.shell("input", "keyevent", "4")
        time.sleep(0.5)

    def shot(self, name: str) -> Path | None:
        path = self.artifacts / f"{name}.png"
        # screencap é binário: não passe por run(), que decodifica UTF-8.
        # A captura nunca deve mascarar o erro que motivou o screenshot.
        try:
            data = subprocess.run(
                self.adb.cmd("exec-out", "screencap", "-p"),
                check=True,
                capture_output=True,
                timeout=30,
            ).stdout
        except (subprocess.CalledProcessError, OSError,
                subprocess.TimeoutExpired) as exc:
            print(f"    aviso: screenshot {name} falhou ({exc})", file=sys.stderr)
            return None
        path.write_bytes(data)
        print(f"    [{_clock()}] screenshot {path.name}")
        return path


def _clock() -> str:
    """Hora local no formato HH:MM:SS.mmm — para medir a janela da oferta.

    A oferta vive 15 s (PRM-oferta.timeout). Sem carimbo de tempo nos passos
    do roteiro é impossível dizer onde o tempo foi: o sintoma é o mesmo
    ("Oferta perdida por tempo") tanto se o atraso está no despacho do
    servidor quanto se está no harness esperando a tela.
    """
    t = time.time()
    return time.strftime("%H:%M:%S", time.localtime(t)) + f".{int((t % 1) * 1000):03d}"


def api(
    base: str,
    method: str,
    path: str,
    body: dict | None = None,
    timeout: float = 10.0,
) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("content-type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        return exc.code, (json.loads(raw) if raw else {})


def wait_api(base: str, path: str, timeout: float = 15.0) -> dict:
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        try:
            status, payload = api(base, "GET", path, timeout=3)
            if status == 200:
                return payload
            last = f"HTTP {status}: {payload}"
        except Exception as exc:  # servidor ainda subindo
            last = str(exc)
        time.sleep(0.4)
    raise E2EFailure(f"API não respondeu em {path}: {last}")


# ---------------------------------------------------------------------------
# Backend real (stack Supabase local)
# ---------------------------------------------------------------------------
class RealBackend:
    """GoTrue (acesso) + Postgres (ciclo da corrida) + PSP (dinheiro).

    O app entra pelas mesmas portas do piloto:

      - `AUTH_BASE` → GoTrue (OTP de 6 dígitos, chega por e-mail);
      - `RIDES_BASE` → Edge Function `rides` (Postgres: cotação congelada,
        despacho, fases, avaliação);
      - `KYC_BASE` → Edge Function `kyc` (Postgres: fila do cadastro do
        parceiro, SLA, decisão da operação);
      - o que ainda não migrou (radar do passageiro, geocoding, perfil,
        carteira) → API de demonstração, como no build de piloto.

    O dinheiro tem UM caminho só: o webhook assinado do PSP. O harness faz o
    papel do PSP (`--payment pix`) — o app nunca confirma pagamento sozinho.
    """

    name = "real"

    def __init__(
        self,
        *,
        device_api_base: str,
        stack_base: str = DEFAULT_STACK_BASE,
        device_rides_base: str = DEFAULT_RIDES_BASE,
        device_auth_base: str = DEFAULT_AUTH_BASE,
        device_radar_base: str = DEFAULT_RADAR_BASE,
        anon_key: str = DEFAULT_ANON_KEY,
        mail_base: str = DEFAULT_MAIL_BASE,
        psp_secret: str = DEFAULT_PSP_SECRET,
        jwt_secret: str = DEFAULT_JWT_SECRET,
        db_container: str = DEFAULT_DB_CONTAINER,
        payment: str = "pix",
    ) -> None:
        self.device_api_base = device_api_base
        self.stack_base = stack_base.rstrip("/")
        self.device_rides_base = device_rides_base
        self.device_auth_base = device_auth_base
        self.device_radar_base = device_radar_base
        self.anon_key = anon_key
        self.mail_base = mail_base.rstrip("/")
        self.psp_secret = psp_secret
        self.jwt_secret = jwt_secret
        self.db_container = db_container
        self.payment = payment

    # --- build ------------------------------------------------------------
    def dart_defines(self) -> list[str]:
        return [
            f"API_BASE={self.device_api_base}",
            f"RIDES_BASE={self.device_rides_base}",
            f"AUTH_BASE={self.device_auth_base}",
            # A presença e o radar (Postgres) também são reais neste build:
            # sem isto o parceiro publicaria presença na API de demo e o
            # passageiro veria os motoristas sintéticos dela.
            f"RADAR_BASE={self.device_radar_base}",
            f"AUTH_ANON_KEY={self.anon_key}",
        ]

    # --- prontidão --------------------------------------------------------
    def wait_ready(self, timeout: float = 30.0) -> None:
        """Confere que as três portas do stack respondem antes do build.

        Sem isso o E2E falha tarde (no login) com um erro que parece do app.
        """
        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            try:
                req = urllib.request.Request(
                    f"{self.stack_base}/auth/v1/health", method="GET")
                req.add_header("apikey", self.anon_key)
                with urllib.request.urlopen(req, timeout=5) as resp:
                    if resp.status == 200:
                        urllib.request.urlopen(
                            f"{self.mail_base}/messages?folder=INBOX", timeout=5
                        ).read()
                        return
            except Exception as exc:
                last = str(exc)
            time.sleep(1.0)
        raise E2EFailure(
            f"stack local não respondeu (GoTrue/Auth em {self.stack_base}/auth/v1, "
            f"caixa em {self.mail_base}): {last}. Suba com `supabase start`."
        )

    # --- login ------------------------------------------------------------
    def login(self, ui: Ui, package: str, done_text: str, email: str) -> None:
        """Login de verdade: e-mail → código de 6 dígitos conferido no GoTrue."""
        print(f"  login {package} (GoTrue: {email})")
        ui.adb.launch(package)
        ui.wait_text("Entrar ou criar conta", timeout=30)
        ui.tap("CONTINUAR", exact=True)
        ui.fill_field("69999999999", label="celular")
        ui.tap("CONTINUAR", exact=True)

        # Etapa de e-mail: o piloto não tem provedor de SMS, então o código vem
        # por e-mail (e o telefone é registrado depois do login).
        ui.wait_text("E-mail", exact=True, timeout=20)
        ui.tap_edit()
        ui.clear_focused_text()
        ui.type_text(email)
        ui.hide_keyboard()
        ui.tap("CONTINUAR", exact=True)

        ui.wait_text("Código de verificação", timeout=45)
        code = self.otp(email, timeout=90)
        print(f"    OTP de {email}: {code}")
        ui.fill_field(code, label="código OTP")
        ui.tap_and_wait("ENTRAR", done_text, timeout=60)

    def otp(self, email: str, timeout: float = 90.0) -> str:
        """Lê o código de 6 dígitos na caixa de entrada do GoTrue (Inbucket)."""
        deadline = time.time() + timeout
        last = "sem mensagem"
        while time.time() < deadline:
            try:
                listing = json.load(urllib.request.urlopen(
                    f"{self.mail_base}/messages?folder=INBOX", timeout=10))
            except Exception as exc:
                last = str(exc)
                time.sleep(1.5)
                continue
            messages = [
                m for m in listing.get("messages", [])
                if any((t.get("Address") or "").lower() == email.lower()
                       for t in (m.get("To") or []))
            ]
            messages.sort(key=lambda m: m.get("Created") or "", reverse=True)
            for message in messages:
                try:
                    full = json.load(urllib.request.urlopen(
                        f"{self.mail_base}/message/{message['ID']}", timeout=10))
                except Exception:
                    continue
                body = f"{full.get('Text') or ''}\n{full.get('HTML') or ''}"
                codes = list(dict.fromkeys(
                    re.findall(r"(?<!\d)(\d{6})(?!\d)", body)))
                if not codes:
                    continue
                if len(codes) > 1:
                    raise E2EFailure(
                        f"caixa de {email} tem mais de um código: {codes}")
                return codes[0]
            time.sleep(1.5)
        raise E2EFailure(
            f"não chegou OTP para {email} em {timeout:.0f}s ({last})")

    # --- API do ciclo (a mesma porta que o app usa) ------------------------
    def token(self, role: str) -> str:
        """JWT de desenvolvimento da conta semeada (para conferir o estado).

        Não é o caminho do app (lá o token vem do login) — é o caminho do
        VERIFICADOR: ler o estado final pela mesma API que o app usa.
        """
        sys.path.insert(0, str(ROOT / "scripts"))
        import dev_jwt  # noqa: E402  (import tardio: só no modo real)

        now = int(time.time())
        sub = DEV_PARCEIRO if role == "partner" else DEV_PASSAGEIRO
        return dev_jwt.sign(
            {
                "sub": sub,
                "role": "authenticated",
                "aud": "authenticated",
                "iss": "supabase",
                "iat": now,
                "exp": now + 3600,
            },
            self.jwt_secret,
        )

    def api(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        role: str = "passenger",
        timeout: float = 20.0,
    ) -> tuple[int, dict]:
        url = f"{self.stack_base}/functions/v1/rides{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("authorization", "Bearer " + self.token(role))
        req.add_header("apikey", self.anon_key)
        req.add_header("content-type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8")
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8")
            try:
                return exc.code, json.loads(raw)
            except Exception:
                return exc.code, {"raw": raw}

    # --- Postgres (a verdade do dinheiro) ---------------------------------
    def psql(self, sql: str) -> list[str]:
        out = subprocess.run(
            [
                "docker", "exec", self.db_container,
                "psql", "-U", "postgres", "-d", "postgres", "-Atc", sql,
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=40,
        )
        if out.returncode != 0:
            raise E2EFailure(
                f"psql no container {self.db_container} falhou: "
                f"{out.stderr.strip()[:400]}")
        return [line.strip() for line in out.stdout.splitlines() if line.strip()]

    def presence_status(self, partner_id: str = DEV_PARCEIRO) -> str:
        rows = self.psql(
            "SELECT online_status FROM partner_presence "
            f"WHERE partner_user_id = '{partner_id}'")
        return rows[0] if rows else "AUSENTE"

    def presence_age_s(self, partner_id: str = DEV_PARCEIRO) -> float | None:
        """Segundos desde o último heartbeat da presença (None se não há linha).

        O servidor só mostra quem deu sinal de vida nos últimos 90 s. Esta
        idade é o invariante do produto: enquanto o parceiro está online, a
        presença precisa ficar fresca — mesmo com o app em segundo plano.
        """
        rows = self.psql(
            "SELECT EXTRACT(EPOCH FROM (now() - last_heartbeat_at))::float "
            "FROM partner_presence "
            f"WHERE partner_user_id = '{partner_id}'")
        if not rows:
            return None
        try:
            return float(rows[0])
        except ValueError:
            return None

    def offer_window_s(self) -> float | None:
        """Janela da última oferta (timeout_at - sent_at), em segundos.

        É o `PRM-oferta.timeout` do contrato (15 s). Conferir no servidor —
        e não no relógio do cliente — é o que pega a classe de bug em que a
        configuração da cidade diverge do contrato (no banco local a janela
        estava em 60 s enquanto o SPEC, o seed e a API de demo dizem 15 s:
        o passageiro esperava 4× mais por um motorista que não respondeu).
        """
        rows = self.psql(
            "SELECT EXTRACT(EPOCH FROM (timeout_at - sent_at))::float "
            "FROM offers ORDER BY sent_at DESC LIMIT 1")
        if not rows:
            return None
        try:
            return float(rows[0])
        except ValueError:
            return None

    def offer_sent_at(self) -> datetime | None:
        """Quando o servidor ENVIOU a oferta (UTC, com fuso).

        É a referência da janela: o tempo do cliente (o `adb input tap` no
        emulador) é comparado com este carimbo. Os dois vêm do MESMO relógio
        (epoch UTC), então a comparação vale mesmo com o host em UTC-4 e o
        Postgres em UTC.
        """
        rows = self.psql(
            "SELECT EXTRACT(EPOCH FROM sent_at)::float "
            "FROM offers ORDER BY sent_at DESC LIMIT 1")
        if not rows:
            return None
        try:
            return datetime.fromtimestamp(float(rows[0]), tz=timezone.utc)
        except ValueError:
            return None

    def payment_id(self, ride_id: str, method: str = "PIX") -> str:
        rows = self.psql(
            "SELECT id FROM payments WHERE ride_id = "
            f"'{ride_id}' AND method = '{method}' ORDER BY created_at DESC LIMIT 1")
        return rows[0] if rows else ""

    def ride_audit(self, ride_id: str) -> dict:
        """Lê a corrida direto no Postgres (o que o servidor gravou)."""
        rows = self.psql(
            "SELECT status || '|' || COALESCE(payment_status,'') || '|' || "
            "COALESCE(fare_total::text,'') || '|' || "
            "COALESCE(pricing->>'quote_id','') || '|' || "
            "COALESCE(pricing->>'quoted_at','') "
            f"FROM rides WHERE id = '{ride_id}'")
        if not rows:
            raise E2EFailure(f"corrida {ride_id} não está no Postgres")
        status, payment, fare, quote_id, quoted_at = rows[0].split("|")
        return {
            "status": status,
            "payment_status": payment,
            "fare_total": float(fare) if fare else None,
            "quote_id": quote_id,
            "quoted_at": quoted_at,
        }

    # --- PSP (o dinheiro) -------------------------------------------------
    def psp_confirm(self, payment_id: str, ride_id: str) -> dict:
        """O PSP simulado confirma: webhook assinado, server-to-server.

        É a ÚNICA porta que confirma dinheiro — o app só pergunta o estado.
        """
        body = {
            "event": "payment.confirmed",
            "payment_id": payment_id,
            "psp_payment_id": f"e2e-{ride_id}",
        }
        req = urllib.request.Request(
            f"{self.stack_base}/functions/v1/psp-webhook",
            data=json.dumps(body).encode(),
            method="POST",
        )
        req.add_header("x-psp-secret", self.psp_secret)
        req.add_header("content-type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise E2EFailure(
                f"webhook do PSP recusado ({exc.code}): {exc.read().decode()[:300]}"
            ) from exc
        if payload.get("code") != "confirmed":
            raise E2EFailure(f"webhook do PSP não confirmou: {payload}")
        return payload

    # --- o que o E2E precisa observar -------------------------------------
    def wait_presence(self, timeout: float = 30.0) -> str:
        """Espera o parceiro aparecer ONLINE no Postgres (despacho real)."""
        deadline = time.time() + timeout
        status = ""
        while time.time() < deadline:
            status = self.presence_status()
            if status in ("ONLINE_DISPONIVEL", "OFERTA_PENDENTE"):
                return status
            time.sleep(1.5)
        raise E2EFailure(
            f"parceiro não ficou ONLINE no Postgres (status: {status or 'AUSENTE'})"
        )

    def assert_ride(self, shown: float | None = None) -> dict:
        print("  backend real: conferindo o estado final")
        status, payload = self.api("GET", "/rides")
        if status != 200:
            raise E2EFailure(f"GET /rides devolveu {status}: {payload}")
        rides = payload.get("rides") or []
        if not rides:
            raise E2EFailure("GET /rides não devolveu a corrida do E2E")
        ride_id = rides[0]["ride_id"]
        status, detail = self.api("GET", f"/rides/{ride_id}")
        if status != 200:
            raise E2EFailure(f"GET /rides/{ride_id} devolveu {status}: {detail}")
        audit = self.ride_audit(ride_id)
        checks = {
            "status FINALIZADA": detail.get("status") == "FINALIZADA",
            "payment_status CONFIRMED": detail.get("payment_status") == "CONFIRMED",
            "fare_total preenchido": isinstance(detail.get("fare_total"), (int, float)),
            "parceiro real (não simulado)":
                "simulado" not in str((detail.get("partner") or {}).get("name", "")),
            # A cotação congelada: o servidor cobrou o valor GRAVADO na
            # cotação (uso único, dentro da validade) — nunca o do cliente.
            "cotação congelada gravada (quote_id)": bool(audit["quote_id"]),
            "mesma corrida na API e no Postgres":
                audit["status"] == detail.get("status"),
        }
        if shown is not None:
            checks["preço cobrado = preço mostrado na tela"] = (
                isinstance(detail.get("fare_total"), (int, float))
                and abs(float(detail["fare_total"]) - shown) < 0.005
            )
            checks["preço do Postgres = preço da API"] = (
                audit["fare_total"] is not None
                and abs(audit["fare_total"] - float(detail["fare_total"])) < 0.005
            )
        failed = [name for name, ok in checks.items() if not ok]
        if failed:
            raise E2EFailure(
                "estado final inesperado: " + ", ".join(failed)
                + f"\n{json.dumps(detail, ensure_ascii=False, indent=2)}"
                + f"\nauditoria: {audit}"
            )
        # A UI acabou de avaliar. Reenviar deve dar 409 already_rated; se der
        # 201, a avaliação não chegou ao servidor.
        status, body = self.api("POST", f"/rides/{ride_id}/rating", {"stars": 5})
        if status != 409 or body.get("code") != "already_rated":
            raise E2EFailure(
                f"avaliação não persistiu: segundo POST devolveu {status} {body}"
            )
        # O dinheiro: a partida dobrada do ledger tem de fechar em zero.
        total = self.psql(
            "SELECT COALESCE(SUM(CASE WHEN direction = 'C' THEN amount "
            "ELSE -amount END), 0)::numeric(12,2) FROM ledger_entries")
        if not total or abs(float(total[0])) > 0.005:
            raise E2EFailure(f"ledger do Postgres não fecha em zero (Σ={total})")
        print(
            f"    ok  {ride_id} FINALIZADA · CONFIRMED · "
            f"R$ {detail['fare_total']:.2f} · avaliada"
            + (f" · cotação {audit['quote_id'][:8]}" if audit["quote_id"] else "")
            + f" · ledger Σ {total[0]}"
        )
        detail = dict(detail)
        detail["quote_id"] = audit["quote_id"]
        return detail


class DemoBackend:
    """Backend de demonstração (scripts/demo_api.py) — o E2E de sempre."""

    name = "demo"

    def __init__(self, *, base: str, device_api_base: str) -> None:
        self.base = base.rstrip("/")
        self.device_api_base = device_api_base
        self.payment = "cash"

    def dart_defines(self) -> list[str]:
        # Sem RIDES_BASE/AUTH_BASE o app fica no modo demonstração: o ciclo de
        # corrida na API de demo e o login de 4 dígitos (sem servidor).
        return [f"API_BASE={self.device_api_base}"]

    def wait_ready(self, timeout: float = 15.0) -> None:
        # A API de demo sobe DENTRO da tentativa (start_api já espera ela
        # responder) — aqui não há nada a checar antes do build.
        return None

    def offer_window_s(self) -> float | None:
        """Janela da oferta viva (timeout_at - sent_at), em segundos.

        Mesma prova do backend real: a janela tem de ser a do contrato
        (PRM-oferta.timeout = 15 s), e não a do relógio de ninguém.
        """
        status, payload = api(self.base, "GET", "/offers/mine")
        if status != 200:
            return None
        offer = self._ultima_oferta(payload)
        if offer is None:
            return None
        try:
            sent = _iso(offer["sent_at"])
            timeout_at = _iso(offer["timeout_at"])
        except (KeyError, ValueError):
            return None
        return (timeout_at - sent).total_seconds()

    def offer_sent_at(self) -> datetime | None:
        """Quando o servidor ENVIOU a oferta (UTC, com fuso).

        É a referência da janela: o instante do toque do harness é
        comparado com este carimbo — os dois do mesmo relógio.
        """
        status, payload = api(self.base, "GET", "/offers/mine")
        if status != 200:
            return None
        offer = self._ultima_oferta(payload)
        if offer is None:
            return None
        try:
            return _iso(offer["sent_at"])
        except (KeyError, ValueError):
            return None

    @staticmethod
    def _ultima_oferta(payload: dict) -> dict | None:
        """A oferta mais recente do parceiro (a que está na tela)."""
        offers = payload.get("offers") or []
        vivas = [o for o in offers if o.get("status") in ("SENT", "PENDING", None)]
        candidatas = vivas or offers
        if not candidatas:
            return None
        try:
            return max(candidatas, key=lambda o: _iso(o.get("sent_at")))
        except (KeyError, ValueError):
            return candidatas[0]

    def login(self, ui: Ui, package: str, done_text: str, email: str) -> None:
        print(f"  login {package} (demo)")
        ui.adb.launch(package)
        ui.wait_text("Entrar ou criar conta", timeout=30)
        ui.tap("CONTINUAR", exact=True)
        ui.fill_field("69999999999", label="celular")
        ui.tap("CONTINUAR", exact=True)

        # M6: entre o celular e o OTP existe a etapa de e-mail. O `find`
        # curto distingue os dois fluxos sem duplicar o roteiro.
        if ui.find("E-mail", exact=True, timeout=8) is not None:
            ui.tap_edit()
            ui.clear_focused_text()
            ui.type_text("e2e@dezemais.app")
            ui.hide_keyboard()
            ui.tap("CONTINUAR", exact=True)

        ui.wait_text("Código de verificação", timeout=60)
        ui.fill_field("1234", label="código OTP")
        ui.tap_and_wait("ENTRAR", done_text, timeout=60)

    def assert_ride(self, shown: float | None = None) -> dict:
        print("  API: conferindo o estado final")
        active = api(self.base, "GET", "/rides?active=1")[1]
        if active.get("rides"):
            raise E2EFailure("ainda existe corrida ativa após finalizar/avaliar")
        rides = api(self.base, "GET", "/rides")[1].get("rides", [])
        if not rides:
            raise E2EFailure("GET /rides não devolveu a corrida do E2E")
        ride = rides[0]
        ride_id = ride["ride_id"]
        detail = api(self.base, "GET", f"/rides/{ride_id}")[1]
        checks = {
            "status FINALIZADA": detail.get("status") == "FINALIZADA",
            # O schema Ride não expõe cash_declared; na demo CONFIRMED só existe
            # quando o parceiro declarou o dinheiro (POST /rides/{id}/transition
            # com cash_declared=true). A tela do passageiro viu o mesmo estado.
            "payment_status CONFIRMED": detail.get("payment_status") == "CONFIRMED",
            "fare_total preenchido": isinstance(detail.get("fare_total"), (int, float)),
            "parceiro real (não simulado)":
                "simulado" not in str((detail.get("partner") or {}).get("name", "")),
            # O preço veio de uma COTAÇÃO CONGELADA no servidor: o app apresentou
            # o quote_id e o servidor cobrou o valor gravado (nunca o do cliente).
            "cotação congelada honrada (quote_id)": bool(detail.get("quote_id")),
        }
        if shown is not None:
            checks["preço cobrado = preço mostrado na tela"] = (
                isinstance(detail.get("fare_total"), (int, float))
                and abs(float(detail["fare_total"]) - shown) < 0.005
            )
        failed = [name for name, ok in checks.items() if not ok]
        if failed:
            raise E2EFailure(
                "estado final inesperado: " + ", ".join(failed)
                + f"\n{json.dumps(detail, ensure_ascii=False, indent=2)}"
            )
        # A UI acabou de avaliar. Reenviar deve dar 409 already_rated; se der 201,
        # a avaliação não chegou ao servidor (a tela teria voltado sem gravar).
        status, body = api(
            self.base, "POST", f"/rides/{ride_id}/rating", {"stars": 5}
        )
        if status != 409 or body.get("code") != "already_rated":
            raise E2EFailure(
                f"avaliação não persistiu: segundo POST devolveu {status} {body}"
            )
        print(
            f"    ok  {ride_id} FINALIZADA · CONFIRMED · "
            f"R$ {detail['fare_total']:.2f} · avaliada"
            + (f" · cotação {detail.get('quote_id', '')[:8]}"
               if detail.get("quote_id") else "")
        )
        return detail


def capture_diagnostics(adb: Adb, artifacts: Path) -> None:
    """Logcat e identidade do dispositivo: o que o screenshot não mostra.

    Falha de ambiente (emulador morto, adb offline) sem logcat é
    indiagnosticável depois; e o fingerprint/ABI dizem qual imagem rodou.
    """
    # Direto para arquivo, sem pipe: quando o dispositivo some no meio,
    # `adb logcat -d` pode não fechar o stdout e um pipe penduraria o teste.
    log_path = artifacts / "logcat.txt"
    try:
        with open(log_path, "wb") as out:
            subprocess.run(
                adb.cmd("logcat", "-d", "-v", "time"),
                stdout=out,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
        print(f"    logcat: {log_path}")
    except (subprocess.TimeoutExpired, OSError) as exc:
        print(f"    aviso: logcat incompleto ({exc})", file=sys.stderr)
    try:
        info = {
            prop: adb.shell("getprop", prop, timeout=15)
            for prop in (
                "ro.build.fingerprint",
                "ro.build.version.sdk",
                "ro.product.cpu.abi",
            )
        }
        info["wm_size"] = adb.shell("wm", "size", timeout=15)
        info["adb_state"] = adb.state() or "ausente"
        (artifacts / "device.json").write_text(
            json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    except E2EFailure as exc:
        print(f"    aviso: device.json incompleto ({exc})", file=sys.stderr)


def ensure_online(ui: Ui, backend) -> None:
    print("  parceiro: ficar online")
    # O app não finge online: sem fix de GPS ele fica em OFFLINE e a tela diz
    # por quê. O AVD entrega o primeiro fix devagar, então cada tentativa
    # reenvia a posição da praça piloto antes de tocar de novo.
    for attempt in range(1, 4):
        ui.tap("FICAR ONLINE", exact=True, timeout=30)
        # O topo minimalista não tem mais chip "ONLINE": o estado online é
        # provado pelo próprio CTA, que vira "FICAR OFFLINE".
        try:
            ui.wait_text("FICAR OFFLINE", exact=True, timeout=25)
        except E2EFailure:
            if attempt == 3:
                raise
            print(f"    sem ONLINE (tentativa {attempt}); reenviando posição")
            fix_geo(ui.adb)
            time.sleep(5)
            continue
        ui.shot("01-parceiro-online")
        # No backend real o despacho olha o Postgres: sem presença gravada
        # não chega oferta, e a UI mentiria se dissesse que está online.
        if isinstance(backend, RealBackend):
            status = backend.wait_presence()
            print(f"    presença no Postgres: {status}")
        return


def assert_radar(ui: Ui, timeout: float = 45.0) -> str:
    """Confere o radar do passageiro com **um** dump por tentativa.

    Por que um dump só: cada `uiautomator dump` leva 2-5 s neste emulador e
    a conferência é a única leitura antes do pedido. Fazer três buscas
    separadas (contador positivo, "radar indisponível", "nenhum motorista")
    gastava ~8 s à toa.

    Onde esta conferência acontece: **antes** do pedido, na tela de destino.
    Por quê: a oferta do parceiro vive 15 s (PRM-oferta.timeout) e uma leitura
    de tela neste emulador custa 3-5 s (`uiautomator dump` + o mapa em
    rasterização por software). Dentro da janela, o teste perdia a corrida
    por lentidão do harness — não por defeito do produto. A tela de destino
    mostra o mesmo contador ("N motoristas na região"), lido da MESMA
    presença real (Edge Function `radar` no Postgres).

    O que é exigido (o que a tela precisa provar):
      * o contador **positivo** ("1 motorista na região") — `wait_text`
        casava por substring e o texto NEGATIVO ("Nenhum motorista por
        perto") fazia o E2E passar com o radar vazio;
      * nada de "radar indisponível" (backend real sem `RADAR_BASE`);
      * nada de "nenhum motorista na região" junto do contador positivo.
    """
    deadline = time.monotonic() + timeout
    rx = re.compile(r"[1-9]\d*\s+motoristas?\s+na\s+regi", re.IGNORECASE)
    while time.monotonic() < deadline:
        try:
            root = ui.dump(save_on_error=False)
        except E2EFailure:
            time.sleep(0.5)
            continue
        labels = [label for label, _x, _y, _ in ui.nodes(root)]
        lower = [lbl.lower() for lbl in labels]
        ui.remember_labels(root)
        if any("radar indispon" in lbl for lbl in lower):
            ui.shot("failure-radar-indisponivel")
            raise E2EFailure(
                "radar respondeu indisponível durante a busca — "
                "com o backend real, `RADAR_BASE` tem de estar configurado"
            )
        achou = next((lbl for lbl in labels if rx.search(lbl)), None)
        if achou:
            if any("nenhum motorista na regi" in lbl for lbl in lower):
                ui.shot("failure-radar-vazio")
                raise E2EFailure(
                    "radar respondeu 0 motoristas durante a busca"
                )
            print(f"    ok  radar -> {achou!r}")
            return achou
        time.sleep(0.5)
    ui.shot("failure-radar-vazio")
    raise E2EFailure(
        f"timeout esperando o contador positivo do radar em {timeout:.0f}s"
        f" — rótulos na tela: {ui.visible_summary()}"
    )


def request_ride(ui: Ui, backend) -> float:
    print("  passageiro: pedir corrida")
    ui.wait_text("Para onde?", exact=True, timeout=30)
    ui.shot("02-passageiro-home")
    # Invariante do produto: enquanto o parceiro está online, a presença no
    # Postgres tem de estar FRESCA (o servidor só mostra quem deu sinal de
    # vida nos últimos 90 s). Se a idade passou disso, o passageiro vai ver
    # "nenhum motorista" — e a causa está no parceiro, não no passageiro.
    if isinstance(backend, RealBackend):
        age = backend.presence_age_s()
        print(f"    idade da presença do parceiro: {age if age is None else round(age, 1)}s")
        if age is None or age > 90:
            ui.shot("failure-presenca-velha")
            raise E2EFailure(
                "a presença do parceiro no Postgres está velha "
                f"({age if age is None else round(age, 1)}s > 90s): "
                "o heartbeat não está batendo com o app em segundo plano"
            )
    ui.tap_and_wait("Para onde?", "Confirmar destino", timeout=45)
    # O radar é requisito do fluxo e tem de mostrar MOTORISTA DE VERDADE.
    #
    # A conferência é ANTES do pedido (tela de destino): a oferta do parceiro
    # vive 15 s (PRM-oferta.timeout) e uma leitura de tela custa 3-5 s neste
    # emulador. Dentro da janela, o teste perdia a corrida por lentidão do
    # harness — não por defeito do produto.
    fix_geo(ui.adb)
    assert_radar(ui, timeout=45)
    ui.shot("02b-passageiro-radar")
    # Endereço real via geocoding do backend (Nominatim). A sugestão precisa
    # ser escolhida: o pedido não aceita mais destino genérico sem número.
    ui.tap_edit()
    ui.clear_focused_text()
    ui.type_text("Centro")
    ui.wait_text("Brasil", timeout=25)  # sugestão do Nominatim
    ui.tap("Brasil", timeout=15)
    # Endereço sem house_number abre o diálogo obrigatório do número.
    ui.wait_text("Número do endereço", timeout=20)
    ui.type_text("1234")  # campo do diálogo entra focado (autofocus)
    ui.tap_and_wait("Confirmar", "Confirmar destino", timeout=20)
    ui.wait_text("Chamar", timeout=20)
    # O teclado precisa estar fechado: com ele aberto a tela perde ~40% da
    # altura, o card de cotação sai da área visível e o `uiautomator` (que
    # só enxerga o que está na tela) não acha o preço. O app já fecha o
    # teclado quando o endereço fica completo — isto cobre o resto.
    ui.dismiss_keyboard()
    # O valor que o passageiro está vendo agora — é contra ele que o
    # servidor vai conferir o preço cobrado no fim do fluxo.
    shown = ui.price_shown(timeout=10)
    if shown is None:
        ui.shot("failure-sem-cotacao")
        raise E2EFailure(
            "não encontrei o valor da cotação na tela antes de chamar "
            f"— rótulos: {ui.visible_summary(limit=12)}"
        )
    print(f"    cotação na tela: R$ {shown:.2f}")
    # GPS fresco na hora do pedido. O AVD só entrega um fix quando alguém
    # manda (`adb emu geo fix`): sem isto, o `getCurrentPosition` do
    # passageiro fica esperando um fix novo e a tela de busca só consulta o
    # radar ~5 s depois do pedido — 5 s da janela de 15 s do parceiro,
    # comidas por causa do GPS e não do produto.
    fix_geo(ui.adb)
    print(f"    [{_clock()}] toca em 'Chamar' (a corrida nasce aqui)")
    ui.tap("Chamar", exact=True, timeout=15)
    # Segundo fix: garante a entrega para quem já estava esperando.
    fix_geo(ui.adb)
    #
    # DAQUI PARA A FRENTE A JANELA DA OFERTA ESTÁ CORRENDO (15 s no
    # servidor). NENHUMA LEITURA DE TELA AQUI: um `uiautomator dump` custa
    # 3-5 s neste emulador e comia a janela inteira — o teste perdia a
    # corrida por lentidão do harness, não por defeito do produto.
    # A captura de tela é rápida (0,5 s) e serve de evidência; a espera
    # de 1 s é só para a navegação para a tela de busca acontecer.
    time.sleep(1.0)
    ui.shot("03-passageiro-buscando")
    print(f"    [{_clock()}] pedido feito; troca para o parceiro")
    return shown


def accept_and_finish(ui: Ui, backend) -> None:
    print("  parceiro: oferta e corrida")
    ui.adb.launch(PARCEIRO)
    print(f"    [{_clock()}] app do parceiro em primeiro plano")
    ui.wait_text("ACEITAR", exact=True, timeout=45)
    print(f"    [{_clock()}] 'ACEITAR' visível — tocando")
    # A janela da oferta é o `PRM-oferta.timeout` do contrato (15 s).
    # Conferida no servidor (não no relógio do cliente): é a guarda contra a
    # configuração da cidade divergir do SPEC — no banco local a janela
    # estava em 60 s (4× mais espera para o passageiro) enquanto o SPEC, o
    # seed e a API de demo dizem 15 s.
    janela = backend.offer_window_s()
    if janela is None or abs(janela - OFERTA_TIMEOUT_CONTRATO_S) > 0.5:
        raise E2EFailure(
            f"janela da oferta = {janela}s (contrato: "
            f"{OFERTA_TIMEOUT_CONTRATO_S}s — PRM-oferta.timeout)"
        )
    print(f"    ok  janela da oferta: {janela}s (PRM-oferta.timeout)")
    # Carimbo do servidor: quando a oferta FOI ENVIADA. O toque é
    # comparado com ele — a prova de que o parceiro aceitou dentro da
    # janela, sem depender do relógio do emulador (que pode estar adiantado
    # ou atrasado em relação ao Postgres).
    enviada_em = backend.offer_sent_at()
    # A oferta vive 15 s (janela do produto) e uma captura de tela neste
    # emulador leva vários segundos: o toque vem ANTES da foto, senão a
    # janela fecha antes do aceite ("Oferta perdida por tempo").
    ui.tap("ACEITAR", exact=True)
    tocou_em = datetime.now(timezone.utc)
    if enviada_em is not None:
        idade = (tocou_em - enviada_em).total_seconds()
        if idade > OFERTA_TIMEOUT_CONTRATO_S:
            raise E2EFailure(
                f"o toque em 'ACEITAR' saiu {idade:.1f}s depois do envio da "
                f"oferta — a janela do contrato é {OFERTA_TIMEOUT_CONTRATO_S}s"
            )
        print(f"    ok  aceite dentro da janela: {idade:.1f}s de "
              f"{OFERTA_TIMEOUT_CONTRATO_S}s (servidor)")
    ui.shot("04-parceiro-aceite")
    ui.wait_text("A CAMINHO", exact=True, timeout=35)
    ui.shot("05-parceiro-em-corrida")
    ui.tap("A CAMINHO", exact=True)
    ui.wait_text("CHEGUEI (raio 50 m)", exact=True, timeout=30)
    ui.tap("CHEGUEI (raio 50 m)", exact=True)
    ui.wait_text("INICIAR CORRIDA", exact=True, timeout=30)
    ui.tap("INICIAR CORRIDA", exact=True)
    ui.wait_text("FINALIZAR", exact=True, timeout=30)
    ui.tap("FINALIZAR", exact=True)
    ui.wait_text("Confirmação de dinheiro", timeout=30)
    if backend.payment == "pix":
        # Pagamento digital: o parceiro NÃO declara dinheiro em espécie — o
        # split é do PSP, e a confirmação chega pelo webhook assinado.
        ui.tap("Pagamento digital (sem declarar)", exact=True)
    else:
        ui.tap("CONFIRMEI O DINHEIRO", exact=True)
    ui.shot("06-parceiro-finalizado")


def pay_and_rate(ui: Ui, backend) -> None:
    print("  passageiro: pagamento e avaliação")
    ui.adb.launch(PASSAGEIRO)
    if backend.payment == "pix":
        # O passageiro paga: o app cria a cobrança (PENDING) e mostra o botão
        # "Já paguei". Quem confirma é o PSP — o harness faz esse papel.
        ui.wait_text("Pagar com PIX", timeout=45)
        ui.tap("Pagar com PIX", exact=True)
        ui.wait_text("Já paguei", timeout=45)
        ui.shot("07-passageiro-pix-pendente")
        ride_id = _ride_id_from_psql(backend)
        payment_id = backend.payment_id(ride_id)
        if not payment_id:
            raise E2EFailure(
                f"nenhuma cobrança PIX criada para a corrida {ride_id}")
        print(f"    cobrança {payment_id} pendente; PSP confirma")
        backend.psp_confirm(payment_id, ride_id)
        # O "Já paguei" só PERGUNTA ao servidor. Como o PSP acabou de
        # confirmar, o app avança sozinho para a tela de avaliação (o título
        # dela é "Avaliar a corrida") — nesse caminho não existe botão
        # "Avaliar corrida". Se o poll já tiver atualizado a tela para o
        # estado "pago", o botão "Avaliar corrida" é o que leva à mesma tela.
        if ui.find("Já paguei", exact=True, timeout=3) is not None:
            ui.tap("Já paguei", exact=True)
        elif ui.find("Avaliar corrida", exact=True, timeout=3) is not None:
            ui.tap("Avaliar corrida", exact=True)
        else:
            raise E2EFailure(
                "nem 'Já paguei' nem 'Avaliar corrida' na tela de pagamento "
                f"— rótulos: {ui.visible_summary(limit=12)}")
        ui.wait_text("Avaliar a corrida", exact=True, timeout=60)
    else:
        # Dinheiro declarado pelo parceiro: a cobrança em espécie já foi
        # confirmada no servidor e a tela de pagamento mostra "Pagamento
        # confirmado" com o botão "Avaliar corrida".
        ui.wait_text("Pagamento confirmado", timeout=45)
        ui.tap("Avaliar corrida", exact=True, timeout=20)
        ui.wait_text("Avaliar a corrida", exact=True, timeout=60)
    ui.shot("07-passageiro-pagamento")
    ui.tap("5 estrelas", timeout=15)
    ui.shot("08-passageiro-avaliacao")
    ui.tap_and_wait("Enviar avaliação", "Para onde?", timeout=60)
    ui.shot("09-passageiro-home-final")


def _ride_id_from_psql(backend) -> str:
    """A corrida mais recente do passageiro (o Postgres é a fonte)."""
    rows = backend.psql(
        "SELECT id FROM rides WHERE passenger_user_id = "
        f"'{DEV_PASSAGEIRO}' ORDER BY created_at DESC LIMIT 1")
    if not rows:
        raise E2EFailure("nenhuma corrida do passageiro no Postgres")
    return rows[0]


def stop_gradle_daemons() -> None:
    """Libera a memória do Gradle antes do fluxo.

    O daemon do Gradle fica vivo (~900 MB) depois do build e, junto com o
    emulador de 4 GB, é o que mais pesa num host de 12 GB — pesar demais faz o
    qemu morrer no meio do teste. O próximo build sobe o daemon de novo.
    """
    if not os.environ.get("JAVA_HOME"):
        for candidate in (
            r"C:\Program Files\Android\Android Studio\jbr",
            str(Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/Android Studio/jbr"),
        ):
            if Path(candidate, "bin", "java.exe").exists():
                os.environ["JAVA_HOME"] = candidate
                break
    for app in ("passageiro", "parceiro"):
        wrapper = ROOT / "app" / app / "android" / (
            "gradlew.bat" if os.name == "nt" else "gradlew"
        )
        if not wrapper.exists():
            continue
        # No Windows .bat só roda via cmd; sem JAVA_HOME o wrapper não acha Java.
        cmd = ["cmd", "/c", str(wrapper), "--stop"] if os.name == "nt" \
            else [str(wrapper), "--stop"]
        try:
            run(cmd, cwd=wrapper.parent, capture=True)
            print("    gradle daemon encerrado (libera memória para o emulador)")
        except E2EFailure:
            pass  # sem daemon vivo não há o que parar


def start_api(port: int, artifacts: Path) -> tuple[subprocess.Popen, object]:
    # Porta ocupada = armadilha: no Windows dois processos podem escutar a
    # MESMA porta (SO_REUSEADDR) e o app passa a falar com um servidor VELHO
    # (de outra sessão), que ainda tem a corrida ativa de antes — o E2E falha
    # com "active_ride_exists" sem que nada do produto esteja quebrado.
    # Por isso a porta é conferida ANTES de subir a API.
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            raise E2EFailure(
                f"a porta {port} já está em uso por outro processo — "
                f"encerrre-o ou rode com --port <outra>. "
                f"(no Windows: Get-NetTCPConnection -LocalPort {port})"
            )
    except (ConnectionRefusedError, socket.timeout, OSError):
        pass  # porta livre: pode subir a API
    log_path = artifacts / "demo_api.log"
    log = open(log_path, "wb")
    env = os.environ.copy()
    # Impede o aceite automático: este teste quer o parceiro real.
    env["DEMO_AUTO_ACCEPT_S"] = "600"
    # Log linha-a-line do que o app pede. Sem isso o diagnóstico do ciclo da
    # oferta (15 s de janela) fica no escuro: o `demo_api.log` tinha só a
    # linha de arranque.
    env["DEMO_LOG"] = "1"
    proc = subprocess.Popen(
        [sys.executable, "-u", "scripts/demo_api.py", "--port", str(port)],
        cwd=ROOT,
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        wait_api(f"http://127.0.0.1:{port}", "/me", timeout=15)
    except Exception:
        proc.terminate()
        log.close()
        raise
    return proc, log


def main() -> int:
    # Log line-a-line: se a execução for interrompida, o log continua útil.
    # Windows usa cp1252 por padrão: o roteiro imprime ↔ e acentos.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", line_buffering=True)
        except (AttributeError, OSError):
            pass
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", help="serial do adb (ex.: emulator-5554)")
    parser.add_argument("--avd", default="",
                        help="AVD a subir quando não há dispositivo "
                             "(default: o único AVD instalado)")
    parser.add_argument("--no-emulator", action="store_true",
                        help="exige um dispositivo já conectado; não sobe AVD")
    parser.add_argument("--keep-emulator", action="store_true",
                        help="não encerra o AVD que este script subiu")
    parser.add_argument("--headless", action="store_true",
                        help="sobe o AVD sem janela (CI); default: com janela")
    parser.add_argument("--gpu", default="",
                        help="modo de GPU do AVD (ex.: host, swiftshader_indirect); "
                             "default: escolha do emulador")
    parser.add_argument("--boot-timeout", type=float, default=240.0,
                        help="segundos máximos esperando o boot do AVD")
    parser.add_argument("--port", type=int, default=8790,
                        help="porta da API isolada do teste (default: 8790)")
    parser.add_argument("--base", help="base HTTP vista pelo host")
    parser.add_argument("--device-api-base",
                        help="base vista pelo emulador (default: 10.0.2.2:<port>)")
    parser.add_argument("--backend", choices=("demo", "real"), default="demo",
                        help="demo = API de demonstração (default); real = stack "
                             "Supabase local (GoTrue + Postgres + PSP)")
    parser.add_argument("--payment", choices=("pix", "cash"), default="pix",
                        help="no backend real: pix = o webhook assinado do PSP "
                             "confirma (default); cash = o parceiro declara o "
                             "dinheiro em espécie")
    parser.add_argument("--stack-base", default=DEFAULT_STACK_BASE,
                        help="base do stack local vista pelo host")
    parser.add_argument("--rides-base", default=DEFAULT_RIDES_BASE,
                        help="base da Edge Function 'rides' vista pelo emulador")
    parser.add_argument("--auth-base", default=DEFAULT_AUTH_BASE,
                        help="base do GoTrue vista pelo emulador")
    parser.add_argument("--radar-base", default=DEFAULT_RADAR_BASE,
                        help="base da Edge Function 'radar' (presença real)")
    parser.add_argument("--anon-key",
                        default=os.environ.get("AUTH_ANON_KEY",
                                               DEFAULT_ANON_KEY),
                        help="chave pública (apikey) do projeto Supabase")
    parser.add_argument("--mail-base", default=DEFAULT_MAIL_BASE,
                        help="API da caixa de entrada do GoTrue (Inbucket)")
    parser.add_argument("--psp-secret",
                        default=os.environ.get("PSP_WEBHOOK_SECRET",
                                               DEFAULT_PSP_SECRET),
                        help="segredo do webhook do PSP")
    parser.add_argument("--jwt-secret",
                        default=os.environ.get("SUPABASE_JWT_SECRET",
                                               DEFAULT_JWT_SECRET),
                        help="segredo do JWT (só para o verificador ler o estado)")
    parser.add_argument("--db-container", default=DEFAULT_DB_CONTAINER,
                        help="container do Postgres do stack local")
    parser.add_argument("--adb", help="caminho do adb")
    parser.add_argument("--emulator", help="caminho do emulator")
    parser.add_argument("--flutter", help="caminho do flutter")
    parser.add_argument("--skip-server", action="store_true",
                        help="usa uma API já em execução (--base)")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-install", action="store_true")
    parser.add_argument("--keep-server", action="store_true",
                        help="deixa a API do teste rodando ao terminar")
    parser.add_argument("--artifacts", default=".preview/e2e_auto")
    parser.add_argument("--attempts", type=int, default=3,
                        help="tentativas completas antes de FAIL (default: 3). "
                             "O emulador 37.x segfaulta de forma intermitente e o "
                             "cold start do primeiro frame às vezes perde o toque; "
                             "a retentativa sobe um AVD novo e reusa os APKs.")
    args = parser.parse_args()
    if args.attempts < 1:
        parser.error("--attempts precisa ser >= 1")

    port = args.port
    base = args.base or f"http://127.0.0.1:{port}"
    device_base = args.device_api_base or f"http://10.0.2.2:{port}"

    local_appdata = os.environ.get("LOCALAPPDATA", "")
    adb_path = find_tool(
        "adb",
        args.adb,
        [
            str(Path(local_appdata) / "Android/Sdk/platform-tools/adb.exe"),
            str(Path.home() / "AppData/Local/Android/Sdk/platform-tools/adb.exe"),
        ],
    )
    emulator_path = None
    if not args.no_emulator:
        emulator_path = find_tool(
            "emulator",
            args.emulator,
            [
                str(Path(local_appdata) / "Android/Sdk/emulator/emulator.exe"),
                str(Path.home() / "AppData/Local/Android/Sdk/emulator/emulator.exe"),
            ],
        )
    flutter_path = None
    if not args.skip_build:
        flutter_path = find_tool(
            "flutter",
            args.flutter,
            [
                "C:/flutter-sdk/flutter/bin/flutter.bat",
                str(Path.home() / "flutter/bin/flutter.bat"),
            ],
        )

    if args.backend == "real":
        # O ciclo de corrida, o acesso e a presença vão para o stack real; o
        # que ainda não migrou (perfil, passe, carteira, geocoding) fica na
        # API de demo, que sobe como no roteiro de sempre.
        backend = RealBackend(
            device_api_base=device_base,
            stack_base=args.stack_base,
            device_rides_base=args.rides_base,
            device_auth_base=args.auth_base,
            device_radar_base=args.radar_base,
            anon_key=args.anon_key,
            mail_base=args.mail_base,
            psp_secret=args.psp_secret,
            jwt_secret=args.jwt_secret,
            db_container=args.db_container,
            payment=args.payment,
        )
    else:
        backend = DemoBackend(base=base, device_api_base=device_base)

    tools = {
        "adb": adb_path,
        "emulator": emulator_path,
        "flutter": flutter_path,
        "base": base,
        "device_api_base": device_base,
        "backend": backend,
    }
    stamp = time.strftime("%Y%m%d-%H%M%S")
    last_error = ""
    for attempt in range(1, args.attempts + 1):
        artifacts = ROOT / args.artifacts / f"{stamp}-a{attempt}"
        artifacts.mkdir(parents=True, exist_ok=True)
        print(f"\n### tentativa {attempt}/{args.attempts} — {artifacts}", flush=True)
        try:
            result = run_attempt(
                args,
                artifacts,
                tools,
                need_build=attempt == 1 and not args.skip_build,
            )
        except E2EFailure as exc:
            last_error = str(exc)
            print(f"tentativa {attempt} falhou: {last_error}", file=sys.stderr)
            if attempt < args.attempts:
                print(
                    "retentando com ambiente limpo (AVD novo)...",
                    file=sys.stderr,
                )
                time.sleep(5)
            continue
        result["attempts"] = attempt
        (artifacts / "result.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        if attempt > 1:
            print(
                f"\nPASS na tentativa {attempt}/{args.attempts}: as anteriores "
                "falharam. Isso é instabilidade do teste/ambiente, não um bug "
                "curado — cada tentativa tem seu result.json com "
                "`failure_kind` (infra × produto)."
            )
        return 0
    print(
        f"\nFAIL após {args.attempts} tentativa(s) — {last_error}",
        file=sys.stderr,
    )
    return 1


def run_attempt(args, artifacts: Path, tools: dict, need_build: bool) -> dict:
    """Uma execução completa: AVD, API, APKs e fluxo. Devolve o resultado."""
    base = tools["base"]
    device_base = tools["device_api_base"]
    backend = tools["backend"]
    adb = Adb(tools["adb"], args.serial)
    ui = Ui(adb, artifacts)
    emulator = (
        Emulator(tools["emulator"], adb, artifacts) if tools["emulator"] else None
    )
    server = None
    log = None
    started_emulator = False
    started_at = time.monotonic()
    result: dict = {"status": "fail", "artifacts": str(artifacts),
                    "backend": backend.name,
                    "payment": backend.payment}
    try:
        # O stack real tem de estar no ar antes do build: sem GoTrue o app
        # entra em modo dev e o roteiro real não acontece.
        backend.wait_ready()
        # Build **antes** de subir o AVD: o Gradle sobe daemon e heap de ~1 GB,
        # e somar isso ao emulador já em execução é o que estourava a memória
        # do host (12 GB) no meio do fluxo. Sem AVD ligado não há o que perder.
        if need_build:
            flutter_path = tools["flutter"]
            assert flutter_path
            flutter_cmd = (
                ["cmd", "/c", flutter_path] if os.name == "nt" and
                flutter_path.lower().endswith((".bat", ".cmd")) else [flutter_path]
            )
            for app in ("passageiro", "parceiro"):
                print(f"build {app}")
                run(
                    flutter_cmd + [
                        "build", "apk", "--debug",
                    ] + [
                        f"--dart-define={define}"
                        for define in backend.dart_defines()
                    ],
                    cwd=ROOT / "app" / app,
                )
            stop_gradle_daemons()

        if args.no_emulator or args.serial:
            serial = adb.choose_device()
        else:
            try:
                serial = adb.choose_device()
            except E2EFailure:
                assert emulator is not None
                print(f"nenhum dispositivo adb; subindo AVD {args.avd}")
                serial = emulator.boot(
                    args.avd,
                    timeout=args.boot_timeout,
                    headless=args.headless,
                    gpu=args.gpu,
                )
                started_emulator = True
        print(f"dispositivo: {serial}")
        tune_device(adb)
        print(f"API do teste: {base} (emulador: {device_base})")
        print(f"backend: {result['backend']} · pagamento: {result['payment']}")
        print(f"artefatos: {artifacts}")

        if not args.skip_server:
            print(f"subindo API isolada na porta {args.port}")
            server, log = start_api(args.port, artifacts)
        else:
            wait_api(base, "/me", timeout=5)

        if not args.skip_install:
            for app in ("passageiro", "parceiro"):
                apk = (
                    ROOT / "app" / app / "build" / "app" / "outputs"
                    / "flutter-apk" / "app-debug.apk"
                )
                if not apk.exists():
                    raise E2EFailure(f"APK não encontrado: {apk}")
                print(f"instalando {app}")
                adb.install(apk)

        print("limpando estado dos apps")
        for package in (PASSAGEIRO, PARCEIRO):
            adb.clear(package)
            adb.grant(package, "android.permission.ACCESS_FINE_LOCATION")
            adb.grant(package, "android.permission.ACCESS_COARSE_LOCATION")

        print("\n== parceiro: login e ONLINE")
        backend.login(ui, PARCEIRO, "FICAR ONLINE", LOGIN_PARCEIRO)
        ensure_online(ui, backend)

        print("\n== passageiro: login e pedido")
        backend.login(ui, PASSAGEIRO, "Para onde?", LOGIN_PASSAGEIRO)
        shown = request_ride(ui, backend)

        print("\n== parceiro: aceite e transições")
        accept_and_finish(ui, backend)

        print("\n== passageiro: pagamento e avaliação")
        pay_and_rate(ui, backend)

        detail = backend.assert_ride(shown)
        result.update(
            status="pass",
            ride_id=detail["ride_id"],
            fare_total=detail.get("fare_total"),
            quoted_fare_shown=shown,
            quote_id=detail.get("quote_id"),
            status_final=detail.get("status"),
            payment_status=detail.get("payment_status"),
        )
        print("\nPASS — fluxo passageiro ↔ parceiro completo")
        print(f"corrida: {detail['ride_id']}  total: R$ {detail['fare_total']:.2f}")
        if shown is not None:
            print(f"cotação na tela: R$ {shown:.2f} (mesmo valor cobrado)")
        print(f"evidências: {artifacts}")
        return result
    except Exception as exc:
        result["error"] = str(exc)
        # Infra (emulador/adb/API mortos) × produto (a tela ou o contrato
        # mudou): só a primeira justifica nova rodada; a segunda é bug de
        # verdade.
        device_state = adb.state()
        result["device_state"] = device_state
        kind = "infra" if device_state != "device" else "produto"
        if kind == "produto":
            # A API do teste parou de responder? O app só veria "offline" e o
            # roteiro acusaria a tela — isso é infra, não produto.
            try:
                api(base, "GET", "/me", timeout=5)
            except Exception:
                kind = "infra"
                result["error"] += " — a API do teste não responde mais"
        result["failure_kind"] = kind
        print(f"\nFAIL ({result['failure_kind']}) — {exc}", file=sys.stderr)
        try:
            ui.shot("failure")
        except Exception:
            pass
        capture_diagnostics(adb, artifacts)
        if log is not None:
            print(f"log da API: {artifacts / 'demo_api.log'}", file=sys.stderr)
        raise
    finally:
        result["duration_s"] = round(time.monotonic() - started_at, 1)
        (artifacts / "result.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        if emulator is not None and started_emulator and not args.keep_emulator:
            print("encerrando o AVD do teste")
            emulator.shutdown()
        if server is not None and not args.keep_server:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
        if log is not None:
            log.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except E2EFailure as exc:
        print(f"erro: {exc}", file=sys.stderr)
        raise SystemExit(1)

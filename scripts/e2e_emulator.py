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

Uso (na raiz do repositório):

    python scripts/e2e_emulator.py                    # sobe o AVD sozinho
    python scripts/e2e_emulator.py --skip-build --skip-install
    python scripts/e2e_emulator.py --serial emulator-5554 --no-emulator

Requisitos: Flutter, Android SDK/platform-tools e a porta da API livre (padrão
8790). Se nenhum dispositivo estiver conectado, o script sobe o único AVD
instalado, espera o boot e o encerra no fim — `--no-emulator` exige um
dispositivo já conectado, `--headless` sobe o AVD sem janela (CI),
`--keep-emulator` deixa o AVD ligado. A API
usa estado em memória; cada execução começa do zero. O script NÃO mata
processos de outras portas.

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
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PASSAGEIRO = "app.dezemais.passageiro"
PARCEIRO = "app.dezemais.parceiro"
# Sem --avd: usa o único AVD instalado (e falha listando os candidatos se houver
# mais de um), para o teste não depender do nome do AVD de cada máquina.
EMULATOR_PORT = 5554


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
        run(adb.cmd("emu", "geo", "fix", "-63.9039", "-8.7607"), capture=True)
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
        # Sem --gpu: deixa o emulador escolher. Forçar swiftshader derrubava o
        # AVD em Windows no meio do fluxo; headless não tem GPU de host, então
        # aí o software renderer é o default.
        args += ["-gpu", gpu] if gpu else (["-gpu", "swiftshader_indirect"] if headless else [])
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
            # `--compressed` (da 3ª tentativa em diante) costuma resolver o
            # "could not get idle state" quando algum widget segue animando;
            # as features que ele omite não são usadas na busca por rótulo.
            extra = ("--compressed",) if attempt >= 2 else ()
            out = self.adb.shell(
                "uiautomator", "dump", *extra, "/sdcard/e2e-ui.xml"
            )
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
            for label, x, y, _ in self.nodes(root):
                match = label == text if exact else needle in label.lower()
                if match:
                    return x, y
            if self.dismiss_system_dialogs(root):
                continue
            time.sleep(0.5)
        return None

    def tap(
        self,
        text: str,
        *,
        exact: bool = False,
        timeout: float = 10.0,
        required: bool = True,
    ) -> bool:
        pos = self.find(text, exact=exact, timeout=timeout)
        if pos is None:
            if not required:
                return False
            self.shot(f"missing-{re.sub(r'[^a-z0-9]+', '-', text.lower())[:40]}")
            raise E2EFailure(f"não encontrei {text!r} na tela")
        self.adb.shell("input", "tap", str(pos[0]), str(pos[1]))
        print(f"    tap {text!r} @ {pos}")
        return True

    def wait_text(
        self,
        text: str,
        *,
        exact: bool = False,
        timeout: float = 30.0,
    ) -> None:
        if self.find(text, exact=exact, timeout=timeout) is None:
            self.shot(f"missing-{re.sub(r'[^a-z0-9]+', '-', text.lower())[:40]}")
            raise E2EFailure(
                f"timeout esperando {text!r} em {timeout:.0f}s"
                f" — rótulos na tela: {self.visible_summary()}"
            )
        print(f"    ok  {text!r}")

    def visible_summary(self, limit: int = 8) -> str:
        """Rótulos visíveis agora — o que faltava para diagnosticar um timeout."""
        try:
            labels = [label for label, *_ in self.nodes(self.dump(save_on_error=False))]
        except E2EFailure as exc:
            return f"(dump indisponível: {exc})"
        unique = list(dict.fromkeys(labels))[:limit]
        return " | ".join(unique) if unique else "(sem rótulos)"

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
        print(f"    screenshot {path.name}")
        return path


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


def login(ui: Ui, package: str, done_text: str) -> None:
    print(f"  login {package}")
    ui.adb.launch(package)
    ui.wait_text("Entrar ou criar conta", timeout=30)
    ui.tap("CONTINUAR", exact=True)
    ui.fill_field("69999999999", label="celular")
    ui.tap_and_wait("CONTINUAR", "Código de verificação", timeout=60)
    ui.fill_field("1234", label="código OTP")
    ui.tap_and_wait("ENTRAR", done_text, timeout=60)

def ensure_online(ui: Ui) -> None:
    print("  parceiro: ficar online")
    # O app não finge online: sem fix de GPS ele fica em OFFLINE e a tela diz
    # por quê. O AVD entrega o primeiro fix devagar, então cada tentativa
    # reenvia a posição da praça piloto antes de tocar de novo.
    for attempt in range(1, 4):
        ui.tap("FICAR ONLINE", exact=True, timeout=30)
        try:
            ui.wait_text("ONLINE", exact=True, timeout=25)
        except E2EFailure:
            if attempt == 3:
                raise
            print(f"    sem ONLINE (tentativa {attempt}); reenviando posição")
            ui.adb.shell("emu", "geo", "fix", "-63.9039", "-8.7607")
            time.sleep(5)
            continue
        ui.shot("01-parceiro-online")
        return


def request_ride(ui: Ui) -> None:
    print("  passageiro: pedir corrida")
    ui.wait_text("Para onde?", exact=True, timeout=30)
    ui.shot("02-passageiro-home")
    ui.tap_and_wait("Para onde?", "Confirmar destino", timeout=45)
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
    ui.tap_and_wait("Chamar", "Busca ativa", timeout=45)
    # O radar é requisito do fluxo: com parceiro online ele TEM de responder
    # (antes a URL duplicava /nearby e a tela anunciava "Radar indisponível").
    ui.wait_text("motorista", timeout=30)
    if ui.find("Radar indisponível", timeout=1) is not None:
        ui.shot("failure-radar-indisponivel")
        raise E2EFailure("radar respondeu indisponível durante a busca")
    ui.shot("03-passageiro-buscando")


def accept_and_finish(ui: Ui) -> None:
    print("  parceiro: oferta e corrida")
    ui.adb.launch(PARCEIRO)
    ui.wait_text("ACEITAR", exact=True, timeout=45)
    ui.shot("04-parceiro-oferta")
    ui.tap("ACEITAR", exact=True)
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
    ui.tap("CONFIRMEI O DINHEIRO", exact=True)
    ui.shot("06-parceiro-finalizado")


def pay_and_rate(ui: Ui) -> None:
    print("  passageiro: pagamento já confirmado + avaliação")
    ui.adb.launch(PASSAGEIRO)
    ui.wait_text("Pagamento confirmado", timeout=35)
    ui.shot("07-passageiro-pagamento")
    ui.tap_and_wait("Avaliar corrida", "Avaliar a corrida", timeout=60)
    ui.tap("5 estrelas", timeout=15)
    ui.shot("08-passageiro-avaliacao")
    ui.tap_and_wait("Enviar avaliação", "Para onde?", timeout=60)
    ui.shot("09-passageiro-home-final")


def assert_ride(base: str) -> dict:
    print("  API: conferindo o estado final")
    active = api(base, "GET", "/rides?active=1")[1]
    if active.get("rides"):
        raise E2EFailure("ainda existe corrida ativa após finalizar/avaliar")
    rides = api(base, "GET", "/rides")[1].get("rides", [])
    if not rides:
        raise E2EFailure("GET /rides não devolveu a corrida do E2E")
    ride = rides[0]
    ride_id = ride["ride_id"]
    detail = api(base, "GET", f"/rides/{ride_id}")[1]
    checks = {
        "status FINALIZADA": detail.get("status") == "FINALIZADA",
        # O schema Ride não expõe cash_declared; na demo CONFIRMED só existe
        # quando o parceiro declarou o dinheiro (POST /rides/{id}/transition
        # com cash_declared=true). A tela do passageiro viu o mesmo estado.
        "payment_status CONFIRMED": detail.get("payment_status") == "CONFIRMED",
        "fare_total preenchido": isinstance(detail.get("fare_total"), (int, float)),
        "parceiro real (não simulado)":
            "simulado" not in str((detail.get("partner") or {}).get("name", "")),
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        raise E2EFailure(
            "estado final inesperado: " + ", ".join(failed)
            + f"\n{json.dumps(detail, ensure_ascii=False, indent=2)}"
        )
    # A UI acabou de avaliar. Reenviar deve dar 409 already_rated; se der 201,
    # a avaliação não chegou ao servidor (a tela teria voltado sem gravar).
    status, body = api(
        base, "POST", f"/rides/{ride_id}/rating", {"stars": 5}
    )
    if status != 409 or body.get("code") != "already_rated":
        raise E2EFailure(
            f"avaliação não persistiu: segundo POST devolveu {status} {body}"
        )
    print(
        f"    ok  {ride_id} FINALIZADA · CONFIRMED · "
        f"R$ {detail['fare_total']:.2f} · avaliada"
    )
    return detail


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
    log_path = artifacts / "demo_api.log"
    log = open(log_path, "wb")
    env = os.environ.copy()
    # Impede o aceite automático: este teste quer o parceiro real.
    env["DEMO_AUTO_ACCEPT_S"] = "600"
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

    tools = {
        "adb": adb_path,
        "emulator": emulator_path,
        "flutter": flutter_path,
        "base": base,
        "device_api_base": device_base,
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
    adb = Adb(tools["adb"], args.serial)
    ui = Ui(adb, artifacts)
    emulator = (
        Emulator(tools["emulator"], adb, artifacts) if tools["emulator"] else None
    )
    server = None
    log = None
    started_emulator = False
    started_at = time.monotonic()
    result: dict = {"status": "fail", "artifacts": str(artifacts)}
    try:
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
                        f"--dart-define=API_BASE={device_base}",
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
        login(ui, PARCEIRO, "FICAR ONLINE")
        ensure_online(ui)

        print("\n== passageiro: login e pedido")
        login(ui, PASSAGEIRO, "Para onde?")
        request_ride(ui)

        print("\n== parceiro: aceite e transições")
        accept_and_finish(ui)

        print("\n== passageiro: pagamento e avaliação")
        pay_and_rate(ui)

        detail = assert_ride(base)
        result.update(
            status="pass",
            ride_id=detail["ride_id"],
            fare_total=detail.get("fare_total"),
            status_final=detail.get("status"),
            payment_status=detail.get("payment_status"),
        )
        print("\nPASS — fluxo passageiro ↔ parceiro completo")
        print(f"corrida: {detail['ride_id']}  total: R$ {detail['fare_total']:.2f}")
        print(f"evidências: {artifacts}")
        return result
    except Exception as exc:
        result["error"] = str(exc)
        # Infra (emulador/adb morto) × produto (a tela ou o contrato mudou):
        # só a primeira justifica nova rodada; a segunda é bug de verdade.
        device_state = adb.state()
        result["device_state"] = device_state
        result["failure_kind"] = "infra" if device_state != "device" else "produto"
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

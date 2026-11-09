#!/usr/bin/env python3
"""Gera os ícones do app (launcher Android + web) a partir da arte da marca.

Fonte única: `app/parceiro/assets/logo/logo_icone_alpha.jpeg` — o quadrado
escuro com o logo teal "10 é +". A assinatura "Dola AI" fica no canto
inferior direito, FORA do quadrado, então não aparece em nenhum ícone gerado.

O que é gerado, para cada app (`app/passageiro` e `app/parceiro`):

  Android (launcher)
    - `mipmap-<densidade>/ic_launcher.png` (48/72/96/144/192) — a arte
      completa (quadrado arredondado), para launchers antigos.
    - `mipmap-<densidade>/ic_launcher_foreground.png` (108/162/216/324/432) —
      só o logo teal, inscrito no círculo seguro de 66 dp do adaptive icon.
    - `values/colors.xml` — `ic_launcher_background` com a cor do corpo
      escuro (o fundo do adaptive icon).
    - `mipmap-anydpi-v26/ic_launcher.xml` — adaptive icon já existente,
      apenas passa a apontar para os arquivos novos (sem mudança de código).

  Web
    - `web/favicon.png` (32) e `web/icons/Icon-192.png`, `Icon-512.png`
      (a arte completa).
    - `web/icons/Icon-maskable-192.png`, `Icon-maskable-512.png` — fundo
      escuro + logo inscrito na zona segura de 80% do maskable.

O PNG é sempre RGBA; o recorte do JPEG (branco + sombra) vira transparência
para o ícone não ficar com halo cinza no launcher.

Uso:
    python3 scripts/gen_app_icons.py
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

RAIZ = Path(__file__).resolve().parent.parent
FONTE = RAIZ / "app" / "parceiro" / "assets" / "logo" / "logo_icone_alpha.jpeg"
APPS = ("app/passageiro", "app/parceiro")

# Densidade Android: launcher (quadrado) e foreground do adaptive icon (108 dp).
DENSIDADES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}

# Adaptive icon: a zona segura é um círculo de 66 dp dentro dos 108 dp.
SAFE_ZONE = 66.0
# Ícone maskable da web: zona segura = círculo de 80% do lado.
SAFE_ZONE_WEB = 0.80


def _clamp(valor: float, minimo: float = 0.0, maximo: float = 1.0) -> float:
    return max(minimo, min(maximo, valor))


def recorte_da_arte() -> Image.Image:
    """Recorta o quadrado da marca (sem a assinatura "Dola AI")."""
    arte = Image.open(FONTE).convert("RGB")
    largura, altura = arte.size
    px = arte.load()

    def luminancia(c: tuple[int, int, int]) -> float:
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]

    # Borda do corpo escuro (o quadrado), ignorando a sombra clara.
    coluna = [x for x in range(largura) if luminancia(px[x, altura // 2]) < 90]
    linha = [y for y in range(altura) if luminancia(px[largura // 2, y]) < 90]
    caixa = (min(coluna), min(linha), max(coluna) + 1, max(linha) + 1)
    return arte.crop(caixa)


def arte_com_alpha(arte: Image.Image) -> Image.Image:
    """Branco e sombra (cinza claro) viram transparência; teal e corpo ficam."""
    saida = Image.new("RGBA", arte.size)
    origem = arte.load()
    destino = saida.load()
    for y in range(arte.size[1]):
        for x in range(arte.size[0]):
            r, g, b = origem[x, y]
            saturacao = max(r, g, b) - min(r, g, b)
            lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if saturacao >= 60:
                # Teal da marca ("10 é +"): mantém opaco.
                alfa = 255
            else:
                # Corpo escuro = opaco; branco/sombra = transparente, com
                # transição suave na borda.
                alfa = int(_clamp((160 - lum) / 100.0) * 255)
            destino[x, y] = (r, g, b, alfa)
    return saida


def logo_teal(arte: Image.Image) -> Image.Image:
    """Só o logo teal da marca, com fundo transparente (o adaptive icon)."""
    saida = Image.new("RGBA", arte.size)
    origem = arte.load()
    destino = saida.load()
    for y in range(arte.size[1]):
        for x in range(arte.size[0]):
            r, g, b = origem[x, y]
            teal = min(g, b) - r
            # O corpo escuro tem um tom azulado leve (teal ~28): o corte em 40
            # separa o logo teal da marca do fundo.
            alfa = int(_clamp((teal - 40) / 25.0) * 255)
            destino[x, y] = (r, g, b, alfa)
    caixa = saida.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if caixa is None:
        raise SystemExit("logo teal não encontrado na arte de origem")
    return saida.crop(caixa)


def cor_de_fundo(arte: Image.Image) -> str:
    """Cor mediana do corpo escuro (fundo do adaptive icon)."""
    origem = arte.load()
    amostras = []
    for y in range(0, arte.size[1], 3):
        for x in range(0, arte.size[0], 3):
            r, g, b = origem[x, y]
            if max(r, g, b) - min(r, g, b) >= 60:
                continue  # teal do logo
            lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if lum < 90:
                amostras.append((r, g, b))
    amostras.sort()
    n = len(amostras)
    med = tuple(amostras[n // 2][i] for i in range(3))
    return "#{:02X}{:02X}{:02X}".format(*med)


def quadrado(img: Image.Image, lado: int) -> Image.Image:
    """Redimensiona preservando o centro (a arte é quase quadrada)."""
    saida = Image.new("RGBA", (lado, lado), (0, 0, 0, 0))
    escala = lado / max(img.size)
    novo = (
        img.resize(
            (max(1, round(img.size[0] * escala)), max(1, round(img.size[1] * escala))),
            Image.LANCZOS,
        )
        if escala < 1
        else img
    )
    saida.paste(
        novo,
        ((lado - novo.size[0]) // 2, (lado - novo.size[1]) // 2),
        novo,
    )
    return saida


def foreground(logo: Image.Image, lado: int) -> Image.Image:
    """Logo inscrito no círculo seguro, centralizado no canvas."""
    destino = Image.new("RGBA", (lado, lado), (0, 0, 0, 0))
    diag = min(lado * SAFE_ZONE / 108.0, lado)
    escala = diag / max(logo.size)
    novo = logo.resize(
        (max(1, round(logo.size[0] * escala)), max(1, round(logo.size[1] * escala))),
        Image.LANCZOS,
    )
    destino.paste(novo, ((lado - novo.size[0]) // 2, (lado - novo.size[1]) // 2), novo)
    return destino


def main() -> int:
    if not FONTE.exists():
        raise SystemExit(f"arte de origem não encontrada: {FONTE}")

    arte = recorte_da_arte()
    rgba = arte_com_alpha(arte)
    logo = logo_teal(arte)
    fundo = cor_de_fundo(arte)
    print(f"arte: {FONTE.relative_to(RAIZ)} -> {rgba.size[0]}x{rgba.size[1]}")
    print(f"logo teal: {logo.size[0]}x{logo.size[1]} | fundo adaptive: {fundo}")

    for app in APPS:
        base = RAIZ / app
        res = base / "android" / "app" / "src" / "main" / "res"
        for densidade, (tela, frente) in DENSIDADES.items():
            pasta = res / f"mipmap-{densidade}"
            pasta.mkdir(parents=True, exist_ok=True)
            quadrado(rgba, tela).save(pasta / "ic_launcher.png")
            foreground(logo, frente).save(pasta / "ic_launcher_foreground.png")

        cores = res / "values" / "colors.xml"
        cores.write_text(
            cores.read_text(encoding="utf-8").replace(
                '<color name="ic_launcher_background">#232C30</color>',
                f'<color name="ic_launcher_background">{fundo}</color>',
            ),
            encoding="utf-8",
        )

        web = base / "web"
        (web / "icons").mkdir(parents=True, exist_ok=True)
        quadrado(rgba, 32).save(web / "favicon.png")
        quadrado(rgba, 192).save(web / "icons" / "Icon-192.png")
        quadrado(rgba, 512).save(web / "icons" / "Icon-512.png")
        for lado in (192, 512):
            canvas = Image.new("RGBA", (lado, lado), fundo)
            destino = Image.new("RGBA", (lado, lado), (0, 0, 0, 0))
            diag = lado * SAFE_ZONE_WEB
            escala = diag / max(logo.size)
            novo = logo.resize(
                (
                    max(1, round(logo.size[0] * escala)),
                    max(1, round(logo.size[1] * escala)),
                ),
                Image.LANCZOS,
            )
            destino.paste(
                novo, ((lado - novo.size[0]) // 2, (lado - novo.size[1]) // 2), novo
            )
            canvas.alpha_composite(destino)
            canvas.convert("RGB").save(web / "icons" / f"Icon-maskable-{lado}.png")
        print(f"{app}: ícones gerados")

    return 0


if __name__ == "__main__":
    sys.exit(main())

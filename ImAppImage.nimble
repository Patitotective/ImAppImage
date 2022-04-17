# Package

version          = "0.1.0"
author           = "Patitotective"
description      = "ImAppImage is a simple Dear ImGui application to install and manage AppImages"
license          = "MIT"
namedBin["main"] = "ImAppImage"
installFiles     = @["config.niprefs", "assets/icon.png", "assets/style.niprefs", "assets/ProggyVector Regular.ttf", "assets/forkawesome-webfont.ttf"]

# Dependencies

requires "nim >= 1.6.2"
requires "nake >= 1.9.4"
requires "nimgl >= 1.3.2"
requires "chroma >= 0.2.4"
requires "niprefs >= 0.1.5"
requires "stb_image >= 2.5"
requires "https://github.com/nim-lang/zip >= 0.3.1"
requires "https://github.com/Patitotective/ImStyle >= 0.1.0"
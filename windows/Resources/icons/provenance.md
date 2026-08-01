# AppIcon.ico provenance

- Source: `Resources/AppIcon/AppIcon-1024.png`
- Source SHA-256: `f5d88d9f05a3ae9743aff268470fed97494c815f8848c6e9252a70a18df59672`
- Output SHA-256: `464d24e60982d44626d5cefcbf2c47df41580eb034734fca03518d5643e73644`
- Sizes: 16, 24, 32, 48, 64, 128, and 256 pixels
- Generation command:

  `python3 -c 'from PIL import Image; source=Image.open("Resources/AppIcon/AppIcon-1024.png").convert("RGBA"); source.save("windows/Resources/icons/AppIcon.ico", format="ICO", sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])'`

The blue-purple project artwork is used unchanged apart from resizing and ICO
container encoding. It is project-owned artwork and does not use the OpenAI
name, wordmark, knot, or other OpenAI trademark.

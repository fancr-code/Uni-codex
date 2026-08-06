# Uni-codex third-party notices

The root MIT License applies only to original Uni-codex installer code and
documentation for which `fancr-code` or Uni-codex contributors hold the
copyright. It does not relicense third-party applications, libraries,
plugins, scripts, artwork, names, or trademarks.

## OpenAI Codex CLI

Project: https://github.com/openai/codex

License: Apache-2.0. A copy is provided at `LICENSES/Apache-2.0.txt`.

## OpenAI Codex desktop application

The official Codex desktop application and Microsoft Store packages are not
licensed by this repository and are not part of the public source snapshot.
The MIT License in this repository does not grant permission to redistribute,
modify, sublicense, or mirror those packages. Obtain them through an official
OpenAI or Microsoft distribution channel and comply with the applicable
service, software, and trademark terms.

Public Uni-codex releases must not contain an official Codex desktop package
unless the publisher has separate written redistribution authorization. The
release workflow is gated by an explicit authorization input and a repository
administrator variable.

## Codex++

Project: https://github.com/BigPizzaV3/CodexPlusPlus

Pinned upstream version: v1.2.44.

License metadata: AGPL-3.0-only. A copy is provided at
`LICENSES/AGPL-3.0-only.txt`.

The compatibility patch under `patches/CodexPlusPlus/` and every distributed
modified Codex++ binary remain subject to the upstream AGPL terms. A binary
distribution must provide its matching Corresponding Source, the downstream
patch, build instructions, license text, and required notices.

## Codex++ script market

The referenced Codex++ script-market repositories do not currently declare a
repository-wide open-source license, and the indexed scripts do not declare
individual licenses. Uni-codex therefore does not mirror their source files in
the public repository. References to immutable upstream URLs are provided for
users who choose to retrieve scripts directly from their authors.

Do not publish an offline bundle containing those scripts without obtaining
permission or confirming an applicable license for every included script.

## Codex plugins

Plugins and marketplace content retain their individual upstream licenses and
notices. A missing license declaration is not permission to redistribute a
plugin. Runtime-supplied or restricted plugins must be obtained from their
official marketplace by an authorized user instead of being mirrored by a
Uni-codex release.

## Microsoft Store package resolver

The Windows build-time Store resolver includes code derived from
https://github.com/Wangnov/codex-app-mirror under the MIT License. Its retained
license text is at
`windows/tools/StorePackageResolver/LICENSE.codex-app-mirror.txt`.

## Trademarks

OpenAI, Codex, Microsoft, Windows, and other names and logos are trademarks of
their respective owners. Open-source copyright licenses do not grant trademark
rights or imply endorsement.

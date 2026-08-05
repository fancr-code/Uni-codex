import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class OnlineReleaseContractTests(unittest.TestCase):
    def test_windows_bootstrap_uses_official_store_and_codex_plus_release(self):
        script = (ROOT / "windows" / "online" / "Install-UniCodex.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("9PLM9XGG6VKS", script)
        self.assertIn("get.microsoft.com/installer/download/9PLM9XGG6VKS", script)
        self.assertIn("BigPizzaV3/CodexPlusPlus", script)
        self.assertNotIn("agentsmirror", script)
        self.assertIn("Get-AuthenticodeSignature", script)

    def test_macos_bootstrap_uses_openai_and_codex_plus_release(self):
        script = (ROOT / "macos" / "online" / "install-unicodex.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("persistent.oaistatic.com/codex-app-prod", script)
        self.assertIn("BigPizzaV3/CodexPlusPlus", script)
        self.assertNotIn("agentsmirror", script)
        self.assertIn("codesign", script)

    def test_release_workflow_builds_both_platform_assets(self):
        workflow = (ROOT / ".github" / "workflows" / "online-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("tags:", workflow)
        self.assertIn("windows-latest", workflow)
        self.assertIn("macos-latest", workflow)
        self.assertIn("Uni-codex-Windows-x64-Online-Setup.exe", workflow)
        self.assertIn("Uni-codex-macOS-Online.dmg", workflow)
        self.assertIn("--repo '${{ github.repository }}'", workflow)
        self.assertNotIn("CODEX_REDISTRIBUTION_AUTHORIZED", workflow)


if __name__ == "__main__":
    unittest.main()

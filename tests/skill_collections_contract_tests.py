import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class SkillCollectionsContractTests(unittest.TestCase):
    def test_manifest_pins_three_approved_collections(self):
        manifest = json.loads((ROOT / "skills" / "collections.json").read_text("utf-8"))
        self.assertEqual(
            [item["repository"] for item in manifest["collections"]],
            [
                "Yuan1z0825/nature-skills",
                "K-Dense-AI/scientific-agent-skills",
                "neuromechanist/research-skills",
            ],
        )
        for item in manifest["collections"]:
            self.assertRegex(item["commit"], r"^[0-9a-f]{40}$")
            self.assertEqual(item["license"], "MIT")

    def test_online_installers_install_skill_collections(self):
        windows = (ROOT / "windows" / "online" / "Install-UniCodex.ps1").read_text("utf-8")
        macos = (ROOT / "macos" / "online" / "install-unicodex.sh").read_text("utf-8")
        self.assertIn("Install-SkillCollections.ps1", windows)
        self.assertIn("install-skill-collections.sh", macos)

    def test_windows_installer_clears_successful_robocopy_exit_code(self):
        installer = (ROOT / "scripts" / "Install-SkillCollections.ps1").read_text("utf-8")
        self.assertIn("$global:LASTEXITCODE = 0", installer)

    def test_offline_builds_bundle_skill_collections(self):
        windows = (ROOT / "windows" / "scripts" / "build-installer.ps1").read_text("utf-8")
        macos = (ROOT / "build-codex-one-click-installer.sh").read_text("utf-8")
        inno = (ROOT / "windows" / "installer" / "CodexOneClick.iss").read_text("utf-8")
        core = (ROOT / "Resources" / "installer-core.sh").read_text("utf-8")
        self.assertIn("skill-collections", windows)
        self.assertIn("skill-collections", macos)
        self.assertIn("Install-SkillCollections.ps1", inno)
        self.assertIn("install_skill_collections", core)

    def test_readme_names_all_preinstalled_collections(self):
        readme = (ROOT / "README.md").read_text("utf-8")
        for name in ("Nature Skills", "Scientific Agent Skills", "Research Skills"):
            self.assertIn(name, readme)
        self.assertIn("211", readme)


if __name__ == "__main__":
    unittest.main()
